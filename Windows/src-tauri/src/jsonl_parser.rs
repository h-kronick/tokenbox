use crate::database::TokenEvent;
use serde_json::Value;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

/// Result of parsing a single JSONL line.
pub struct ParsedEvent {
    pub event: TokenEvent,
    /// True if stop_reason is set (completed event → store in DB).
    /// False for intermediate streaming events (display only).
    pub is_complete: bool,
}

/// Parse a single JSONL line into a TokenEvent, if it contains token usage data.
pub fn parse_line(line: &str, project: Option<&str>, session_id: Option<&str>) -> Option<ParsedEvent> {
    if line.trim().is_empty() {
        return None;
    }
    let json: Value = serde_json::from_str(line).ok()?;
    let usage = extract_usage(&json);
    if !usage.has_tokens() {
        return None;
    }

    let timestamp = extract_timestamp(&json);
    let model = extract_model(&json);
    let sid = extract_session_id(&json).or_else(|| session_id.map(String::from));
    let cost = extract_cost(&json);
    let is_complete = is_complete_event(&json);

    Some(ParsedEvent {
        event: TokenEvent {
            id: None,
            timestamp,
            source: "claude_code".to_string(),
            session_id: sid,
            project: project.map(String::from),
            model,
            input_tokens: usage.input,
            output_tokens: usage.output,
            cache_create: usage.cache_create,
            cache_read: usage.cache_read,
            cost_usd: cost,
        },
        is_complete,
    })
}

/// Parse new lines from a file starting at the given byte offset.
/// Returns parsed events and the new byte offset.
pub fn parse_new_lines(
    path: &str,
    offset: u64,
    project: Option<&str>,
) -> (Vec<ParsedEvent>, u64) {
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return (Vec::new(), offset),
    };

    if file.seek(SeekFrom::Start(offset)).is_err() {
        return (Vec::new(), offset);
    }

    let mut buf = String::new();
    let bytes_read = match file.read_to_string(&mut buf) {
        Ok(n) => n as u64,
        Err(_) => return (Vec::new(), offset),
    };
    let new_offset = offset + bytes_read;

    let session_id = session_id_from_path(path);
    let proj_from_path = project_name_from_path(path);
    let proj = project.or(proj_from_path.as_deref()).map(String::from);

    let events: Vec<ParsedEvent> = buf
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|line| parse_line(line, proj.as_deref(), session_id.as_deref()))
        .collect();

    (events, new_offset)
}

// ── Usage extraction ──────────────────────────────────────────────

struct Usage {
    input: i64,
    output: i64,
    cache_create: i64,
    cache_read: i64,
}

impl Usage {
    fn has_tokens(&self) -> bool {
        self.input > 0 || self.output > 0 || self.cache_create > 0 || self.cache_read > 0
    }
}

fn extract_usage(json: &Value) -> Usage {
    // Direct fields
    let mut u = Usage {
        input: json["input_tokens"].as_i64().unwrap_or(0),
        output: json["output_tokens"].as_i64().unwrap_or(0),
        cache_create: json["cache_creation_input_tokens"].as_i64().unwrap_or(0),
        cache_read: json["cache_read_input_tokens"].as_i64().unwrap_or(0),
    };
    if u.has_tokens() {
        return u;
    }

    // Nested under "usage"
    if let Some(usage) = json.get("usage") {
        u = usage_from_obj(usage);
        if u.has_tokens() {
            return u;
        }
    }

    // Nested under "message" → "usage"
    if let Some(msg) = json.get("message") {
        if let Some(usage) = msg.get("usage") {
            u = usage_from_obj(usage);
            if u.has_tokens() {
                return u;
            }
        }
    }

    // Nested under "result" → "usage"
    if let Some(result) = json.get("result") {
        if let Some(usage) = result.get("usage") {
            u = usage_from_obj(usage);
            if u.has_tokens() {
                return u;
            }
        }
    }

    // Nested under "response" → "usage"
    if let Some(resp) = json.get("response") {
        if let Some(usage) = resp.get("usage") {
            u = usage_from_obj(usage);
            if u.has_tokens() {
                return u;
            }
        }
    }

    // Context window format (from Status hook)
    if let Some(cw) = json.get("context_window") {
        if let Some(cu) = cw.get("current_usage") {
            u = usage_from_obj(cu);
            if u.has_tokens() {
                return u;
            }
        }
    }

    u
}

fn usage_from_obj(v: &Value) -> Usage {
    Usage {
        input: v["input_tokens"].as_i64().unwrap_or(0),
        output: v["output_tokens"].as_i64().unwrap_or(0),
        cache_create: v["cache_creation_input_tokens"].as_i64().unwrap_or(0),
        cache_read: v["cache_read_input_tokens"].as_i64().unwrap_or(0),
    }
}

fn extract_timestamp(json: &Value) -> String {
    if let Some(ts) = json["timestamp"].as_str() {
        return ts.to_string();
    }
    if let Some(ts) = json["ts"].as_str() {
        return ts.to_string();
    }
    chrono::Utc::now().to_rfc3339()
}

fn extract_model(json: &Value) -> String {
    if let Some(m) = json["model"].as_str() {
        return m.to_string();
    }
    if let Some(obj) = json["model"].as_object() {
        if let Some(id) = obj.get("id").and_then(|v| v.as_str()) {
            return id.to_string();
        }
        if let Some(id) = obj.get("api_model_id").and_then(|v| v.as_str()) {
            return id.to_string();
        }
    }
    if let Some(msg) = json.get("message") {
        if let Some(m) = msg["model"].as_str() {
            return m.to_string();
        }
    }
    "unknown".to_string()
}

fn extract_session_id(json: &Value) -> Option<String> {
    json["session_id"]
        .as_str()
        .or_else(|| json["sid"].as_str())
        .map(String::from)
}

fn extract_cost(json: &Value) -> Option<f64> {
    if let Some(c) = json["costUSD"].as_f64() {
        return Some(c);
    }
    if let Some(c) = json["cost"].as_f64() {
        return Some(c);
    }
    if let Some(obj) = json["cost"].as_object() {
        if let Some(c) = obj.get("total_cost_usd").and_then(|v| v.as_f64()) {
            return Some(c);
        }
    }
    None
}

/// Check if a JSON event represents a completed message (has stop_reason set).
fn is_complete_event(json: &Value) -> bool {
    if let Some(msg) = json.get("message") {
        if let Some(msg_obj) = msg.as_object() {
            match msg_obj.get("stop_reason") {
                None => return false,
                Some(v) if v.is_null() => return false,
                _ => return true,
            }
        }
    }
    true // Non-message events are considered complete
}

// ── Path helpers ──────────────────────────────────────────────────

/// Extract session ID from JSONL filename.
fn session_id_from_path(path: &str) -> Option<String> {
    std::path::Path::new(path)
        .file_stem()
        .and_then(|s| s.to_str())
        .map(String::from)
}

/// Extract project name from JSONL path.
/// Path format: ~/.claude/projects/<encoded-project-path>/<session>.jsonl
fn project_name_from_path(path: &str) -> Option<String> {
    let components: Vec<&str> = path.split(['/', '\\']).collect();
    if let Some(idx) = components.iter().position(|&c| c == "projects") {
        if idx + 1 < components.len() {
            let encoded = components[idx + 1];
            // Return the last meaningful segment of the directory name
            if let Some(last) = encoded.rsplit('-').next() {
                if !last.is_empty() {
                    return Some(last.to_string());
                }
            }
            return Some(encoded.to_string());
        }
    }
    None
}
