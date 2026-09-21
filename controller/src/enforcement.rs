use anyhow::Result;
use chrono::Utc;
use k8s_openapi::api::core::v1::Pod;
use kube::{
    api::{
        DeleteParams,
        ListParams,
    },
    Api,
    Client,
};

use crate::decision::{
    DecisionResult,
    RecoveryDecision,
};

use crate::fencing::{
    self,
    FencingState,
};

#[derive(Debug, Clone, PartialEq)]
pub enum EnforcementAction {
    PreserveExisting,
    RecoveryReleased,
    RecoveryBlockedFencingFailed,
}

#[derive(Debug, Clone)]
pub struct EnforcementResult {
    pub action: EnforcementAction,
    pub enforced: bool,
    pub message: String,
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
    match decision.decision {
        RecoveryDecision::Preserve => {
            Ok(
                EnforcementResult {
                    action:
                        EnforcementAction::
                            PreserveExisting,

                    enforced: true,

                    message:
                        "existing workload remains bound; no recovery action initiated"
                            .to_string(),
                }
            )
        }

        RecoveryDecision::Recover => {
            if decision.fencing_required {
                let fencing_result =
                    fencing::execute_fence(
                        true,
                        fencing_supported,
                        fencing_command,
                    )?;

                if fencing_result.state
                    != FencingState::Succeeded
                {
                    return Ok(
                        EnforcementResult {
                            action:
                                EnforcementAction::
                                    RecoveryBlockedFencingFailed,

                            enforced: false,

                            message:
                                format!(
                                    "recovery blocked because fencing did not succeed: {}",
                                    fencing_result.message
                                ),
                        }
                    );
                }

                println!(
                    "[FENCING VERIFIED] {} | node={} | recovery may proceed",
                    Utc::now()
                        .to_rfc3339(),
                    target_node
                );
            }

            let pods: Api<Pod> =
                Api::namespaced(
                    client,
                    namespace,
                );

            let list_params =
                ListParams::default()
                    .labels(
                        pod_label_selector
                    );

            let pod_list =
                pods
                    .list(
                        &list_params
                    )
                    .await?;

            let mut released_pod:
                Option<String> = None;

            for pod in
                pod_list.items
            {
                let pod_name =
                    pod
                        .metadata
                        .name
                        .clone()
                        .unwrap_or_default();

                let pod_node =
                    pod
                        .spec
                        .as_ref()
                        .and_then(
                            |spec| {
                                spec
                                    .node_name
                                    .clone()
                            }
                        );

                if pod_node.as_deref()
                    == Some(
                        target_node
                    )
                {
                    println!(
                        "[RECOVERY RELEASE] {} | deleting preserved pod={} | node={}",
                        Utc::now()
                            .to_rfc3339(),
                        pod_name,
                        target_node
                    );

                    let delete_params =
                        DeleteParams {
                            grace_period_seconds:
                                Some(0),

                            ..Default::default()
                        };

                    pods
                        .delete(
                            &pod_name,
                            &delete_params,
                        )
                        .await?;

                    released_pod =
                        Some(
                            pod_name
                        );

                    break;
                }
            }

            match released_pod {
                Some(pod_name) => {
                    Ok(
                        EnforcementResult {
                            action:
                                EnforcementAction::
                                    RecoveryReleased,

                            enforced: true,

                            message:
                                format!(
                                    "preserved pod {} released after recovery safety requirements were satisfied",
                                    pod_name
                                ),
                        }
                    )
                }

                None => {
                    Ok(
                        EnforcementResult {
                            action:
                                EnforcementAction::
                                    RecoveryReleased,

                            enforced: false,

                            message:
                                format!(
                                    "no matching preserved pod found on target node {}",
                                    target_node
                                ),
                        }
                    )
                }
            }
        }
    }
}

pub fn log_enforcement(
    node: &str,
    result: &EnforcementResult,
) {
    println!(
        "[ENFORCEMENT] {} | node={} | action={:?} | enforced={} | message={}",
        Utc::now()
            .to_rfc3339(),
        node,
        result.action,
        result.enforced,
        result.message
    );
}