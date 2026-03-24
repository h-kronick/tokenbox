use std::path::PathBuf;
use std::sync::OnceLock;

static APP_DATA: OnceLock<PathBuf> = OnceLock::new();

/// Application data directory.
/// Windows: %APPDATA%\TokenBox
/// macOS:   ~/Library/Application Support/TokenBox
pub fn app_data_dir() -> &'static PathBuf {
    APP_DATA.get_or_init(|| {
        let base = if cfg!(target_os = "windows") {
            std::env::var("APPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(|_| dirs::home_dir().unwrap_or_default())
        } else {
            dirs::home_dir()
                .unwrap_or_default()
                .join("Library")
                .join("Application Support")
        };
        let dir = base.join("TokenBox");
        std::fs::create_dir_all(&dir).ok();
        dir
    })
}

/// Claude Code projects directory: ~/.claude/projects/
pub fn claude_projects_dir() -> PathBuf {
    let dir = dirs::home_dir()
        .unwrap_or_default()
        .join(".claude")
        .join("projects");
    std::fs::create_dir_all(&dir).ok();
    dir
}

/// Path to live.json for real-time streaming events.
pub fn live_json_path() -> PathBuf {
    app_data_dir().join("live.json")
}

/// Path to the SQLite database.
pub fn db_path() -> PathBuf {
    app_data_dir().join("tokenbox.db")
}
