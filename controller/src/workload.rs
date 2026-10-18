use anyhow::{Result, anyhow};
use k8s_openapi::api::core::v1::Pod;
use kube::{Api, Client, api::ListParams};
use std::time::Duration;
use tokio::time::timeout;

pub const DUPLICATION_SENSITIVE_LABEL: &str = "failure-aware.io/duplication-sensitive";

#[derive(Debug, Clone, PartialEq)]
pub enum WorkloadType {
    Stateless,
    Stateful,
}

#[derive(Debug, Clone)]
pub struct WorkloadAwareness {
    pub name: String,
    pub workload_type: WorkloadType,
    pub duplication_sensitive: bool,
}

impl WorkloadType {
    pub fn from_str(value: &str) -> Self {
        match value.to_lowercase().as_str() {
            "stateful" => WorkloadType::Stateful,
            _ => WorkloadType::Stateless,
        }
    }
}

impl WorkloadAwareness {
    pub fn new(name: String, workload_type: String, duplication_sensitive: bool) -> Self {
        Self {
            name,
            workload_type: WorkloadType::from_str(&workload_type),
            duplication_sensitive,
        }
    }

    pub fn with_duplication_sensitivity(&self, duplication_sensitive: bool) -> Self {
        let mut updated = self.clone();
        updated.duplication_sensitive = duplication_sensitive;
        updated
    }
}

fn parse_duplication_label(value: &str) -> Result<bool> {
    match value {
        "true" => Ok(true),
        "false" => Ok(false),
        other => Err(anyhow!(
            "Invalid {} label value: {}",
            DUPLICATION_SENSITIVE_LABEL,
            other
        )),
    }
}

fn resolve_pod_sensitivity(pods: &[Pod], target_node: &str, fallback: bool) -> Result<bool> {
    let mut observed: Option<bool> = None;
    let mut found_target = false;

    for pod in pods {
        let scheduled_node = pod.spec.as_ref().and_then(|spec| spec.node_name.as_deref());

        if scheduled_node != Some(target_node) {
            continue;
        }

        if pod.metadata.deletion_timestamp.is_some() {
            continue;
        }

        found_target = true;

        let label = pod
            .metadata
            .labels
            .as_ref()
            .and_then(|labels| labels.get(DUPLICATION_SENSITIVE_LABEL));

        let Some(value) = label else {
            continue;
        };

        let sensitivity = parse_duplication_label(value)?;

        if let Some(previous) = observed {
            if previous != sensitivity {
                return Err(anyhow!(
                    "Conflicting duplication-sensitive labels \
                     on target workload Pods"
                ));
            }
        }

        observed = Some(sensitivity);
    }

    if !found_target {
        return Err(anyhow!(
            "No matching workload Pod found on target node {}",
            target_node
        ));
    }

    Ok(observed.unwrap_or(fallback))
}

pub async fn discover_workload_awareness(
    client: Client,
    namespace: &str,
    pod_label_selector: &str,
    target_node: &str,
    configured: &WorkloadAwareness,
    api_timeout_ms: u64,
) -> Result<WorkloadAwareness> {
    if api_timeout_ms == 0 {
        return Err(anyhow!("Workload discovery timeout must be positive"));
    }

    let pods: Api<Pod> = Api::namespaced(client, namespace);

    let params = ListParams::default().labels(pod_label_selector);

    let response = timeout(Duration::from_millis(api_timeout_ms), pods.list(&params))
        .await
        .map_err(|_| {
            anyhow!(
                "Workload label discovery timed out after {} ms",
                api_timeout_ms
            )
        })??;

    let sensitivity = resolve_pod_sensitivity(
        &response.items,
        target_node,
        configured.duplication_sensitive,
    )?;

    println!(
        "[WORKLOAD] name={} | target_node={} | duplication_sensitive={}",
        configured.name, target_node, sensitivity
    );

    Ok(configured.with_duplication_sensitivity(sensitivity))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn true_label_is_recognized() {
        assert!(parse_duplication_label("true").unwrap());
    }

    #[test]
    fn false_label_is_recognized() {
        assert!(!parse_duplication_label("false").unwrap());
    }

    #[test]
    fn invalid_label_is_rejected() {
        assert!(parse_duplication_label("yes").is_err());
    }

    #[test]
    fn constructor_preserves_configuration() {
        let workload = WorkloadAwareness::new("test-db".to_string(), "stateful".to_string(), true);

        assert_eq!(workload.workload_type, WorkloadType::Stateful);

        assert!(workload.duplication_sensitive);
    }

    #[test]
    fn sensitivity_override_preserves_metadata() {
        let workload = WorkloadAwareness::new("test-db".to_string(), "stateful".to_string(), false);

        let updated = workload.with_duplication_sensitivity(true);

        assert!(updated.duplication_sensitive);
        assert!(!workload.duplication_sensitive);
        assert_eq!(updated.name, workload.name);
    }

    #[test]
    fn missing_target_is_not_treated_as_safe() {
        assert!(resolve_pod_sensitivity(&[], "worker1", false).is_err());
    }
}
