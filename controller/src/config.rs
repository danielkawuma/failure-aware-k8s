use anyhow::Result;
use serde::Deserialize;
use std::fs;

#[derive(Debug, Deserialize, Clone)]
pub struct ControllerConfig {
    pub target_node: String,
    pub trigger_ready_status: String,
    pub verification_url: String,
    pub verification_timeout_ms: u64,
}

impl ControllerConfig {
    pub fn load(path: &str) -> Result<Self> {
        let contents = fs::read_to_string(path)?;

        let config: ControllerConfig =
            serde_json::from_str(&contents)?;

        Ok(config)
    }
}