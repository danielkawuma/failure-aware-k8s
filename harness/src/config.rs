use anyhow::Result;
use serde::{
    Deserialize,
    Serialize,
};
use std::fs;

#[derive(
    Debug,
    Deserialize,
    Serialize,
    Clone,
)]
pub struct ServiceTarget {
    pub node: String,
    pub url: String,
}

#[derive(
    Debug,
    Deserialize,
    Clone,
)]
pub struct HarnessConfig {
    pub scenario: String,

    pub target_node: String,
    pub namespace: String,
    pub pod_label_selector: String,

    pub request_interval_ms: u64,
    pub request_timeout_ms: u64,

    pub service_targets: Vec<ServiceTarget>,
}

impl HarnessConfig {
    pub fn load(path: &str) -> Result<Self> {
        let contents =
            fs::read_to_string(path)?;

        let config: HarnessConfig =
            serde_json::from_str(
                &contents
            )?;

        Ok(config)
    }

    pub fn service_url_for_node(
        &self,
        node: &str,
    ) -> Option<String> {
        self.service_targets
            .iter()
            .find(
                |target| {
                    target.node == node
                }
            )
            .map(
                |target| {
                    target.url.clone()
                }
            )
    }
}