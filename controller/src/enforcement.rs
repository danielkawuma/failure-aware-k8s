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

use crate::decision::{DecisionResult, RecoveryDecision};

use crate::fencing::{self, FencingState};

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

fn controller_owner(pod: &Pod) -> Option<(String, String)> {
    pod.metadata
        .owner_references
        .as_ref()?
        .iter()
        .find(|owner| owner.controller.unwrap_or(false))
        .map(|owner| (owner.kind.clone(), owner.name.clone()))
}

async fn patch_deployment_hostname(
    client: Client,
    namespace: &str,
    deployment_name: &str,
    candidate_node: &str,
) -> Result<()> {
    let deployments: Api<Deployment> = Api::namespaced(client, namespace);

    let patch = json!({
        "spec": {
            "template": {
                "spec": {
                    "nodeSelector": {
                        "kubernetes.io/hostname": candidate_node
                    }
                }
            }
        }
    });

    deployments
        .patch(
            deployment_name,
            &PatchParams::default(),
            &Patch::Merge(&patch),
        )
        .await?;

    Ok(())
}

async fn patch_statefulset_hostname(
    client: Client,
    namespace: &str,
    statefulset_name: &str,
    candidate_node: &str,
) -> Result<()> {
    let statefulsets: Api<StatefulSet> = Api::namespaced(client, namespace);

    let patch = json!({
        "spec": {
            "template": {
                "spec": {
                    "nodeSelector": {
                        "kubernetes.io/hostname": candidate_node
                    }
                }
            }
        }
    });

    statefulsets
        .patch(
            statefulset_name,
            &PatchParams::default(),
            &Patch::Merge(&patch),
        )
        .await?;

    Ok(())
}

async fn constrain_replacement_to_candidate(
    client: Client,
    namespace: &str,
    pod: &Pod,
    candidate_node: &str,
) -> Result<String> {
    let (owner_kind, owner_name) =
        controller_owner(pod)
            .ok_or_else(|| {
                anyhow!(
                    "selected candidate {} cannot be enforced because the preserved Pod has no controller owner",
                    candidate_node
                )
            })?;

    match owner_kind.as_str() {
        "ReplicaSet" => {
            let replica_sets: Api<ReplicaSet> = Api::namespaced(client.clone(), namespace);

            let replica_set = replica_sets.get(&owner_name).await?;

            let deployment_owner =
                replica_set
                    .metadata
                    .owner_references
                    .as_ref()
                    .and_then(|owners| {
                        owners
                            .iter()
                            .find(|owner| {
                                owner.controller
                                    .unwrap_or(false)
                                    && owner.kind
                                        == "Deployment"
                            })
                    })
                    .ok_or_else(|| {
                        anyhow!(
                            "ReplicaSet {} has no controlling Deployment; selected candidate cannot be enforced safely",
                            owner_name
                        )
                    })?;

            patch_deployment_hostname(client, namespace, &deployment_owner.name, candidate_node)
                .await?;

            Ok(format!("Deployment/{}", deployment_owner.name))
        }

        "Deployment" => {
            patch_deployment_hostname(client, namespace, &owner_name, candidate_node).await?;

            Ok(format!("Deployment/{}", owner_name))
        }

        "StatefulSet" => {
            patch_statefulset_hostname(client, namespace, &owner_name, candidate_node).await?;

            Ok(format!("StatefulSet/{}", owner_name))
        }

        other => Err(anyhow!(
            "unsupported workload controller kind {} for selected-candidate enforcement",
            other
        )),
    }
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
        RecoveryDecision::Preserve => Ok(EnforcementResult {
            action: EnforcementAction::PreserveExisting,

            enforced: true,

            message: "existing workload remains bound; no recovery action initiated".to_string(),
        }),

        RecoveryDecision::Recover => {
            if decision.fencing_required {
                let fencing_result =
                    fencing::execute_fence(true, fencing_supported, fencing_command)?;

                if fencing_result.state != FencingState::Succeeded {
                    return Ok(EnforcementResult {
                        action: EnforcementAction::RecoveryBlockedFencingFailed,

                        enforced: false,

                        message: format!(
                            "recovery blocked because fencing did not succeed: {}",
                            fencing_result.message
                        ),
                    });
                }

                println!(
                    "[FENCING VERIFIED] {} | node={} | recovery may proceed",
                    Utc::now().to_rfc3339(),
                    target_node
                );
            }

            let pods: Api<Pod> = Api::namespaced(client.clone(), namespace);

            let list_params = ListParams::default().labels(pod_label_selector);

            let pod_list = pods.list(&list_params).await?;

            let mut target_pod: Option<Pod> = None;

            for pod in pod_list.items {
                let pod_node = pod.spec.as_ref().and_then(|spec| spec.node_name.clone());

                if pod_node.as_deref() == Some(target_node) {
                    target_pod = Some(pod);

                    break;
                }
            }

            let pod = match target_pod {
                Some(pod) => pod,

                None => {
                    return Ok(EnforcementResult {
                        action: EnforcementAction::RecoveryReleased,

                        enforced: false,

                        message: format!(
                            "no matching preserved pod found on target node {}",
                            target_node
                        ),
                    });
                }
            };

            let pod_name = pod.metadata.name.clone().unwrap_or_default();

            /*
             * In legacy mode selected_candidate is None, so the
             * original release-only behaviour is unchanged.
             *
             * In multi-candidate mode the owning Deployment or
             * StatefulSet is constrained first. Kubernetes still
             * performs the actual scheduling.
             */
            if let Some(candidate_node) = decision.selected_candidate.as_deref() {
                let constrained_controller = match constrain_replacement_to_candidate(
                    client.clone(),
                    namespace,
                    &pod,
                    candidate_node,
                )
                .await
                {
                    Ok(controller) => controller,

                    Err(error) => {
                        return Ok(EnforcementResult {
                            action: EnforcementAction::RecoveryBlockedPlacementConstraintFailed,

                            enforced: false,

                            message: format!(
                                "recovery blocked because selected candidate {} could not be expressed as a Kubernetes scheduling constraint: {}",
                                candidate_node, error
                            ),
                        });
                    }
                };

                println!(
                    "[PLACEMENT] {} | selected_candidate={} | controller={} | constraint=kubernetes.io/hostname",
                    Utc::now().to_rfc3339(),
                    candidate_node,
                    constrained_controller
                );
            }

            println!(
                "[RECOVERY RELEASE] {} | deleting preserved pod={} | node={} | selected_candidate={}",
                Utc::now().to_rfc3339(),
                pod_name,
                target_node,
                decision
                    .selected_candidate
                    .as_deref()
                    .unwrap_or("native-scheduler")
            );

            let delete_params = DeleteParams {
                grace_period_seconds: Some(0),

                ..Default::default()
            };

            pods.delete(&pod_name, &delete_params).await?;

            Ok(EnforcementResult {
                action: EnforcementAction::RecoveryReleased,

                enforced: true,

                message: match decision.selected_candidate.as_deref() {
                    Some(candidate) => {
                        format!(
                            "preserved pod {} released; replacement constrained to selected recovery candidate {}",
                            pod_name, candidate
                        )
                    }

                    None => {
                        format!(
                            "preserved pod {} released after recovery safety requirements were satisfied",
                            pod_name
                        )
                    }
                },
            })
        }
    }
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
