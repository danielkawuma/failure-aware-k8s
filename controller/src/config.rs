use anyhow::{Context, Result, bail};
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

    #[serde(default = "default_api_timeout")]
    pub kubernetes_api_timeout_ms: u64,

    #[serde(default = "default_resource_timeout")]
    pub resource_evaluation_timeout_ms: u64,

    #[serde(default = "default_enforcement_timeout")]
    pub enforcement_timeout_ms: u64,

    #[serde(default = "default_fencing_timeout")]
    pub fencing_timeout_ms: u64,
}

fn default_api_timeout() -> u64 {
    3000
}

fn default_resource_timeout() -> u64 {
    10000
}

fn default_enforcement_timeout() -> u64 {
    15000
}

fn default_fencing_timeout() -> u64 {
    30000
}

impl ControllerConfig {
    pub fn load(path: &str) -> Result<Self> {
        let contents = fs::read_to_string(path)
            .with_context(|| format!("Failed to read controller config: {path}"))?;

        let config: ControllerConfig = serde_json::from_str(&contents)
            .with_context(|| format!("Invalid controller config: {path}"))?;

        config.validate()?;

        Ok(config)
    }

    fn validate(&self) -> Result<()> {
        if self.target_node.trim().is_empty() {
            bail!("target_node cannot be empty");
        }

        if self.namespace.trim().is_empty() {
            bail!("namespace cannot be empty");
        }

        if self.pod_label_selector.trim().is_empty() {
            bail!("pod_label_selector cannot be empty");
        }

        if self.verification_url.trim().is_empty() {
            bail!("verification_url cannot be empty");
        }

        if self.verification_attempts == 0 {
            bail!("verification_attempts must be positive");
        }

        for (name, value) in [
            ("verification_timeout_ms", self.verification_timeout_ms),
            ("kubernetes_api_timeout_ms", self.kubernetes_api_timeout_ms),
            (
                "resource_evaluation_timeout_ms",
                self.resource_evaluation_timeout_ms,
            ),
            ("enforcement_timeout_ms", self.enforcement_timeout_ms),
            ("fencing_timeout_ms", self.fencing_timeout_ms),
        ] {
            if value == 0 {
                bail!("{name} must be greater than zero");
            }
        }

        if self.resource_evaluation_timeout_ms < self.kubernetes_api_timeout_ms {
            bail!(
                "resource evaluation timeout must be at least \
                 as large as the individual API timeout"
            );
        }

        if self.duplication_sensitive
            && self.fencing_supported
            && self.fencing_command.trim().is_empty()
        {
            bail!(
                "duplication-sensitive recovery requires a \
                 configured fencing command when fencing \
                 support is enabled"
            );
        }

        Ok(())
    }
}
