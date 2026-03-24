use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

const BASE_URL: &str = "https://tokenbox.club";

/// Response from the /register endpoint.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterResponse {
    pub share_code: String,
    pub secret_token: String,
    pub share_url: String,
}

/// Response from the /share/{code} endpoint.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeekResponse {
    pub display_name: String,
    pub today_tokens: i64,
    pub today_date: String,
    #[serde(default)]
    pub tokens_by_model: HashMap<String, i64>,
    #[serde(default)]
    pub week_by_model: HashMap<String, i64>,
    #[serde(default)]
    pub month_by_model: HashMap<String, i64>,
    #[serde(default)]
    pub all_time_by_model: HashMap<String, i64>,
    pub last_updated: Option<String>,
    pub last_token_change: Option<String>,
}

/// Push payload sent to the /push endpoint.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PushBody {
    share_code: String,
    today_tokens: i64,
    today_date: String,
    tokens_by_model: HashMap<String, i64>,
    week_by_model: HashMap<String, i64>,
    month_by_model: HashMap<String, i64>,
    all_time_by_model: HashMap<String, i64>,
    #[serde(rename = "displayName", skip_serializing_if = "Option::is_none")]
    display_name: Option<String>,
}

/// Sharing API client.
pub struct SharingClient {
    client: Client,
}

#[derive(Debug)]
pub enum SharingError {
    RateLimited,
    Http(u16),
    Network(String),
    Parse(String),
}

impl std::fmt::Display for SharingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RateLimited => write!(f, "Rate limited — will retry shortly"),
            Self::Http(code) => write!(f, "Sharing server returned HTTP {}", code),
            Self::Network(msg) => write!(f, "Network error: {}", msg),
            Self::Parse(msg) => write!(f, "Parse error: {}", msg),
        }
    }
}

impl SharingClient {
    pub fn new() -> Self {
        let client = Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .build()
            .unwrap_or_default();
        Self { client }
    }

    /// Register a new share identity.
    pub async fn register(&self, display_name: &str) -> Result<RegisterResponse, SharingError> {
        let mut body = HashMap::new();
        body.insert("displayName", display_name);

        let resp = self
            .client
            .post(format!("{}/register", BASE_URL))
            .json(&body)
            .send()
            .await
            .map_err(|e| SharingError::Network(e.to_string()))?;

        let status = resp.status().as_u16();
        if status == 429 {
            return Err(SharingError::RateLimited);
        }
        if !(200..300).contains(&status) {
            return Err(SharingError::Http(status));
        }

        resp.json::<RegisterResponse>()
            .await
            .map_err(|e| SharingError::Parse(e.to_string()))
    }

    /// Push token counts to the cloud.
    pub async fn push(
        &self,
        share_code: &str,
        secret_token: &str,
        today_tokens: i64,
        today_date: &str,
        tokens_by_model: HashMap<String, i64>,
        week_by_model: HashMap<String, i64>,
        month_by_model: HashMap<String, i64>,
        all_time_by_model: HashMap<String, i64>,
        display_name: Option<&str>,
    ) -> Result<(), SharingError> {
        let body = PushBody {
            share_code: share_code.to_string(),
            today_tokens,
            today_date: today_date.to_string(),
            tokens_by_model,
            week_by_model,
            month_by_model,
            all_time_by_model,
            display_name: display_name.map(String::from),
        };

        let resp = self
            .client
            .post(format!("{}/push", BASE_URL))
            .header("Authorization", format!("Bearer {}", secret_token))
            .json(&body)
            .send()
            .await
            .map_err(|e| SharingError::Network(e.to_string()))?;

        let status = resp.status().as_u16();
        if status == 429 {
            return Err(SharingError::RateLimited);
        }
        if !(200..300).contains(&status) {
            return Err(SharingError::Http(status));
        }

        Ok(())
    }

    /// Peek at a friend's current token count.
    pub async fn peek(&self, share_code: &str) -> Result<PeekResponse, SharingError> {
        let resp = self
            .client
            .get(format!("{}/share/{}", BASE_URL, share_code))
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(|e| SharingError::Network(e.to_string()))?;

        let status = resp.status().as_u16();
        if status == 429 {
            return Err(SharingError::RateLimited);
        }
        if !(200..300).contains(&status) {
            return Err(SharingError::Http(status));
        }

        resp.json::<PeekResponse>()
            .await
            .map_err(|e| SharingError::Parse(e.to_string()))
    }
}
