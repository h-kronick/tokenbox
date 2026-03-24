use crate::data_store::DataStore;
use crate::database::ModelBreakdown;
use crate::sharing::{PeekResponse, SharingClient, SharingError};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tauri::{AppHandle, Emitter};

/// A friend tracked via cloud sharing.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudFriend {
    pub share_code: String,
    pub display_name: String,
    #[serde(default)]
    pub today_tokens: i64,
    #[serde(default)]
    pub today_date: String,
    #[serde(default)]
    pub tokens_by_model: HashMap<String, i64>,
    #[serde(default)]
    pub week_by_model: HashMap<String, i64>,
    #[serde(default)]
    pub month_by_model: HashMap<String, i64>,
    #[serde(default)]
    pub all_time_by_model: HashMap<String, i64>,
    pub last_token_change: Option<String>,
}

struct SharingState {
    sharing_enabled: bool,
    display_name: String,
    share_code: String,
    secret_token: Option<String>,
    friends: Vec<CloudFriend>,
    last_pushed_tokens: i64,
    last_push_time: Option<Instant>,
    last_error: Option<String>,
}

/// Manages friend sharing state and push/fetch timers.
pub struct SharingManager {
    client: SharingClient,
    state: Mutex<SharingState>,
}

impl SharingManager {
    pub fn new() -> Self {
        Self {
            client: SharingClient::new(),
            state: Mutex::new(SharingState {
                sharing_enabled: false,
                display_name: String::new(),
                share_code: String::new(),
                secret_token: None,
                friends: Vec::new(),
                last_pushed_tokens: 0,
                last_push_time: None,
                last_error: None,
            }),
        }
    }

    /// Load persisted state from settings store values.
    pub fn load_from_settings(
        &self,
        enabled: bool,
        display_name: &str,
        share_code: &str,
        secret_token: Option<&str>,
        friends_json: Option<&str>,
    ) {
        let mut state = self.state.lock().unwrap();
        state.sharing_enabled = enabled;
        state.display_name = display_name.to_string();
        state.share_code = share_code.to_string();
        state.secret_token = secret_token.map(String::from);
        if let Some(json) = friends_json {
            if let Ok(friends) = serde_json::from_str::<Vec<CloudFriend>>(json) {
                state.friends = friends;
            }
        }
    }

    pub fn is_registered(&self) -> bool {
        let state = self.state.lock().unwrap();
        !state.share_code.is_empty()
    }

    pub fn get_friends(&self) -> Vec<CloudFriend> {
        self.state.lock().unwrap().friends.clone()
    }

    pub fn get_share_code(&self) -> String {
        self.state.lock().unwrap().share_code.clone()
    }

    /// Register a new share identity.
    pub async fn register(&self, display_name: &str) -> Result<(String, String, String), String> {
        let name = display_name.trim();
        if name.is_empty() || name.len() > 7 {
            return Err("Display name must be 1-7 characters".to_string());
        }
        if !is_valid_display_name(name) {
            return Err(
                "Display name can only contain letters, numbers, and spaces".to_string(),
            );
        }

        let response = self
            .client
            .register(&name.to_uppercase())
            .await
            .map_err(|e| e.to_string())?;

        let mut state = self.state.lock().unwrap();
        state.share_code = response.share_code.clone();
        state.secret_token = Some(response.secret_token.clone());
        state.display_name = name.to_uppercase();
        state.sharing_enabled = true;
        state.last_error = None;

        Ok((
            response.share_code,
            response.secret_token,
            response.share_url,
        ))
    }

    /// Reset registration so the user can re-register.
    pub fn reset_registration(&self) {
        let mut state = self.state.lock().unwrap();
        state.share_code.clear();
        state.secret_token = None;
        state.sharing_enabled = false;
        state.last_error = None;
    }

    /// Add a friend by share code or URL.
    pub async fn add_friend(&self, input: &str) -> Result<CloudFriend, String> {
        let code = extract_share_code(input);
        if code.len() != 6 {
            return Err("Invalid share code".to_string());
        }

        {
            let state = self.state.lock().unwrap();
            if state.friends.iter().any(|f| f.share_code == code) {
                return Err("This friend has already been added".to_string());
            }
        }

        let response = self
            .client
            .peek(&code)
            .await
            .map_err(|e| e.to_string())?;

        let friend = friend_from_peek(&code, &response);
        {
            let mut state = self.state.lock().unwrap();
            state.friends.push(friend.clone());
        }

        Ok(friend)
    }

    /// Remove a friend by share code.
    pub fn remove_friend(&self, share_code: &str) {
        let mut state = self.state.lock().unwrap();
        state.friends.retain(|f| f.share_code != share_code);
    }

    /// Update the display name (validates and uppercases).
    pub fn update_display_name(&self, new_name: &str) -> Result<(), String> {
        let trimmed = new_name.trim();
        if trimmed.is_empty() || trimmed.len() > 7 {
            return Err("Display name must be 1-7 characters".to_string());
        }
        if !is_valid_display_name(trimmed) {
            return Err("Display name can only contain letters, numbers, and spaces".to_string());
        }
        let mut state = self.state.lock().unwrap();
        state.display_name = trimmed.to_uppercase();
        Ok(())
    }

    /// Push token counts to the cloud.
    pub async fn push_my_tokens(
        &self,
        today_tokens: i64,
        today_by_model: &[ModelBreakdown],
        week_by_model: &[ModelBreakdown],
        month_by_model: &[ModelBreakdown],
        all_time_by_model: &[ModelBreakdown],
        force: bool,
    ) -> Result<(), String> {
        let (share_code, secret_token, enabled, last_pushed, last_push_time, display_name) = {
            let state = self.state.lock().unwrap();
            (
                state.share_code.clone(),
                state.secret_token.clone(),
                state.sharing_enabled,
                state.last_pushed_tokens,
                state.last_push_time,
                state.display_name.clone(),
            )
        };

        if !enabled || share_code.is_empty() {
            return Ok(());
        }
        if !force && today_tokens == last_pushed {
            return Ok(());
        }

        // Client-side 10s throttle
        if !force {
            if let Some(last) = last_push_time {
                if last.elapsed().as_secs() < 10 {
                    return Ok(());
                }
            }
        }

        let token = secret_token
            .ok_or("Secret token missing — please re-register")?;

        let today_date = chrono::Local::now()
            .date_naive()
            .format("%Y-%m-%d")
            .to_string();

        let dn = if display_name.is_empty() { None } else { Some(display_name.as_str()) };
        let result = self
            .client
            .push(
                &share_code,
                &token,
                today_tokens,
                &today_date,
                build_model_map(today_by_model),
                build_model_map(week_by_model),
                build_model_map(month_by_model),
                build_model_map(all_time_by_model),
                dn,
            )
            .await;

        let mut state = self.state.lock().unwrap();
        match result {
            Ok(()) => {
                state.last_pushed_tokens = today_tokens;
                state.last_push_time = Some(Instant::now());
                state.last_error = None;
                Ok(())
            }
            Err(SharingError::RateLimited) => {
                state.last_push_time = Some(Instant::now());
                Ok(()) // Silently absorb
            }
            Err(e) => {
                state.last_error = Some(e.to_string());
                Err(e.to_string())
            }
        }
    }

    /// Fetch latest data for all friends.
    pub async fn fetch_all_friends(&self) {
        let codes: Vec<String> = {
            let state = self.state.lock().unwrap();
            state.friends.iter().map(|f| f.share_code.clone()).collect()
        };

        if codes.is_empty() {
            return;
        }

        for code in &codes {
            if let Ok(response) = self.client.peek(code).await {
                let friend = friend_from_peek(code, &response);
                let mut state = self.state.lock().unwrap();
                if let Some(idx) = state.friends.iter().position(|f| f.share_code == *code) {
                    state.friends[idx] = friend;
                }
            }
        }
    }

    /// Get friends list as JSON for persistence.
    pub fn friends_json(&self) -> String {
        let state = self.state.lock().unwrap();
        serde_json::to_string(&state.friends).unwrap_or_else(|_| "[]".to_string())
    }

    pub fn get_last_error(&self) -> Option<String> {
        self.state.lock().unwrap().last_error.clone()
    }
}

/// Check if a display name contains only allowed characters (alphanumeric + spaces).
fn is_valid_display_name(name: &str) -> bool {
    name.chars().all(|c| c.is_ascii_alphanumeric() || c == ' ')
}

/// Strip non-allowed characters from a received display name (defense-in-depth).
fn sanitize_display_name(name: &str) -> String {
    name.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == ' ')
        .collect()
}

fn friend_from_peek(code: &str, response: &PeekResponse) -> CloudFriend {
    CloudFriend {
        share_code: code.to_string(),
        display_name: sanitize_display_name(&response.display_name),
        today_tokens: response.today_tokens,
        today_date: response.today_date.clone(),
        tokens_by_model: response.tokens_by_model.clone(),
        week_by_model: response.week_by_model.clone(),
        month_by_model: response.month_by_model.clone(),
        all_time_by_model: response.all_time_by_model.clone(),
        last_token_change: response
            .last_token_change
            .clone()
            .or_else(|| response.last_updated.clone()),
    }
}

/// Build per-model output token map with short model names.
fn build_model_map(entries: &[ModelBreakdown]) -> HashMap<String, i64> {
    let mut result: HashMap<String, i64> = HashMap::new();
    for entry in entries {
        let key = if entry.model.contains("opus") {
            "opus"
        } else if entry.model.contains("sonnet") {
            "sonnet"
        } else if entry.model.contains("haiku") {
            "haiku"
        } else {
            &entry.model
        };
        *result.entry(key.to_string()).or_insert(0) += entry.output_tokens;
    }
    result
}

/// Extract a 6-char share code from user input (code or URL).
fn extract_share_code(input: &str) -> String {
    let trimmed = input.trim();

    // Direct 6-char code
    if trimmed.len() == 6 && trimmed.chars().all(|c| c.is_alphanumeric()) {
        return trimmed.to_uppercase();
    }

    // Try to extract from URL path like /share/XXXXXX
    if let Some(idx) = trimmed.find("/share/") {
        let after = &trimmed[idx + 7..];
        let code: String = after.chars().take(6).collect();
        if code.len() == 6 {
            return code.to_uppercase();
        }
    }

    // tokenbox://add/XXXXXX
    if let Some(idx) = trimmed.find("://add/") {
        let after = &trimmed[idx + 7..];
        let code: String = after.chars().take(6).collect();
        if code.len() == 6 {
            return code.to_uppercase();
        }
    }

    trimmed.to_uppercase()
}

/// Start 60s push and fetch timers.
pub fn start_sharing_timers(
    app: AppHandle,
    sharing: Arc<SharingManager>,
    store: Arc<DataStore>,
) {
    let sharing_push = sharing.clone();
    let store_push = store.clone();

    // Push timer — 60s interval
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            let data = store_push.get_current();
            let _ = sharing_push
                .push_my_tokens(
                    data.today_tokens,
                    &data.today_by_model,
                    &data.week_by_model,
                    &data.month_by_model,
                    &data.all_time_by_model,
                    false,
                )
                .await;
        }
    });

    // Fetch timer — 60s interval
    let sharing_fetch = sharing.clone();
    let app_fetch = app.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            sharing_fetch.fetch_all_friends().await;
            let friends = sharing_fetch.get_friends();
            let _ = app_fetch.emit("friends-changed", &friends);
        }
    });
}

// ── Tauri Commands ────────────────────────────────────────────────

#[tauri::command]
pub async fn register_sharing(
    sharing: tauri::State<'_, Arc<SharingManager>>,
    display_name: String,
) -> Result<(String, String, String), String> {
    let sharing = Arc::clone(&sharing);
    sharing.register(&display_name).await
}

#[tauri::command]
pub async fn add_friend(
    sharing: tauri::State<'_, Arc<SharingManager>>,
    app: AppHandle,
    input: String,
) -> Result<CloudFriend, String> {
    let sharing = Arc::clone(&sharing);
    let friend = sharing.add_friend(&input).await?;
    // Fetch latest data immediately
    sharing.fetch_all_friends().await;
    let friends = sharing.get_friends();
    let _ = app.emit("friends-changed", &friends);
    Ok(friend)
}

#[tauri::command]
pub fn remove_friend(
    sharing: tauri::State<'_, Arc<SharingManager>>,
    app: AppHandle,
    share_code: String,
) {
    sharing.remove_friend(&share_code);
    let friends = sharing.get_friends();
    let _ = app.emit("friends-changed", &friends);
}

#[tauri::command]
pub fn get_friends(sharing: tauri::State<'_, Arc<SharingManager>>) -> Vec<CloudFriend> {
    sharing.get_friends()
}

#[tauri::command]
pub async fn push_tokens(
    sharing: tauri::State<'_, Arc<SharingManager>>,
    store: tauri::State<'_, Arc<DataStore>>,
) -> Result<(), String> {
    let sharing = Arc::clone(&sharing);
    let data = store.get_current();
    sharing
        .push_my_tokens(
            data.today_tokens,
            &data.today_by_model,
            &data.week_by_model,
            &data.month_by_model,
            &data.all_time_by_model,
            true,
        )
        .await
}

#[tauri::command]
pub fn reset_registration(sharing: tauri::State<'_, Arc<SharingManager>>) {
    sharing.reset_registration();
}

#[tauri::command]
pub async fn update_display_name(
    sharing: tauri::State<'_, Arc<SharingManager>>,
    store: tauri::State<'_, Arc<DataStore>>,
    display_name: String,
) -> Result<(), String> {
    let sharing = Arc::clone(&sharing);
    sharing.update_display_name(&display_name)?;
    // Trigger immediate push so the server gets the new name
    let data = store.get_current();
    sharing
        .push_my_tokens(
            data.today_tokens,
            &data.today_by_model,
            &data.week_by_model,
            &data.month_by_model,
            &data.all_time_by_model,
            true,
        )
        .await
}
