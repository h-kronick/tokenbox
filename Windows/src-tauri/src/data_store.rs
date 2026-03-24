use crate::database::{Database, ModelBreakdown, TokenEvent};
use chrono::Local;
use serde::Serialize;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};

/// Aggregate token data emitted to the frontend.
#[derive(Debug, Clone, Serialize)]
pub struct TokenData {
    pub today_tokens: i64,
    pub week_tokens: i64,
    pub month_tokens: i64,
    pub all_time_tokens: i64,
    pub realtime_delta: i64,
    pub realtime_display_tokens: i64,
    pub is_live: bool,
    pub today_by_model: Vec<ModelBreakdown>,
    pub week_by_model: Vec<ModelBreakdown>,
    pub month_by_model: Vec<ModelBreakdown>,
    pub all_time_by_model: Vec<ModelBreakdown>,
}

/// Mutable inner state for the data store.
struct DataStoreInner {
    model_filter: Option<String>,
    realtime_delta: i64,
    is_live: bool,
    today_tokens: i64,
    week_tokens: i64,
    month_tokens: i64,
    all_time_tokens: i64,
    today_by_model: Vec<ModelBreakdown>,
    week_by_model: Vec<ModelBreakdown>,
    month_by_model: Vec<ModelBreakdown>,
    all_time_by_model: Vec<ModelBreakdown>,
    debounce_pending: bool,
}

/// Central data store for token aggregation and state.
pub struct DataStore {
    db: Arc<Database>,
    inner: Mutex<DataStoreInner>,
}

impl DataStore {
    pub fn new(db: Arc<Database>) -> Self {
        Self {
            db,
            inner: Mutex::new(DataStoreInner {
                model_filter: Some("opus".to_string()),
                realtime_delta: 0,
                is_live: false,
                today_tokens: 0,
                week_tokens: 0,
                month_tokens: 0,
                all_time_tokens: 0,
                today_by_model: Vec::new(),
                week_by_model: Vec::new(),
                month_by_model: Vec::new(),
                all_time_by_model: Vec::new(),
                debounce_pending: false,
            }),
        }
    }

    /// Get the current model filter.
    pub fn model_filter(&self) -> Option<String> {
        self.inner.lock().unwrap().model_filter.clone()
    }

    /// Set the model filter.
    pub fn set_model_filter(&self, filter: Option<String>) {
        self.inner.lock().unwrap().model_filter = filter;
    }

    /// Add intermediate streaming tokens to the realtime delta (display only).
    pub fn add_realtime_delta(&self, output_tokens: i64, model: &str) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(ref filter) = inner.model_filter {
            if !model.to_lowercase().contains(&filter.to_lowercase()) {
                return;
            }
        }
        inner.realtime_delta += output_tokens;
    }

    /// Mark the stream as live.
    pub fn set_live(&self, live: bool) {
        self.inner.lock().unwrap().is_live = live;
    }

    /// Refresh all token counts from the database.
    /// Resets realtime_delta to 0 (DB totals now include completed events).
    pub fn refresh(&self) -> TokenData {
        let now = Local::now();
        let start_of_today = now
            .date_naive()
            .and_hms_opt(0, 0, 0)
            .unwrap()
            .and_local_timezone(Local)
            .unwrap();
        let start_of_tomorrow = start_of_today + chrono::Duration::days(1);

        let today_start = start_of_today.to_rfc3339();
        let today_end = start_of_tomorrow.to_rfc3339();

        // Week start (Monday)
        let weekday = now.date_naive().weekday().num_days_from_monday();
        let week_start_date = now.date_naive() - chrono::Duration::days(weekday as i64);
        let week_start = week_start_date
            .and_hms_opt(0, 0, 0)
            .unwrap()
            .and_local_timezone(Local)
            .unwrap()
            .to_rfc3339();

        // Month start
        let month_start_date = now
            .date_naive()
            .with_day(1)
            .unwrap_or(now.date_naive());
        let month_start = month_start_date
            .and_hms_opt(0, 0, 0)
            .unwrap()
            .and_local_timezone(Local)
            .unwrap()
            .to_rfc3339();

        let end = now.to_rfc3339();

        let mut inner = self.inner.lock().unwrap();
        // Reset intermediate delta — DB totals now include completed events
        inner.realtime_delta = 0;

        let filter = inner.model_filter.as_deref();

        // Token counts — output only, filtered by selected model
        inner.today_tokens = self
            .db
            .total_tokens(Some(&today_start), Some(&today_end), filter)
            .unwrap_or(0);
        inner.week_tokens = self
            .db
            .total_tokens(Some(&week_start), Some(&end), filter)
            .unwrap_or(0);
        inner.month_tokens = self
            .db
            .total_tokens(Some(&month_start), Some(&end), filter)
            .unwrap_or(0);
        inner.all_time_tokens = self.db.total_tokens(None, None, filter).unwrap_or(0);

        // Per-model breakdowns (unfiltered — used by sharing)
        inner.today_by_model = self
            .db
            .tokens_by_model(Some(&today_start), Some(&today_end))
            .unwrap_or_default();
        inner.week_by_model = self
            .db
            .tokens_by_model(Some(&week_start), Some(&end))
            .unwrap_or_default();
        inner.month_by_model = self
            .db
            .tokens_by_model(Some(&month_start), Some(&end))
            .unwrap_or_default();
        inner.all_time_by_model = self.db.tokens_by_model(None, None).unwrap_or_default();

        self.build_token_data(&inner)
    }

    /// Build a TokenData snapshot from current inner state.
    fn build_token_data(&self, inner: &DataStoreInner) -> TokenData {
        TokenData {
            today_tokens: inner.today_tokens,
            week_tokens: inner.week_tokens,
            month_tokens: inner.month_tokens,
            all_time_tokens: inner.all_time_tokens,
            realtime_delta: inner.realtime_delta,
            realtime_display_tokens: inner.today_tokens + inner.realtime_delta,
            is_live: inner.is_live,
            today_by_model: inner.today_by_model.clone(),
            week_by_model: inner.week_by_model.clone(),
            month_by_model: inner.month_by_model.clone(),
            all_time_by_model: inner.all_time_by_model.clone(),
        }
    }

    /// Get the current token data snapshot (without refreshing from DB).
    pub fn get_current(&self) -> TokenData {
        let inner = self.inner.lock().unwrap();
        self.build_token_data(&inner)
    }

    /// Schedule a debounced refresh (500ms). Returns true if a new debounce was started.
    pub fn request_debounced_refresh(&self) -> bool {
        let mut inner = self.inner.lock().unwrap();
        if inner.debounce_pending {
            return false;
        }
        inner.debounce_pending = true;
        true
    }

    /// Clear the debounce flag (called after the debounced refresh fires).
    pub fn clear_debounce(&self) {
        self.inner.lock().unwrap().debounce_pending = false;
    }
}

/// Emit the current token data to the frontend.
pub fn emit_token_data(app: &AppHandle, data: &TokenData) {
    let _ = app.emit("token-data-changed", data);
}

// ── Tauri Commands ────────────────────────────────────────────────

#[tauri::command]
pub fn get_token_data(store: tauri::State<'_, Arc<DataStore>>) -> TokenData {
    store.get_current()
}

#[tauri::command]
pub fn refresh_data(
    store: tauri::State<'_, Arc<DataStore>>,
    app: AppHandle,
) -> TokenData {
    let data = store.refresh();
    emit_token_data(&app, &data);
    data
}

#[tauri::command]
pub fn set_model_filter(
    store: tauri::State<'_, Arc<DataStore>>,
    app: AppHandle,
    filter: Option<String>,
) -> TokenData {
    store.set_model_filter(filter);
    let data = store.refresh();
    emit_token_data(&app, &data);
    data
}

#[tauri::command]
pub fn get_model_breakdown(
    db: tauri::State<'_, Arc<Database>>,
) -> Result<Vec<ModelBreakdown>, String> {
    let now = Local::now();
    let start_of_today = now
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_local_timezone(Local)
        .unwrap();
    let start_of_tomorrow = start_of_today + chrono::Duration::days(1);
    db.tokens_by_model(
        Some(&start_of_today.to_rfc3339()),
        Some(&start_of_tomorrow.to_rfc3339()),
    )
    .map_err(|e| e.to_string())
}
