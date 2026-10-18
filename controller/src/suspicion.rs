use anyhow::Result;
use chrono::{DateTime, Utc};
use futures::{StreamExt, TryStreamExt};
use k8s_openapi::api::core::v1::Node;
use kube::{
    Api, Client,
    runtime::watcher::{self, Event},
};
use std::collections::HashMap;
use std::env;
use std::time::Duration;
use tokio::time::timeout;

use crate::awareness::{self, OperationalState};
use crate::decision::{self, DecisionResult, RecoveryDecision};
use crate::enforcement;
use crate::recovery_safety::{self, RecoverySafetyState};
use crate::resource;
use crate::verification;
use crate::workload::{self, WorkloadAwareness};

#[derive(Debug, Clone)]
pub struct FailureSuspicion {
    pub node: String,
    pub detected_at: DateTime<Utc>,
    pub previous_ready: Option<String>,
    pub current_ready: String,
}

fn ready_status(node: &Node) -> Option<String> {
    node.status
        .as_ref()?
        .conditions
        .as_ref()?
        .iter()
        .find(|condition| condition.type_ == "Ready")
        .map(|condition| condition.status.clone())
}

fn preserve(reason: &str) -> DecisionResult {
    DecisionResult {
        decision: RecoveryDecision::Preserve,
        reason: reason.to_string(),
        fencing_required: false,
        selected_candidate: None,
    }
}

fn workload_discovery_timeout_ms() -> u64 {
    env::var("FAILURE_AWARE_API_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(3000)
}

pub async fn run_suspicion_listener(
    client: Client,
    target_node: String,
    trigger_status: String,
    verification_url: String,
    verification_timeout_ms: u64,
    verification_attempts: u32,
    verification_interval_ms: u64,
    workload_awareness: WorkloadAwareness,
    namespace: String,
    pod_label_selector: String,
    recovery_candidate_node: String,
    required_cpu_millicores: u64,
    required_memory_mib: u64,
    required_node_labels: HashMap<String, String>,
    fencing_supported: bool,
    fencing_command: String,
    resource_evaluation_timeout_ms: u64,
    _enforcement_timeout_ms: u64,
) -> Result<()> {
    let nodes: Api<Node> = Api::all(client.clone());

    let watcher_config =
        watcher::Config::default().fields(&format!("metadata.name={}", target_node));

    let mut stream = watcher::watcher(nodes, watcher_config).boxed();

    let mut previous_ready: Option<String> = None;

    println!(
        "[LISTENER] Watching node={} for Ready={}",
        target_node, trigger_status
    );

    while let Some(event) = stream.try_next().await? {
        match event {
            Event::Init => {
                println!("[LISTENER] Initializing node watch");
            }

            Event::InitApply(node) => {
                previous_ready = ready_status(&node);

                println!(
                    "[INITIAL STATE] node={} | Ready={:?}",
                    target_node, previous_ready
                );
            }

            Event::InitDone => {
                println!("[LISTENER] Initial node state synchronized");
            }

            Event::Apply(node) => {
                let current_ready = ready_status(&node).unwrap_or_else(|| "Unknown".to_string());

                let new_suspicion = current_ready == trigger_status
                    && previous_ready.as_deref() != Some(trigger_status.as_str());

                if new_suspicion {
                    let suspicion = FailureSuspicion {
                        node: target_node.clone(),
                        detected_at: Utc::now(),
                        previous_ready: previous_ready.clone(),
                        current_ready: current_ready.clone(),
                    };

                    println!(
                        "[SUSPICION] {} | node={} | Ready={:?} -> {}",
                        suspicion.detected_at.to_rfc3339(),
                        suspicion.node,
                        suspicion.previous_ready,
                        suspicion.current_ready
                    );

                    let evidence = verification::verify_http_bounded(
                        &verification_url,
                        verification_timeout_ms,
                        verification_attempts,
                        verification_interval_ms,
                    )
                    .await?;

                    let operational_state = awareness::classify_operational_state(&evidence);

                    println!(
                        "[VERIFICATION] node={} | state={:?} | attempts={} | successes={} | failures={}",
                        target_node,
                        operational_state,
                        evidence.attempts,
                        evidence.successes,
                        evidence.failures
                    );

                    let decision_result = match operational_state {
                        OperationalState::ReachableOutsideControlPlane => {
                            println!(
                                "[SHORT CIRCUIT] node={} | candidate_evaluation=skipped | workload_discovery=skipped | reason=reachable",
                                target_node
                            );

                            preserve(
                                "workload remains reachable outside the control-plane path; unnecessary recovery is avoided",
                            )
                        }

                        OperationalState::Indeterminate => {
                            println!(
                                "[SHORT CIRCUIT] node={} | candidate_evaluation=skipped | workload_discovery=skipped | reason=indeterminate",
                                target_node
                            );

                            preserve(
                                "operational state is indeterminate; disruptive recovery is not justified",
                            )
                        }

                        OperationalState::Unreachable => {
                            /*
                             * Workload discovery occurs only after
                             * independent verification establishes
                             * that the workload is unreachable.
                             *
                             * A missing or invalid workload
                             * classification must not silently
                             * authorize unsafe recovery.
                             */
                            let discovered = workload::discover_workload_awareness(
                                client.clone(),
                                &namespace,
                                &pod_label_selector,
                                &target_node,
                                &workload_awareness,
                                workload_discovery_timeout_ms(),
                            )
                            .await;

                            match discovered {
                                Err(error) => {
                                    println!(
                                        "[WORKLOAD DISCOVERY ERROR] {} | node={} | error={} | recovery_authorized=false",
                                        Utc::now().to_rfc3339(),
                                        target_node,
                                        error
                                    );

                                    preserve(
                                        "recovery deferred because workload duplication sensitivity could not be established",
                                    )
                                }

                                Ok(discovered_workload) => {
                                    println!(
                                        "[WORKLOAD] node={} | name={} | type={:?} | duplication_sensitive={}",
                                        target_node,
                                        discovered_workload.name,
                                        discovered_workload.workload_type,
                                        discovered_workload.duplication_sensitive
                                    );

                                    let safety = recovery_safety::evaluate_recovery_safety(
                                        &discovered_workload,
                                        fencing_supported,
                                    );

                                    println!(
                                        "[RECOVERY SAFETY] state={:?} | fencing_required={} | fencing_supported={}",
                                        safety.state,
                                        safety.fencing_required,
                                        safety.fencing_supported
                                    );

                                    if safety.state == RecoverySafetyState::Unsafe {
                                        println!(
                                            "[SHORT CIRCUIT] node={} | candidate_evaluation=skipped | reason=unsafe_recovery",
                                            target_node
                                        );

                                        DecisionResult {
                                            decision:
                                                RecoveryDecision::Preserve,
                                            reason:
                                                "recovery blocked because required fencing is unavailable"
                                                    .to_string(),
                                            fencing_required: true,
                                            selected_candidate: None,
                                        }
                                    } else {
                                        let evaluation = timeout(
                                            Duration::from_millis(resource_evaluation_timeout_ms),
                                            resource::evaluate_resources(
                                                client.clone(),
                                                &recovery_candidate_node,
                                                required_cpu_millicores,
                                                required_memory_mib,
                                                &required_node_labels,
                                            ),
                                        )
                                        .await;

                                        match evaluation {
                                            Ok(Ok(resources)) => {
                                                println!(
                                                    "[RESOURCE] candidate={} | state={:?} | Ready={} | schedulable={} | remaining_cpu={}m | remaining_memory={}Mi | reliability={:.6}",
                                                    resources.candidate_node,
                                                    resources.state,
                                                    resources.node_ready,
                                                    resources.node_schedulable,
                                                    resources.remaining_cpu_millicores,
                                                    resources.remaining_memory_mib,
                                                    resources.reliability_score
                                                );

                                                let context = awareness::AwarenessContext {
                                                    operational_state:
                                                        OperationalState::Unreachable,
                                                    workload: discovered_workload,
                                                    resources,
                                                    recovery_safety: safety,
                                                };

                                                decision::decide(&context)
                                            }

                                            Ok(Err(error)) => {
                                                println!(
                                                    "[RESOURCE ERROR] node={} | error={}",
                                                    target_node, error
                                                );

                                                preserve(
                                                    "recovery deferred because candidate evaluation failed",
                                                )
                                            }

                                            Err(_) => {
                                                println!(
                                                    "[RESOURCE TIMEOUT] node={} | timeout_ms={}",
                                                    target_node, resource_evaluation_timeout_ms
                                                );

                                                preserve(
                                                    "recovery deferred because candidate evaluation exceeded its time bound",
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    };

                    println!(
                        "[DECISION] {} | node={} | decision={:?} | fencing_required={} | selected_candidate={:?} | reason={}",
                        Utc::now().to_rfc3339(),
                        target_node,
                        decision_result.decision,
                        decision_result.fencing_required,
                        decision_result.selected_candidate,
                        decision_result.reason
                    );

                    if decision_result.decision == RecoveryDecision::Preserve {
                        println!(
                            "[ENFORCEMENT] node={} | action=PreserveExisting | no disruptive action",
                            target_node
                        );
                    } else {
                        /*
                         * No arbitrary outer enforcement timeout.
                         *
                         * Kubernetes API calls, fencing, and
                         * recovery verification retain their
                         * respective operation-level bounds.
                         */
                        match enforcement::enforce_decision(
                            client.clone(),
                            &decision_result,
                            &namespace,
                            &pod_label_selector,
                            &target_node,
                            fencing_supported,
                            &fencing_command,
                        )
                        .await
                        {
                            Ok(result) => {
                                enforcement::log_enforcement(&target_node, &result);
                            }

                            Err(error) => {
                                println!(
                                    "[ENFORCEMENT ERROR] {} | node={} | error={}",
                                    Utc::now().to_rfc3339(),
                                    target_node,
                                    error
                                );
                            }
                        }
                    }
                }

                if previous_ready.as_deref() == Some(trigger_status.as_str())
                    && current_ready == "True"
                {
                    println!(
                        "[RECOVERED] {} | node={} | Ready={} -> True",
                        Utc::now().to_rfc3339(),
                        target_node,
                        trigger_status
                    );
                }

                previous_ready = Some(current_ready);
            }

            Event::Delete(node) => {
                println!("[NODE DELETE] {}", node.metadata.name.unwrap_or_default());
            }
        }
    }

    Ok(())
}
