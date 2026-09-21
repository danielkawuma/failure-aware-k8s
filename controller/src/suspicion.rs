use anyhow::Result;
use chrono::{DateTime, Utc};
use futures::{StreamExt, TryStreamExt};
use k8s_openapi::api::core::v1::Node;
use kube::{
    Api,
    Client,
    runtime::watcher::{self, Event},
};
use std::collections::HashMap;

use crate::awareness;
use crate::decision;
use crate::enforcement;
use crate::recovery_safety;
use crate::resource;
use crate::verification;
use crate::workload::WorkloadAwareness;

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

pub async fn run_suspicion_listener(
    client: Client,
    target_node: String,
    trigger_status: String,

    verification_url: String,
    verification_timeout_ms: u64,
    verification_attempts: u32,
    verification_interval_ms: u64,

    workload_awareness: WorkloadAwareness,

    recovery_candidate_node: String,
    required_cpu_millicores: u64,
    required_memory_mib: u64,
    required_node_labels: HashMap<String, String>,

    fencing_supported: bool,
) -> Result<()> {
    let nodes: Api<Node> =
        Api::all(client.clone());

    let watcher_config =
        watcher::Config::default()
            .fields(
                &format!(
                    "metadata.name={}",
                    target_node
                )
            );

    let mut stream =
        watcher::watcher(
            nodes,
            watcher_config,
        )
        .boxed();

    let mut previous_ready: Option<String> = None;

    println!(
        "[LISTENER] Watching node={} for Ready={}",
        target_node,
        trigger_status
    );

    while let Some(event) =
        stream.try_next().await?
    {
        match event {
            Event::Init => {
                println!(
                    "[LISTENER] Initializing node watch"
                );
            }

            Event::InitApply(node) => {
                let current =
                    ready_status(&node);

                println!(
                    "[INITIAL STATE] node={} | Ready={:?}",
                    target_node,
                    current
                );

                previous_ready = current;
            }

            Event::InitDone => {
                println!(
                    "[LISTENER] Initial node state synchronized"
                );
            }

            Event::Apply(node) => {
                let current_ready =
                    ready_status(&node)
                        .unwrap_or_else(
                            || "Unknown".to_string()
                        );

                if current_ready == trigger_status
                    && previous_ready.as_deref()
                        != Some(trigger_status.as_str())
                {
                    let suspicion =
                        FailureSuspicion {
                            node:
                                target_node.clone(),

                            detected_at:
                                Utc::now(),

                            previous_ready:
                                previous_ready.clone(),

                            current_ready:
                                current_ready.clone(),
                        };

                    println!(
                        "[SUSPICION] {} | node={} | Ready={:?} -> {}",
                        suspicion
                            .detected_at
                            .to_rfc3339(),
                        suspicion.node,
                        suspicion.previous_ready,
                        suspicion.current_ready
                    );

                    println!(
                        "[VERIFY] {} | starting bounded verification against {}",
                        Utc::now().to_rfc3339(),
                        verification_url
                    );

                    let evidence =
                        verification::verify_http_bounded(
                            &verification_url,
                            verification_timeout_ms,
                            verification_attempts,
                            verification_interval_ms,
                        )
                        .await?;

                    let operational_state =
                        awareness::classify_operational_state(
                            &evidence
                        );

                    let resource_awareness =
                        resource::evaluate_resources(
                            client.clone(),
                            &recovery_candidate_node,
                            required_cpu_millicores,
                            required_memory_mib,
                            &required_node_labels,
                        )
                        .await?;

                    let recovery_safety_awareness =
                        recovery_safety::evaluate_recovery_safety(
                            &workload_awareness,
                            fencing_supported,
                        );

                    let context =
                        awareness::AwarenessContext {
                            operational_state:
                                operational_state.clone(),

                            workload:
                                workload_awareness.clone(),

                            resources:
                                resource_awareness.clone(),

                            recovery_safety:
                                recovery_safety_awareness.clone(),
                        };

                    println!(
                        "[RESOURCE] {} | candidate={} | state={:?} | Ready={} | labels_match={} | CPU={}m required={}m | memory={}Mi required={}Mi",
                        Utc::now().to_rfc3339(),
                        context.resources.candidate_node,
                        context.resources.state,
                        context.resources.node_ready,
                        context.resources.labels_match,
                        context.resources.allocatable_cpu_millicores,
                        context.resources.required_cpu_millicores,
                        context.resources.allocatable_memory_mib,
                        context.resources.required_memory_mib
                    );

                    println!(
                        "[RECOVERY SAFETY] {} | state={:?} | fencing_required={} | fencing_supported={}",
                        Utc::now().to_rfc3339(),
                        context.recovery_safety.state,
                        context.recovery_safety.fencing_required,
                        context.recovery_safety.fencing_supported
                    );

                    println!(
                        "[AWARENESS] {} | node={} | operational_state={:?} | workload={} | workload_type={:?} | duplication_sensitive={} | service_criticality={:?} | resource_state={:?} | recovery_candidate={} | recovery_safety={:?} | fencing_required={} | attempts={} | successes={} | failures={}",
                        Utc::now().to_rfc3339(),
                        target_node,
                        context.operational_state,
                        context.workload.name,
                        context.workload.workload_type,
                        context.workload.duplication_sensitive,
                        context.workload.service_criticality,
                        context.resources.state,
                        context.resources.candidate_node,
                        context.recovery_safety.state,
                        context.recovery_safety.fencing_required,
                        evidence.attempts,
                        evidence.successes,
                        evidence.failures
                    );

                    let decision_result =
                        decision::decide(
                            &context
                        );

                    println!(
                        "[DECISION] {} | node={} | decision={:?} | fencing_required={} | reason={}",
                        Utc::now().to_rfc3339(),
                        target_node,
                        decision_result.decision,
                        decision_result.fencing_required,
                        decision_result.reason
                    );

                    let enforcement_result =
                        enforcement::enforce_decision(
                            &decision_result
                        );

                    enforcement::log_enforcement(
                        &target_node,
                        &enforcement_result,
                    );
                }

                if previous_ready.as_deref()
                    == Some(trigger_status.as_str())
                    && current_ready == "True"
                {
                    println!(
                        "[RECOVERED] {} | node={} | Ready={} -> True",
                        Utc::now().to_rfc3339(),
                        target_node,
                        trigger_status
                    );
                }

                previous_ready =
                    Some(current_ready);
            }

            Event::Delete(node) => {
                println!(
                    "[NODE DELETE] {}",
                    node.metadata
                        .name
                        .unwrap_or_default()
                );
            }
        }
    }

    Ok(())
}