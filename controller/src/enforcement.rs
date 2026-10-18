use anyhow::{Result, anyhow};
use chrono::Utc;
use k8s_openapi::api::{
    apps::v1::{Deployment, ReplicaSet, StatefulSet},
    core::v1::Pod,
};
use kube::{
    Api, Client,
    api::{DeleteParams, ListParams, Patch, PatchParams},
};
use serde_json::json;
use std::collections::BTreeMap;
use std::env;
use std::future::Future;
use std::time::Duration;
use tokio::time::{sleep, timeout};

use crate::decision::{DecisionResult, RecoveryDecision};
use crate::fencing::{self, FencingState};
use crate::resource;

#[derive(Debug, Clone, PartialEq)]
pub enum EnforcementAction {
    PreserveExisting,
    RecoveryReleased,
    RecoveryBlockedFencingFailed,
    RecoveryBlockedPlacementConstraintFailed,
}

#[derive(Debug, Clone)]
pub struct EnforcementResult {
    pub action: EnforcementAction,
    pub enforced: bool,
    pub message: String,
}

const DEFAULT_API_TIMEOUT_MS: u64 = 3000;
const DEFAULT_FENCING_TIMEOUT_MS: u64 = 30000;
const DEFAULT_RECOVERY_TIMEOUT_MS: u64 = 180000;

const HOSTNAME_KEY: &str = "kubernetes.io/hostname";
const MANAGED_KEY: &str = "failure-aware.io/placement-managed";
const CANDIDATE_KEY: &str = "failure-aware.io/placement-candidate";
const ORIGINAL_KEY: &str = "failure-aware.io/placement-original-hostname";
const CLEANUP_KEY: &str = "failure-aware.io/placement-cleanup";

fn configured_timeout(name: &str, default: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

fn api_timeout_ms() -> u64 {
    configured_timeout("FAILURE_AWARE_API_TIMEOUT_MS", DEFAULT_API_TIMEOUT_MS)
}

fn fencing_timeout_ms() -> u64 {
    configured_timeout(
        "FAILURE_AWARE_FENCING_TIMEOUT_MS",
        DEFAULT_FENCING_TIMEOUT_MS,
    )
}

fn recovery_timeout_ms() -> u64 {
    configured_timeout(
        "FAILURE_AWARE_RECOVERY_TIMEOUT_MS",
        DEFAULT_RECOVERY_TIMEOUT_MS,
    )
}

async fn bounded_api<T, F>(operation: &str, future: F) -> Result<T>
where
    F: Future<Output = Result<T>>,
{
    let duration = Duration::from_millis(api_timeout_ms());

    timeout(duration, future)
        .await
        .map_err(|_| anyhow!("{} timed out", operation))?
        .map_err(|error| anyhow!("{} failed: {}", operation, error))
}

fn blocked(action: EnforcementAction, message: String) -> EnforcementResult {
    EnforcementResult {
        action,
        enforced: false,
        message,
    }
}

fn controller_owner(pod: &Pod) -> Option<(String, String)> {
    pod.metadata
        .owner_references
        .as_ref()?
        .iter()
        .find(|owner| owner.controller.unwrap_or(false))
        .map(|owner| (owner.kind.clone(), owner.name.clone()))
}

fn hostname_selector(selector: Option<&BTreeMap<String, String>>) -> Option<String> {
    selector.and_then(|map| map.get(HOSTNAME_KEY)).cloned()
}

fn selector_string(labels: &BTreeMap<String, String>) -> Result<String> {
    if labels.is_empty() {
        return Err(anyhow!("Refusing cleanup with an empty workload selector"));
    }

    Ok(labels
        .iter()
        .map(|(key, value)| format!("{}={}", key, value))
        .collect::<Vec<_>>()
        .join(","))
}

async fn resolve_controller(
    client: Client,
    namespace: &str,
    pod: &Pod,
) -> Result<(String, String)> {
    let (kind, name) =
        controller_owner(pod).ok_or_else(|| anyhow!("Pod has no controller owner"))?;

    match kind.as_str() {
        "ReplicaSet" => {
            let api: Api<ReplicaSet> = Api::namespaced(client, namespace);

            let replica_set =
                bounded_api("get ReplicaSet", async { Ok(api.get(&name).await?) }).await?;

            let deployment = replica_set
                .metadata
                .owner_references
                .as_ref()
                .and_then(|owners| {
                    owners.iter().find(|owner| {
                        owner.controller.unwrap_or(false) && owner.kind == "Deployment"
                    })
                })
                .ok_or_else(|| anyhow!("ReplicaSet has no controlling Deployment"))?;

            Ok(("Deployment".to_string(), deployment.name.clone()))
        }

        "Deployment" | "StatefulSet" => Ok((kind, name)),

        other => Err(anyhow!("Unsupported controller kind: {}", other)),
    }
}

fn placement_patch(candidate: &str) -> serde_json::Value {
    json!({
        "metadata": {
            "annotations": {
                MANAGED_KEY: "true",
                CANDIDATE_KEY: candidate,
                ORIGINAL_KEY: "",
                CLEANUP_KEY: "pending"
            }
        },
        "spec": {
            "template": {
                "spec": {
                    "nodeSelector": {
                        HOSTNAME_KEY: candidate
                    }
                }
            }
        }
    })
}

fn validate_original_placement(original: Option<String>, candidate: &str) -> Result<bool> {
    match original {
        Some(existing) if existing == candidate => Ok(false),

        Some(existing) => Err(anyhow!(
            "Existing hostname constraint {} conflicts with candidate {}",
            existing,
            candidate
        )),

        None => Ok(true),
    }
}

async fn constrain_replacement_to_candidate(
    client: Client,
    namespace: &str,
    pod: &Pod,
    candidate: &str,
) -> Result<String> {
    let (kind, name) = resolve_controller(client.clone(), namespace, pod).await?;

    match kind.as_str() {
        "Deployment" => {
            let api: Api<Deployment> = Api::namespaced(client, namespace);

            let deployment =
                bounded_api("get Deployment", async { Ok(api.get(&name).await?) }).await?;

            let spec = deployment
                .spec
                .as_ref()
                .and_then(|s| s.template.spec.as_ref())
                .ok_or_else(|| anyhow!("Missing Pod template"))?;

            let original = hostname_selector(spec.node_selector.as_ref());

            if !validate_original_placement(original, candidate)? {
                return Ok(format!("Deployment/{}", name));
            }

            let patch = placement_patch(candidate);

            bounded_api("patch Deployment placement", async {
                Ok(api
                    .patch(&name, &PatchParams::default(), &Patch::Merge(&patch))
                    .await?)
            })
            .await?;
        }

        "StatefulSet" => {
            let api: Api<StatefulSet> = Api::namespaced(client, namespace);

            let statefulset =
                bounded_api("get StatefulSet", async { Ok(api.get(&name).await?) }).await?;

            let spec = statefulset
                .spec
                .as_ref()
                .and_then(|s| s.template.spec.as_ref())
                .ok_or_else(|| anyhow!("Missing Pod template"))?;

            let original = hostname_selector(spec.node_selector.as_ref());

            if !validate_original_placement(original, candidate)? {
                return Ok(format!("StatefulSet/{}", name));
            }

            let patch = placement_patch(candidate);

            bounded_api("patch StatefulSet placement", async {
                Ok(api
                    .patch(&name, &PatchParams::default(), &Patch::Merge(&patch))
                    .await?)
            })
            .await?;
        }

        _ => {
            return Err(anyhow!("Unsupported controller kind: {}", kind));
        }
    }

    println!(
        "[PLACEMENT] {} | workload={}/{} | candidate={} | cleanup=pending",
        Utc::now().to_rfc3339(),
        kind,
        name,
        candidate
    );

    Ok(format!("{}/{}", kind, name))
}

async fn wait_for_replacement(
    client: Client,
    namespace: &str,
    selector: &str,
    original_pod: &str,
    candidate: Option<&str>,
) -> Result<String> {
    let pods: Api<Pod> = Api::namespaced(client, namespace);

    let deadline = tokio::time::Instant::now() + Duration::from_millis(recovery_timeout_ms());

    loop {
        if tokio::time::Instant::now() >= deadline {
            return Err(anyhow!("Replacement readiness verification timed out"));
        }

        let list = bounded_api("list replacement Pods", async {
            Ok(pods.list(&ListParams::default().labels(selector)).await?)
        })
        .await?;

        for pod in list.items {
            let name = pod.metadata.name.as_deref().unwrap_or("");

            if name == original_pod {
                continue;
            }

            if pod.metadata.deletion_timestamp.is_some() {
                continue;
            }

            let Some(spec) = pod.spec.as_ref() else {
                continue;
            };

            if let Some(node) = candidate {
                if spec.node_name.as_deref() != Some(node) {
                    continue;
                }
            }

            let running = pod.status.as_ref().and_then(|s| s.phase.as_deref()) == Some("Running");

            let ready = pod
                .status
                .as_ref()
                .and_then(|s| s.conditions.as_ref())
                .map(|conditions| {
                    conditions
                        .iter()
                        .any(|condition| condition.type_ == "Ready" && condition.status == "True")
                })
                .unwrap_or(false);

            if running && ready {
                return Ok(name.to_string());
            }
        }

        sleep(Duration::from_secs(2)).await;
    }
}

async fn verify_application() -> Result<()> {
    let url = env::var("FAILURE_AWARE_RECOVERY_VERIFY_URL")
        .map_err(|_| anyhow!("FAILURE_AWARE_RECOVERY_VERIFY_URL is required"))?;

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()?;

    let deadline = tokio::time::Instant::now() + Duration::from_millis(recovery_timeout_ms());

    loop {
        let response = client.get(&url).send().await;

        if let Ok(response) = response {
            if response.status().is_success() {
                return Ok(());
            }
        }

        if tokio::time::Instant::now() >= deadline {
            return Err(anyhow!("Application recovery verification timed out"));
        }

        sleep(Duration::from_secs(2)).await;
    }
}

/*
 * Controlled placement-constraint cleanup.
 *
 * This operation is deliberately separate from recovery.
 *
 * It must be invoked only during a controlled maintenance
 * phase after the workload has been scaled to zero.
 *
 * It does not scale workloads, delete Pods, or initiate
 * another recovery.
 */
pub async fn reconcile_placement_constraint(
    client: Client,
    namespace: &str,
    kind: &str,
    name: &str,
) -> Result<bool> {
    let pods: Api<Pod> = Api::namespaced(client.clone(), namespace);

    let (replicas, annotations, selector, hostname, resource_version) = match kind {
        "Deployment" => {
            let api: Api<Deployment> = Api::namespaced(client.clone(), namespace);

            let workload = bounded_api("get Deployment for cleanup", async {
                Ok(api.get(name).await?)
            })
            .await?;

            let spec = workload
                .spec
                .as_ref()
                .ok_or_else(|| anyhow!("Missing Deployment spec"))?;

            let pod_spec = spec
                .template
                .spec
                .as_ref()
                .ok_or_else(|| anyhow!("Missing Pod template"))?;

            (
                spec.replicas.unwrap_or(1),
                workload.metadata.annotations.clone().unwrap_or_default(),
                selector_string(
                    spec.selector
                        .match_labels
                        .as_ref()
                        .ok_or_else(|| anyhow!("Deployment selector has no matchLabels"))?,
                )?,
                hostname_selector(pod_spec.node_selector.as_ref()),
                workload
                    .metadata
                    .resource_version
                    .clone()
                    .ok_or_else(|| anyhow!("Missing Deployment resourceVersion"))?,
            )
        }

        "StatefulSet" => {
            let api: Api<StatefulSet> = Api::namespaced(client.clone(), namespace);

            let workload = bounded_api("get StatefulSet for cleanup", async {
                Ok(api.get(name).await?)
            })
            .await?;

            let spec = workload
                .spec
                .as_ref()
                .ok_or_else(|| anyhow!("Missing StatefulSet spec"))?;

            let pod_spec = spec
                .template
                .spec
                .as_ref()
                .ok_or_else(|| anyhow!("Missing Pod template"))?;

            (
                spec.replicas.unwrap_or(1),
                workload.metadata.annotations.clone().unwrap_or_default(),
                selector_string(
                    spec.selector
                        .match_labels
                        .as_ref()
                        .ok_or_else(|| anyhow!("StatefulSet selector has no matchLabels"))?,
                )?,
                hostname_selector(pod_spec.node_selector.as_ref()),
                workload
                    .metadata
                    .resource_version
                    .clone()
                    .ok_or_else(|| anyhow!("Missing StatefulSet resourceVersion"))?,
            )
        }

        _ => {
            return Err(anyhow!("Unsupported cleanup controller: {}", kind));
        }
    };

    if annotations.get(MANAGED_KEY).map(String::as_str) != Some("true") {
        return Ok(false);
    }

    if annotations.get(CLEANUP_KEY).map(String::as_str) != Some("pending") {
        return Err(anyhow!("Placement cleanup is not marked pending"));
    }

    let candidate = annotations
        .get(CANDIDATE_KEY)
        .ok_or_else(|| anyhow!("Missing recorded recovery candidate"))?;

    if hostname.as_deref() != Some(candidate.as_str()) {
        return Err(anyhow!(
            "Current hostname selector differs from the recorded candidate"
        ));
    }

    if annotations.get(ORIGINAL_KEY).map(String::as_str) != Some("") {
        return Err(anyhow!(
            "Original hostname policy is not confirmed as absent"
        ));
    }

    if replicas != 0 {
        return Err(anyhow!(
            "Cleanup blocked: workload has {} desired replicas; scale to zero during controlled maintenance",
            replicas
        ));
    }

    let remaining = bounded_api("check Pods before placement cleanup", async {
        Ok(pods.list(&ListParams::default().labels(&selector)).await?)
    })
    .await?;

    if !remaining.items.is_empty() {
        return Err(anyhow!(
            "Cleanup blocked: {} matching Pods still exist",
            remaining.items.len()
        ));
    }

    let patch = json!({
        "metadata": {
            "resourceVersion": resource_version,
            "annotations": {
                MANAGED_KEY: null,
                CANDIDATE_KEY: null,
                ORIGINAL_KEY: null,
                CLEANUP_KEY: null
            }
        },
        "spec": {
            "template": {
                "spec": {
                    "nodeSelector": {
                        HOSTNAME_KEY: null
                    }
                }
            }
        }
    });

    match kind {
        "Deployment" => {
            let api: Api<Deployment> = Api::namespaced(client, namespace);

            bounded_api("cleanup Deployment placement", async {
                Ok(api
                    .patch(name, &PatchParams::default(), &Patch::Merge(&patch))
                    .await?)
            })
            .await?;
        }

        "StatefulSet" => {
            let api: Api<StatefulSet> = Api::namespaced(client, namespace);

            bounded_api("cleanup StatefulSet placement", async {
                Ok(api
                    .patch(name, &PatchParams::default(), &Patch::Merge(&patch))
                    .await?)
            })
            .await?;
        }

        _ => unreachable!(),
    }

    println!(
        "[PLACEMENT CLEANUP] {} | workload={}/{} | constraint_removed=true",
        Utc::now().to_rfc3339(),
        kind,
        name
    );

    Ok(true)
}

pub async fn enforce_decision(
    client: Client,
    decision: &DecisionResult,
    namespace: &str,
    pod_label_selector: &str,
    target_node: &str,
    fencing_supported: bool,
    fencing_command: &str,
) -> Result<EnforcementResult> {
    if decision.decision == RecoveryDecision::Preserve {
        return Ok(EnforcementResult {
            action: EnforcementAction::PreserveExisting,
            enforced: true,
            message: "Existing workload preserved".to_string(),
        });
    }

    if decision.fencing_required {
        let result = fencing::execute_fence_bounded(
            true,
            fencing_supported,
            fencing_command,
            fencing_timeout_ms(),
        )
        .await?;

        if result.state != FencingState::Succeeded {
            return Ok(blocked(
                EnforcementAction::RecoveryBlockedFencingFailed,
                format!("Fencing failed: {}", result.message),
            ));
        }

        println!(
            "[FENCING VERIFIED] {} | node={}",
            Utc::now().to_rfc3339(),
            target_node
        );
    }

    let pods: Api<Pod> = Api::namespaced(client.clone(), namespace);

    let list = bounded_api("list target Pods", async {
        Ok(pods
            .list(&ListParams::default().labels(pod_label_selector))
            .await?)
    })
    .await?;

    let target_pod = list
        .items
        .into_iter()
        .find(|pod| pod.spec.as_ref().and_then(|s| s.node_name.as_deref()) == Some(target_node));

    let Some(pod) = target_pod else {
        return Ok(blocked(
            EnforcementAction::RecoveryReleased,
            "No matching target Pod found".to_string(),
        ));
    };

    let pod_name = pod
        .metadata
        .name
        .clone()
        .ok_or_else(|| anyhow!("Pod has no name"))?;

    if let Some(candidate) = decision.selected_candidate.as_deref() {
        if candidate == target_node {
            return Ok(blocked(
                EnforcementAction::RecoveryBlockedPlacementConstraintFailed,
                "Recovery candidate equals target node".to_string(),
            ));
        }

        if let Err(error) =
            constrain_replacement_to_candidate(client.clone(), namespace, &pod, candidate).await
        {
            return Ok(blocked(
                EnforcementAction::RecoveryBlockedPlacementConstraintFailed,
                error.to_string(),
            ));
        }
    }

    bounded_api("delete preserved Pod", async {
        Ok(pods
            .delete(
                &pod_name,
                &DeleteParams {
                    grace_period_seconds: Some(0),
                    ..Default::default()
                },
            )
            .await?)
    })
    .await?;

    let replacement = wait_for_replacement(
        client,
        namespace,
        pod_label_selector,
        &pod_name,
        decision.selected_candidate.as_deref(),
    )
    .await;

    let replacement_name = match replacement {
        Ok(name) => name,
        Err(error) => {
            println!("[RECOVERY UNVERIFIED] {}", error);

            return Ok(blocked(
                EnforcementAction::RecoveryReleased,
                format!("Recovery initiated but not verified: {}", error),
            ));
        }
    };

    if let Err(error) = verify_application().await {
        println!("[APPLICATION VERIFICATION FAILED] {}", error);

        return Ok(blocked(
            EnforcementAction::RecoveryReleased,
            format!(
                "Replacement {} is Ready but application verification failed: {}",
                replacement_name, error
            ),
        ));
    }

    // Optional post-recovery reconciliation. Legacy experiments remain unchanged
    // unless FAILURE_AWARE_RECONCILE_COMMAND is explicitly configured.
    if decision.fencing_required {
        if let Ok(reconcile_command) = env::var("FAILURE_AWARE_RECONCILE_COMMAND") {
            if !reconcile_command.trim().is_empty() {
                println!("[RECONCILIATION] starting post-recovery safety checks");
                let outcome = timeout(
                    Duration::from_millis(configured_timeout(
                        "FAILURE_AWARE_RECONCILE_TIMEOUT_MS",
                        180_000,
                    )),
                    tokio::process::Command::new("sh")
                        .arg("-c")
                        .arg(&reconcile_command)
                        .kill_on_drop(true)
                        .output(),
                )
                .await;
                match outcome {
                    Ok(Ok(output)) if output.status.success() => {
                        println!(
                            "[RECONCILIATION VERIFIED] {}",
                            String::from_utf8_lossy(&output.stdout).trim()
                        );
                    }
                    Ok(Ok(output)) => {
                        eprintln!(
                            "[RECONCILIATION PENDING] exit={} stderr={}",
                            output.status,
                            String::from_utf8_lossy(&output.stderr).trim()
                        );
                    }
                    Ok(Err(error)) => {
                        eprintln!("[RECONCILIATION PENDING] execution error: {}", error)
                    }
                    Err(_) => {
                        eprintln!("[RECONCILIATION PENDING] timed out; fence must remain active")
                    }
                }
            }
        }
    }

    println!(
        "[RECOVERY VERIFIED] {} | replacement={}",
        Utc::now().to_rfc3339(),
        replacement_name
    );

    if let Some(candidate) = decision.selected_candidate.as_deref() {
        if let Err(error) = resource::record_recovery_outcome(candidate, true) {
            println!(
                "[HISTORY ERROR] Recovery succeeded but history update failed: {}",
                error
            );
        }
    }

    Ok(EnforcementResult {
        action: EnforcementAction::RecoveryReleased,
        enforced: true,
        message: format!(
            "Replacement {} verified Ready and application reachable; placement cleanup pending",
            replacement_name
        ),
    })
}

pub fn log_enforcement(node: &str, result: &EnforcementResult) {
    println!(
        "[ENFORCEMENT] {} | node={} | action={:?} | enforced={} | message={}",
        Utc::now().to_rfc3339(),
        node,
        result.action,
        result.enforced,
        result.message
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn existing_hostname_constraint_is_preserved() {
        assert!(
            !validate_original_placement(Some("k3s-worker2".to_string()), "k3s-worker2").unwrap()
        );
    }

    #[test]
    fn conflicting_hostname_constraint_is_rejected() {
        assert!(
            validate_original_placement(Some("k3s-worker3".to_string()), "k3s-worker2").is_err()
        );
    }

    #[test]
    fn absent_hostname_constraint_can_be_managed() {
        assert!(validate_original_placement(None, "k3s-worker2").unwrap());
    }
}
