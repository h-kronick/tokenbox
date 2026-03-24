use crate::database::{DailySummary, Database};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

/// Recompute daily summaries for a specific date from raw token_events.
pub fn rollup_date(db: &Arc<Database>, date: &str) -> Result<(), String> {
    let start_of_day = format!("{}T00:00:00Z", date);
    let end_of_day = format!("{}T23:59:59Z", date);

    let events = db
        .query_token_events(Some(&start_of_day), Some(&end_of_day))
        .map_err(|e| e.to_string())?;

    // Group by (source, model)
    struct Group {
        input: i64,
        output: i64,
        cache_r: i64,
        cache_w: i64,
        cost: Option<f64>,
        sessions: HashSet<String>,
    }

    let mut groups: HashMap<String, Group> = HashMap::new();
    for event in &events {
        let key = format!("{}|{}", event.source, event.model);
        let group = groups.entry(key).or_insert_with(|| Group {
            input: 0,
            output: 0,
            cache_r: 0,
            cache_w: 0,
            cost: None,
            sessions: HashSet::new(),
        });
        group.input += event.input_tokens;
        group.output += event.output_tokens;
        group.cache_r += event.cache_read;
        group.cache_w += event.cache_create;
        if let Some(c) = event.cost_usd {
            group.cost = Some(group.cost.unwrap_or(0.0) + c);
        }
        if let Some(ref sid) = event.session_id {
            group.sessions.insert(sid.clone());
        }
    }

    // Upsert each group
    for (key, group) in &groups {
        let parts: Vec<&str> = key.splitn(2, '|').collect();
        if parts.len() != 2 {
            continue;
        }
        let summary = DailySummary {
            date: date.to_string(),
            source: parts[0].to_string(),
            model: parts[1].to_string(),
            total_input: group.input,
            total_output: group.output,
            total_cache_read: group.cache_r,
            total_cache_write: group.cache_w,
            total_cost: group.cost,
            session_count: group.sessions.len() as i64,
        };
        db.upsert_daily_rollup(&summary).map_err(|e| e.to_string())?;
    }

    Ok(())
}

/// Recompute daily summaries for the last N days.
pub fn rollup_recent_days(db: &Arc<Database>, days: i64) -> Result<(), String> {
    let today = chrono::Local::now().date_naive();
    for offset in 0..days {
        let date = today - chrono::Duration::days(offset);
        let date_str = date.format("%Y-%m-%d").to_string();
        rollup_date(db, &date_str)?;
    }
    Ok(())
}

// ── Tauri Command ─────────────────────────────────────────────────

#[tauri::command]
pub fn run_rollup(db: tauri::State<'_, Arc<Database>>) -> Result<(), String> {
    let today = chrono::Local::now().date_naive().format("%Y-%m-%d").to_string();
    rollup_date(&db, &today)
}
