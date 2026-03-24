// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokenbox_windows::*;

/// Settings structure returned to the frontend.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub pinned_display: String,
    pub model_filter: Option<String>,
    pub theme: String,
    pub sound_enabled: bool,
    pub sound_volume: f64,
    pub animation_speed: f64,
    pub realtime_flip_display: bool,
    pub menu_bar_tokens: bool,
    pub jsonl_scanning: bool,
    pub sharing_enabled: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            pinned_display: "today".to_string(),
            model_filter: Some("opus".to_string()),
            theme: "classic-amber".to_string(),
            sound_enabled: true,
            sound_volume: 0.7,
            animation_speed: 1.0,
            realtime_flip_display: true,
            menu_bar_tokens: true,
            jsonl_scanning: true,
            sharing_enabled: false,
        }
    }
}

fn main() {
    env_logger::init();

    tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::default().build())
        .setup(|app| {
            // Initialize database
            let db_path = paths::db_path();
            let db = Arc::new(
                database::Database::open(&db_path)
                    .expect("Failed to open database"),
            );

            // Initialize data store
            let store = Arc::new(data_store::DataStore::new(db.clone()));

            // Initialize sharing manager
            let sharing = Arc::new(sharing_manager::SharingManager::new());

            // Load sharing settings from store if available
            // (Frontend will call load_sharing_settings after init)

            // Register state with Tauri
            app.manage(db.clone());
            app.manage(store.clone());
            app.manage(sharing.clone());

            // Set up system tray
            tray::setup_tray(app.handle())?;

            // Initial data refresh
            let data = store.refresh();
            data_store::emit_token_data(app.handle(), &data);

            // Start file watchers
            let app_handle = app.handle().clone();

            // Keep watchers alive by storing them in state
            let live_watcher = watchers::start_live_watcher(
                app_handle.clone(),
                db.clone(),
                store.clone(),
            );
            let jsonl_watcher = watchers::start_jsonl_watcher(
                app_handle.clone(),
                db.clone(),
                store.clone(),
            );

            // Store watchers so they don't get dropped
            app.manage(WatcherHolder {
                _live: std::sync::Mutex::new(live_watcher),
                _jsonl: std::sync::Mutex::new(jsonl_watcher),
            });

            // Start sharing timers (runs on tokio runtime)
            let sharing_clone = sharing.clone();
            let store_clone = store.clone();
            let app_clone = app_handle.clone();
            tauri::async_runtime::spawn(async move {
                sharing_manager::start_sharing_timers(app_clone, sharing_clone, store_clone);
            });

            // Run initial aggregation
            let db_agg = db.clone();
            std::thread::spawn(move || {
                let _ = aggregator::rollup_recent_days(&db_agg, 30);
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            // Data store commands
            data_store::get_token_data,
            data_store::refresh_data,
            data_store::set_model_filter,
            data_store::get_model_breakdown,
            // Sharing commands
            sharing_manager::register_sharing,
            sharing_manager::add_friend,
            sharing_manager::remove_friend,
            sharing_manager::get_friends,
            sharing_manager::push_tokens,
            sharing_manager::reset_registration,
            sharing_manager::update_display_name,
            // Tray commands
            tray::update_tray_state,
            // Aggregator commands
            aggregator::run_rollup,
            // Settings commands
            load_sharing_settings,
            get_settings,
            save_setting,
            set_autostart,
            rescan_jsonl,
        ])
        .run(tauri::generate_context!())
        .expect("Error while running TokenBox");
}

/// Holds file watchers to prevent them from being dropped.
/// Wrapped in Mutex to satisfy Send + Sync required by Tauri's manage().
struct WatcherHolder {
    _live: std::sync::Mutex<Option<notify::RecommendedWatcher>>,
    _jsonl: std::sync::Mutex<Option<notify::RecommendedWatcher>>,
}

/// Load sharing settings from the frontend store into the SharingManager.
#[tauri::command]
fn load_sharing_settings(
    sharing: tauri::State<'_, Arc<sharing_manager::SharingManager>>,
    enabled: bool,
    display_name: String,
    share_code: String,
    secret_token: Option<String>,
    friends_json: Option<String>,
) {
    sharing.load_from_settings(
        enabled,
        &display_name,
        &share_code,
        secret_token.as_deref(),
        friends_json.as_deref(),
    );
}

/// Get all settings from the settings file.
#[tauri::command]
fn get_settings() -> AppSettings {
    let settings_path = paths::app_data_dir().join("settings.json");
    if let Ok(data) = std::fs::read_to_string(&settings_path) {
        serde_json::from_str(&data).unwrap_or_default()
    } else {
        AppSettings::default()
    }
}

/// Save a single setting key-value pair.
#[tauri::command]
fn save_setting(key: String, value: Value) -> Result<(), String> {
    let settings_path = paths::app_data_dir().join("settings.json");
    let mut settings: HashMap<String, Value> = if let Ok(data) = std::fs::read_to_string(&settings_path) {
        serde_json::from_str(&data).unwrap_or_default()
    } else {
        HashMap::new()
    };
    settings.insert(key, value);
    let json = serde_json::to_string_pretty(&settings).map_err(|e| e.to_string())?;
    std::fs::write(&settings_path, json).map_err(|e| e.to_string())?;
    Ok(())
}

/// Toggle launch at login (Windows startup registry, macOS launchd).
#[tauri::command]
fn set_autostart(enabled: bool) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        use std::process::Command;
        let exe_path = std::env::current_exe().map_err(|e| e.to_string())?;
        let exe_str = exe_path.to_string_lossy();
        if enabled {
            Command::new("reg")
                .args([
                    "add",
                    r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
                    "/v", "TokenBox",
                    "/t", "REG_SZ",
                    "/d", &exe_str,
                    "/f",
                ])
                .output()
                .map_err(|e| e.to_string())?;
        } else {
            Command::new("reg")
                .args([
                    "delete",
                    r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
                    "/v", "TokenBox",
                    "/f",
                ])
                .output()
                .map_err(|e| e.to_string())?;
        }
    }
    #[cfg(target_os = "macos")]
    {
        // On macOS, autostart is handled via launchd plist
        let plist_path = dirs::home_dir()
            .ok_or("No home dir")?
            .join("Library/LaunchAgents/com.tokenbox.windows.plist");
        if enabled {
            let exe_path = std::env::current_exe().map_err(|e| e.to_string())?;
            let plist = format!(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tokenbox.windows</string>
    <key>ProgramArguments</key>
    <array>
        <string>{}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>"#,
                exe_path.to_string_lossy()
            );
            std::fs::write(&plist_path, plist).map_err(|e| e.to_string())?;
        } else {
            let _ = std::fs::remove_file(&plist_path);
        }
    }
    // Save the setting
    save_setting("launchAtLogin".into(), Value::Bool(enabled)).ok();
    Ok(())
}

/// Re-scan all JSONL files (clears offsets and re-reads everything).
#[tauri::command]
fn rescan_jsonl(
    db: tauri::State<'_, Arc<database::Database>>,
    store: tauri::State<'_, Arc<data_store::DataStore>>,
    app: tauri::AppHandle,
) -> Result<(), String> {
    let projects_dir = paths::claude_projects_dir();
    if !projects_dir.exists() {
        return Ok(());
    }
    rescan_dir_recursive(&projects_dir, &db);
    let data = store.refresh();
    data_store::emit_token_data(&app, &data);
    Ok(())
}

/// Recursively scan a directory for JSONL files and insert events.
fn rescan_dir_recursive(dir: &std::path::Path, db: &Arc<database::Database>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            rescan_dir_recursive(&path, db);
        } else if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            let path_str = path.to_string_lossy().to_string();
            let (events, _) = jsonl_parser::parse_new_lines(&path_str, 0, None);
            for parsed in &events {
                if parsed.is_complete {
                    let _ = db.insert_token_event(&parsed.event);
                }
            }
        }
    }
}
