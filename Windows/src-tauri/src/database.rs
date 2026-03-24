use rusqlite::{params, Connection, Result as SqlResult};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Mutex;

/// Raw token event from JSONL logs or hooks.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenEvent {
    pub id: Option<i64>,
    pub timestamp: String,
    pub source: String,
    pub session_id: Option<String>,
    pub project: Option<String>,
    pub model: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_create: i64,
    pub cache_read: i64,
    pub cost_usd: Option<f64>,
}

/// Pre-aggregated daily rollup.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DailySummary {
    pub date: String,
    pub source: String,
    pub model: String,
    pub total_input: i64,
    pub total_output: i64,
    pub total_cache_read: i64,
    pub total_cache_write: i64,
    pub total_cost: Option<f64>,
    pub session_count: i64,
}

/// Per-model token breakdown.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelBreakdown {
    pub model: String,
    pub output_tokens: i64,
    pub input_tokens: i64,
    pub cache_read: i64,
    pub cache_create: i64,
}

/// Thread-safe database wrapper.
pub struct Database {
    conn: Mutex<Connection>,
}

impl Database {
    /// Open or create the database at the given path.
    pub fn open(path: &Path) -> SqlResult<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let conn = Connection::open(path)?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        let db = Self {
            conn: Mutex::new(conn),
        };
        db.create_tables()?;
        Ok(db)
    }

    /// In-memory database for testing.
    #[allow(dead_code)]
    pub fn open_in_memory() -> SqlResult<Self> {
        let conn = Connection::open_in_memory()?;
        let db = Self {
            conn: Mutex::new(conn),
        };
        db.create_tables()?;
        Ok(db)
    }

    fn create_tables(&self) -> SqlResult<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS token_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                source TEXT NOT NULL,
                session_id TEXT,
                project TEXT,
                model TEXT NOT NULL,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                cache_create INTEGER DEFAULT 0,
                cache_read INTEGER DEFAULT 0,
                cost_usd REAL,
                UNIQUE(timestamp, session_id, model)
            );

            CREATE TABLE IF NOT EXISTS daily_summary (
                date TEXT NOT NULL,
                source TEXT NOT NULL,
                model TEXT NOT NULL,
                total_input INTEGER DEFAULT 0,
                total_output INTEGER DEFAULT 0,
                total_cache_r INTEGER DEFAULT 0,
                total_cache_w INTEGER DEFAULT 0,
                total_cost REAL,
                session_count INTEGER DEFAULT 0,
                PRIMARY KEY (date, source, model)
            );

            CREATE TABLE IF NOT EXISTS config (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            ",
        )?;
        Ok(())
    }

    // ── Token Events ──────────────────────────────────────────────

    /// Insert a token event. Returns the row ID if inserted, None if dedup conflict.
    pub fn insert_token_event(&self, event: &TokenEvent) -> SqlResult<Option<i64>> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT OR IGNORE INTO token_events
             (timestamp, source, session_id, project, model,
              input_tokens, output_tokens, cache_create, cache_read, cost_usd)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                event.timestamp,
                event.source,
                event.session_id,
                event.project,
                event.model,
                event.input_tokens,
                event.output_tokens,
                event.cache_create,
                event.cache_read,
                event.cost_usd,
            ],
        )?;
        if conn.changes() > 0 {
            Ok(Some(conn.last_insert_rowid()))
        } else {
            Ok(None)
        }
    }

    /// Count output tokens in a date range, optionally filtered by model substring.
    pub fn total_tokens(
        &self,
        from: Option<&str>,
        to: Option<&str>,
        model_filter: Option<&str>,
    ) -> SqlResult<i64> {
        let conn = self.conn.lock().unwrap();
        let mut sql =
            "SELECT COALESCE(SUM(output_tokens), 0) FROM token_events WHERE 1=1".to_string();
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(f) = from {
            sql.push_str(&format!(" AND timestamp >= ?{}", param_values.len() + 1));
            param_values.push(Box::new(f.to_string()));
        }
        if let Some(t) = to {
            sql.push_str(&format!(" AND timestamp < ?{}", param_values.len() + 1));
            param_values.push(Box::new(t.to_string()));
        }
        if let Some(mf) = model_filter {
            let escaped = mf.replace('%', "\\%").replace('_', "\\_");
            sql.push_str(&format!(
                " AND model LIKE ?{} ESCAPE '\\'",
                param_values.len() + 1
            ));
            param_values.push(Box::new(format!("%{}%", escaped)));
        }

        let params_ref: Vec<&dyn rusqlite::types::ToSql> =
            param_values.iter().map(|p| p.as_ref()).collect();
        conn.query_row(&sql, params_ref.as_slice(), |row| row.get(0))
    }

    /// Per-model breakdown for a date range.
    pub fn tokens_by_model(
        &self,
        from: Option<&str>,
        to: Option<&str>,
    ) -> SqlResult<Vec<ModelBreakdown>> {
        let conn = self.conn.lock().unwrap();
        let mut sql = "SELECT model,
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(cache_read), 0),
                COALESCE(SUM(cache_create), 0)
             FROM token_events WHERE 1=1"
            .to_string();
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(f) = from {
            sql.push_str(&format!(" AND timestamp >= ?{}", param_values.len() + 1));
            param_values.push(Box::new(f.to_string()));
        }
        if let Some(t) = to {
            sql.push_str(&format!(" AND timestamp < ?{}", param_values.len() + 1));
            param_values.push(Box::new(t.to_string()));
        }
        sql.push_str(" GROUP BY model ORDER BY COALESCE(SUM(output_tokens), 0) DESC");

        let params_ref: Vec<&dyn rusqlite::types::ToSql> =
            param_values.iter().map(|p| p.as_ref()).collect();
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_ref.as_slice(), |row| {
            Ok(ModelBreakdown {
                model: row.get(0)?,
                output_tokens: row.get(1)?,
                input_tokens: row.get(2)?,
                cache_read: row.get(3)?,
                cache_create: row.get(4)?,
            })
        })?;
        rows.collect()
    }

    /// Query token events in a date range.
    pub fn query_token_events(
        &self,
        from: Option<&str>,
        to: Option<&str>,
    ) -> SqlResult<Vec<TokenEvent>> {
        let conn = self.conn.lock().unwrap();
        let mut sql = "SELECT id, timestamp, source, session_id, project, model,
             input_tokens, output_tokens, cache_create, cache_read, cost_usd
             FROM token_events WHERE 1=1"
            .to_string();
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(f) = from {
            sql.push_str(&format!(" AND timestamp >= ?{}", param_values.len() + 1));
            param_values.push(Box::new(f.to_string()));
        }
        if let Some(t) = to {
            sql.push_str(&format!(" AND timestamp < ?{}", param_values.len() + 1));
            param_values.push(Box::new(t.to_string()));
        }
        sql.push_str(" ORDER BY timestamp DESC");

        let params_ref: Vec<&dyn rusqlite::types::ToSql> =
            param_values.iter().map(|p| p.as_ref()).collect();
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_ref.as_slice(), |row| {
            Ok(TokenEvent {
                id: row.get(0)?,
                timestamp: row.get(1)?,
                source: row.get(2)?,
                session_id: row.get(3)?,
                project: row.get(4)?,
                model: row.get(5)?,
                input_tokens: row.get(6)?,
                output_tokens: row.get(7)?,
                cache_create: row.get(8)?,
                cache_read: row.get(9)?,
                cost_usd: row.get(10)?,
            })
        })?;
        rows.collect()
    }

    /// Distinct session count for a date range.
    pub fn session_count(&self, from: &str, to: &str) -> SqlResult<i64> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT COUNT(DISTINCT session_id) FROM token_events
             WHERE timestamp >= ?1 AND timestamp < ?2",
            params![from, to],
            |row| row.get(0),
        )
    }

    // ── Daily Summary ─────────────────────────────────────────────

    /// Upsert a daily summary rollup.
    pub fn upsert_daily_rollup(&self, summary: &DailySummary) -> SqlResult<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT OR REPLACE INTO daily_summary
             (date, source, model, total_input, total_output,
              total_cache_r, total_cache_w, total_cost, session_count)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                summary.date,
                summary.source,
                summary.model,
                summary.total_input,
                summary.total_output,
                summary.total_cache_read,
                summary.total_cache_write,
                summary.total_cost,
                summary.session_count,
            ],
        )?;
        Ok(())
    }

    /// Daily token history for charting.
    pub fn daily_history(
        &self,
        from: &str,
        to: &str,
    ) -> SqlResult<Vec<(String, i64)>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT date,
                    COALESCE(SUM(total_input), 0) +
                    COALESCE(SUM(total_output), 0) +
                    COALESCE(SUM(total_cache_r), 0) +
                    COALESCE(SUM(total_cache_w), 0)
             FROM daily_summary
             WHERE date >= ?1 AND date <= ?2
             GROUP BY date ORDER BY date ASC",
        )?;
        let rows = stmt.query_map(params![from, to], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;
        rows.collect()
    }

    // ── Config ────────────────────────────────────────────────────

    pub fn get_config(&self, key: &str) -> SqlResult<Option<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT value FROM config WHERE key = ?1")?;
        let mut rows = stmt.query(params![key])?;
        match rows.next()? {
            Some(row) => Ok(Some(row.get(0)?)),
            None => Ok(None),
        }
    }

    pub fn set_config(&self, key: &str, value: &str) -> SqlResult<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT OR REPLACE INTO config (key, value) VALUES (?1, ?2)",
            params![key, value],
        )?;
        Ok(())
    }
}
