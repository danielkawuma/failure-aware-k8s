use anyhow::Result;
use serde::Deserialize;
use std::fs;

#[derive(Debug, Deserialize, Clone)]
pub struct HarnessConfig {
    pub scenario: String,
    pub target_url: String,
    pub target_node: String,
    pub namespace: String,
    pub pod_label_selector: String,
    pub request_interval_ms: u64,
    pub request_timeout_ms: u64,
}

impl HarnessConfig {
    pub fn load(path: &str) -> Result<Self> {
        let contents = fs::read_to_string(path)?;
        let config: HarnessConfig = serde_json::from_str(&contents)?;
        Ok(config)
    }
}