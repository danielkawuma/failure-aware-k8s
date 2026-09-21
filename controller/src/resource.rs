use anyhow::{anyhow, Result};
use k8s_openapi::api::core::v1::Node;
use kube::{Api, Client};
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq)]
pub enum ResourceState {
    Available,
    Insufficient,
    Unavailable,
}

#[derive(Debug, Clone)]
pub struct ResourceAwareness {
    pub candidate_node: String,
    pub state: ResourceState,

    pub node_ready: bool,
    pub labels_match: bool,

    pub allocatable_cpu_millicores: u64,
    pub required_cpu_millicores: u64,

    pub allocatable_memory_mib: u64,
    pub required_memory_mib: u64,
}

fn node_ready(node: &Node) -> bool {
    node.status
        .as_ref()
        .and_then(|status| status.conditions.as_ref())
        .and_then(|conditions| {
            conditions
                .iter()
                .find(|condition| condition.type_ == "Ready")
        })
        .map(|condition| condition.status == "True")
        .unwrap_or(false)
}

fn labels_match(
    node: &Node,
    required_labels: &HashMap<String, String>,
) -> bool {
    required_labels.iter().all(
        |(key, expected_value)| {
            node.metadata
                .labels
                .as_ref()
                .and_then(|labels| labels.get(key))
                == Some(expected_value)
        },
    )
}

fn parse_cpu_millicores(value: &str) -> Result<u64> {
    if let Some(millicores) = value.strip_suffix('m') {
        return Ok(millicores.parse()?);
    }

    let cores: f64 = value.parse()?;

    Ok((cores * 1000.0) as u64)
}

fn parse_memory_mib(value: &str) -> Result<u64> {
    if let Some(kib) = value.strip_suffix("Ki") {
        let kib: u64 = kib.parse()?;
        return Ok(kib / 1024);
    }

    if let Some(mib) = value.strip_suffix("Mi") {
        return Ok(mib.parse()?);
    }

    if let Some(gib) = value.strip_suffix("Gi") {
        let gib: u64 = gib.parse()?;
        return Ok(gib * 1024);
    }

    Err(anyhow!(
        "Unsupported Kubernetes memory quantity: {}",
        value
    ))
}

pub async fn evaluate_resources(
    client: Client,
    candidate_node: &str,
    required_cpu_millicores: u64,
    required_memory_mib: u64,
    required_labels: &HashMap<String, String>,
) -> Result<ResourceAwareness> {
    let nodes: Api<Node> =
        Api::all(client);

    let node =
        nodes.get(candidate_node).await?;

    let ready =
        node_ready(&node);

    let labels_ok =
        labels_match(
            &node,
            required_labels,
        );

    let allocatable =
        node.status
            .as_ref()
            .and_then(|status| status.allocatable.as_ref())
            .ok_or_else(|| {
                anyhow!(
                    "Node {} has no allocatable resource data",
                    candidate_node
                )
            })?;

    let cpu_quantity =
        allocatable
            .get("cpu")
            .ok_or_else(|| {
                anyhow!(
                    "Node {} has no allocatable CPU value",
                    candidate_node
                )
            })?;

    let memory_quantity =
        allocatable
            .get("memory")
            .ok_or_else(|| {
                anyhow!(
                    "Node {} has no allocatable memory value",
                    candidate_node
                )
            })?;

    let cpu_millicores =
        parse_cpu_millicores(
            &cpu_quantity.0
        )?;

    let memory_mib =
        parse_memory_mib(
            &memory_quantity.0
        )?;

    let resources_sufficient =
        cpu_millicores
            >= required_cpu_millicores
        &&
        memory_mib
            >= required_memory_mib;

    let state =
        if !ready || !labels_ok {
            ResourceState::Unavailable
        } else if !resources_sufficient {
            ResourceState::Insufficient
        } else {
            ResourceState::Available
        };

    Ok(ResourceAwareness {
        candidate_node:
            candidate_node.to_string(),

        state,

        node_ready:
            ready,

        labels_match:
            labels_ok,

        allocatable_cpu_millicores:
            cpu_millicores,

        required_cpu_millicores,

        allocatable_memory_mib:
            memory_mib,

        required_memory_mib,
    })
}