use crate::data_store::{emit_token_data, DataStore};
use crate::database::{Database, TokenEvent};
use crate::jsonl_parser;
use crate::paths;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};

/// Live event from status-relay hook (live.json).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiveEvent {
    pub ts: String,
    pub sid: Option<String>,
    pub model: String,
    pub cost: f64,
    #[serde(rename = "in")]
    pub input: i64,
    pub out: i64,
    pub cw: i64,
    pub cr: i64,
}

/// File offset tracker for incremental JSONL reading.
struct JsonlState {
    file_offsets: HashMap<PathBuf, u64>,
    initial_scan_complete: bool,
}

/// Start the live.json file watcher.
/// Watches for modifications and emits 'live-event' + inserts to DB.
pub fn start_live_watcher(
    app: AppHandle,
    db: Arc<Database>,
    store: Arc<DataStore>,
) -> Option<RecommendedWatcher> {
    let live_path = paths::live_json_path();
    let watch_dir = live_path.parent()?.to_path_buf();

    // Ensure the directory exists
    std::fs::create_dir_all(&watch_dir).ok();

    // Read current state if file exists
    read_and_emit_live(&app, &db, &store, &live_path);

    let live_path_clone = live_path.clone();
    let mut watcher = notify::recommended_watcher(move |res: Result<Event, notify::Error>| {
        if let Ok(event) = res {
            match event.kind {
                EventKind::Modify(_) | EventKind::Create(_) => {
                    for path in &event.paths {
                        if path.file_name().and_then(|n| n.to_str()) == Some("live.json") {
                            read_and_emit_live(&app, &db, &store, &live_path_clone);
                        }
                    }
                }
                _ => {}
            }
        }
    })
    .ok()?;

    watcher
        .watch(&watch_dir, RecursiveMode::NonRecursive)
        .ok()?;
    Some(watcher)
}

/// Read live.json, parse it, emit to frontend, and insert into DB.
fn read_and_emit_live(
    app: &AppHandle,
    db: &Arc<Database>,
    store: &Arc<DataStore>,
    path: &PathBuf,
) {
    let data = match std::fs::read_to_string(path) {
        Ok(d) => d,
        Err(_) => return,
    };
    let event: LiveEvent = match serde_json::from_str(&data) {
        Ok(e) => e,
        Err(_) => return,
    };

    // Emit to frontend
    let _ = app.emit("live-event", &event);

    // Feed realtime display delta
    store.add_realtime_delta(event.out, &event.model);
    store.set_live(true);

    // Insert into database
    let token_event = TokenEvent {
        id: None,
        timestamp: event.ts.clone(),
        source: "claude_code".to_string(),
        session_id: event.sid.clone(),
        project: None,
        model: event.model.clone(),
        input_tokens: event.input,
        output_tokens: event.out,
        cache_create: event.cw,
        cache_read: event.cr,
        cost_usd: if event.cost > 0.0 {
            Some(event.cost)
        } else {
            None
        },
    };
    let _ = db.insert_token_event(&token_event);

    // Trigger debounced refresh
    trigger_debounced_refresh(app.clone(), store.clone());
}

/// Start the JSONL file watcher for ~/.claude/projects/.
/// Watches for new/modified .jsonl files, parses new lines, inserts to DB.
pub fn start_jsonl_watcher(
    app: AppHandle,
    db: Arc<Database>,
    store: Arc<DataStore>,
) -> Option<RecommendedWatcher> {
    let projects_dir = paths::claude_projects_dir();
    if !projects_dir.exists() {
        std::fs::create_dir_all(&projects_dir).ok();
    }

    let state = Arc::new(Mutex::new(JsonlState {
        file_offsets: HashMap::new(),
        initial_scan_complete: false,
    }));

    // Initial scan — backfill existing files (suppress display events)
    {
        let db_clone = db.clone();
        let state_clone = state.clone();
        let dir = projects_dir.clone();
        std::thread::spawn(move || {
            scan_existing_files(&dir, &db_clone, &state_clone);
            state_clone.lock().unwrap().initial_scan_complete = true;
        });
    }

    let state_clone = state.clone();
    let mut watcher = notify::recommended_watcher(move |res: Result<Event, notify::Error>| {
        if let Ok(event) = res {
            match event.kind {
                EventKind::Modify(_) | EventKind::Create(_) => {
                    for path in &event.paths {
                        if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                            process_jsonl_file(
                                path,
                                &app,
                                &db,
                                &store,
                                &state_clone,
                            );
                        }
                    }
                }
                _ => {}
            }
        }
    })
    .ok()?;

    watcher
        .watch(&projects_dir, RecursiveMode::Recursive)
        .ok()?;
    Some(watcher)
}

/// Scan all existing JSONL files on startup for backfill.
fn scan_existing_files(dir: &PathBuf, db: &Arc<Database>, state: &Arc<Mutex<JsonlState>>) {
    if dir.is_dir() {
        scan_dir_recursive(dir, db, state);
    }
}

fn scan_dir_recursive(dir: &PathBuf, db: &Arc<Database>, state: &Arc<Mutex<JsonlState>>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            scan_dir_recursive(&path, db, state);
        } else if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            let path_str = path.to_string_lossy().to_string();
            let offset = state
                .lock()
                .unwrap()
                .file_offsets
                .get(&path)
                .copied()
                .unwrap_or(0);

            let (events, new_offset) = jsonl_parser::parse_new_lines(&path_str, offset, None);
            state
                .lock()
                .unwrap()
                .file_offsets
                .insert(path, new_offset);

            // During initial scan, only insert completed events (no display events)
            for parsed in &events {
                if parsed.is_complete {
                    let _ = db.insert_token_event(&parsed.event);
                }
            }
        }
    }
}

/// Process a single JSONL file — parse new lines, insert completed events, emit display events.
fn process_jsonl_file(
    path: &PathBuf,
    app: &AppHandle,
    db: &Arc<Database>,
    store: &Arc<DataStore>,
    state: &Arc<Mutex<JsonlState>>,
) {
    let path_str = path.to_string_lossy().to_string();
    let offset = state
        .lock()
        .unwrap()
        .file_offsets
        .get(path)
        .copied()
        .unwrap_or(0);

    let (events, new_offset) = jsonl_parser::parse_new_lines(&path_str, offset, None);
    state
        .lock()
        .unwrap()
        .file_offsets
        .insert(path.clone(), new_offset);

    if events.is_empty() {
        return;
    }

    let initial_scan_complete = state.lock().unwrap().initial_scan_complete;
    let mut had_inserts = false;

    for parsed in &events {
        // Emit display events only after initial scan
        if initial_scan_complete {
            // Emit realtime-delta for all events (including intermediate)
            let _ = app.emit("realtime-delta", &parsed.event);
            store.add_realtime_delta(parsed.event.output_tokens, &parsed.event.model);
        }

        // Only insert completed events into DB
        if parsed.is_complete {
            if let Ok(Some(_)) = db.insert_token_event(&parsed.event) {
                had_inserts = true;
            }
        }
    }

    if had_inserts {
        trigger_debounced_refresh(app.clone(), store.clone());
    }
}

/// Trigger a 500ms debounced refresh.
fn trigger_debounced_refresh(app: AppHandle, store: Arc<DataStore>) {
    if !store.request_debounced_refresh() {
        return; // Already pending
    }
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(500));
        store.clear_debounce();
        let data = store.refresh();
        emit_token_data(&app, &data);
    });
}
