use anyhow::Result;
use chrono::{DateTime, Utc};
use futures::{StreamExt, TryStreamExt};
use k8s_openapi::api::core::v1::Node;
use kube::{
    Api,
    Client,
    runtime::watcher::{self, Event},
};

use crate::verification;

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
) -> Result<()> {
    let nodes: Api<Node> =
        Api::all(client);

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
                        "[VERIFY] {} | probing {}",
                        Utc::now().to_rfc3339(),
                        verification_url
                    );

                    let verification =
                        verification::verify_http(
                            &verification_url,
                            verification_timeout_ms,
                        )
                        .await?;

                    if verification.reachable {
                        println!(
                            "[VERIFY RESULT] {} | reachable=true | HTTP={:?} | latency={:.3} ms",
                            verification
                                .checked_at
                                .to_rfc3339(),
                            verification.http_status,
                            verification.latency_ms
                        );
                    } else {
                        println!(
                            "[VERIFY RESULT] {} | reachable=false | HTTP={:?} | latency={:.3} ms | error={:?}",
                            verification
                                .checked_at
                                .to_rfc3339(),
                            verification.http_status,
                            verification.latency_ms,
                            verification.error
                        );
                    }
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