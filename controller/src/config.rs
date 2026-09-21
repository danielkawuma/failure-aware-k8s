use anyhow::Result;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;

#[derive(Debug, Deserialize, Clone)]
pub struct ControllerConfig {
    pub target_node: String,
    pub trigger_ready_status: String,

    pub verification_url: String,
    pub verification_timeout_ms: u64,
    pub verification_attempts: u32,
    pub verification_interval_ms: u64,

    pub workload_name: String,
    pub workload_type: String,
    pub duplication_sensitive: bool,
    pub service_criticality: String,

    pub namespace: String,
    pub pod_label_selector: String,

    pub recovery_candidate_node: String,
    pub required_cpu_millicores: u64,
    pub required_memory_mib: u64,
    pub required_node_labels: HashMap<String, String>,

    pub fencing_supported: bool,
    pub fencing_command: String,
}

impl ControllerConfig {
    pub fn load(
        path: &str,
    ) -> Result<Self> {
        let contents =
            fs::read_to_string(
                path
            )?;

        let config:
            ControllerConfig =
            serde_json::from_str(
                &contents
            )?;

        Ok(config)
    }
}