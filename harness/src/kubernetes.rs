use anyhow::Result;
use chrono::Utc;
use csv::Writer;
use serde::Serialize;
use std::fs::OpenOptions;
use std::process::Command;
use std::time::Duration;
use tokio::time::sleep;

#[derive(Serialize)]
struct NodeObservation {
    timestamp_utc: String,
    node: String,
    ready_status: String,
}

#[derive(Serialize)]
struct LeaseObservation {
    timestamp_utc: String,
    node: String,
    renew_time: String,
}

#[derive(Serialize)]
struct PodObservation {
    timestamp_utc: String,
    pod: String,
    phase: String,
    deletion_timestamp: String,
    node: String,
}

#[derive(Serialize)]
struct TaintObservation {
    timestamp_utc: String,
    node: String,
    taints: String,
}

#[derive(Serialize)]
struct EventObservation {
    timestamp_utc: String,
    namespace: String,
    event_type: String,
    reason: String,
    message: String,
    event_time: String,
    involved_kind: String,
    involved_name: String,
}

fn kubectl(args: &[&str]) -> Result<String> {
    let output = Command::new("kubectl").args(args).output()?;

    if !output.status.success() {
        return Err(anyhow::anyhow!(
            "kubectl failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub async fn observe_node(node: &str, output_path: String) -> Result<()> {
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(output_path)?;

    let mut writer = Writer::from_writer(file);

    loop {
        let timestamp = Utc::now();

        let jsonpath = "{.status.conditions[?(@.type==\"Ready\")].status}";

        let result = kubectl(&["get", "node", node, "-o", &format!("jsonpath={}", jsonpath)]);

        let ready_status = match result {
            Ok(value) => value,
            Err(error) => format!("ERROR: {}", error),
        };

        let observation = NodeObservation {
            timestamp_utc: timestamp.to_rfc3339(),
            node: node.to_string(),
            ready_status: ready_status.clone(),
        };

        writer.serialize(&observation)?;
        writer.flush()?;

        println!(
            "[NODE] {} | {} | Ready={}",
            timestamp.to_rfc3339(),
            node,
            ready_status
        );

        sleep(Duration::from_secs(1)).await;
    }
}

pub async fn observe_lease(node: &str, output_path: String) -> Result<()> {
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(output_path)?;

    let mut writer = Writer::from_writer(file);

    loop {
        let timestamp = Utc::now();

        let result = kubectl(&[
            "get",
            "lease",
            node,
            "-n",
            "kube-node-lease",
            "-o",
            "jsonpath={.spec.renewTime}",
        ]);

        let renew_time = match result {
            Ok(value) => value,
            Err(error) => format!("ERROR: {}", error),
        };

        let observation = LeaseObservation {
            timestamp_utc: timestamp.to_rfc3339(),
            node: node.to_string(),
            renew_time: renew_time.clone(),
        };

        writer.serialize(&observation)?;
        writer.flush()?;

        println!(
            "[LEASE] {} | {} | renewTime={}",
            timestamp.to_rfc3339(),
            node,
            renew_time
        );

        sleep(Duration::from_secs(1)).await;
    }
}

pub async fn observe_pod(namespace: &str, label_selector: &str, output_path: String) -> Result<()> {
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(output_path)?;

    let mut writer = Writer::from_writer(file);

    loop {
        let timestamp = Utc::now();

        let output = kubectl(&[
            "get",
            "pods",
            "-n",
            namespace,
            "-l",
            label_selector,
            "-o",
            "jsonpath={range .items[*]}{.metadata.name}{\"|\"}{.status.phase}{\"|\"}{.metadata.deletionTimestamp}{\"|\"}{.spec.nodeName}{\"\\n\"}{end}",
        ]);

        match output {
            Ok(pods) => {
                for line in pods.lines() {
                    let parts: Vec<&str> = line.split('|').collect();

                    if parts.len() != 4 {
                        continue;
                    }

                    let observation = PodObservation {
                        timestamp_utc: timestamp.to_rfc3339(),
                        pod: parts[0].to_string(),
                        phase: parts[1].to_string(),
                        deletion_timestamp: parts[2].to_string(),
                        node: parts[3].to_string(),
                    };

                    writer.serialize(&observation)?;
                    writer.flush()?;

                    println!(
                        "[POD] {} | {} | phase={} | node={} | deletion={}",
                        timestamp.to_rfc3339(),
                        parts[0],
                        parts[1],
                        parts[3],
                        parts[2]
                    );
                }
            }

            Err(error) => {
                println!("[POD] {} | ERROR: {}", timestamp.to_rfc3339(), error);
            }
        }

        sleep(Duration::from_secs(1)).await;
    }
}

pub async fn observe_taint(node: &str, output_path: String) -> Result<()> {
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(output_path)?;

    let mut writer = Writer::from_writer(file);

    loop {
        let timestamp = Utc::now();

        let result = kubectl(&[
            "get",
            "node",
            node,
            "-o",
            "jsonpath={range .spec.taints[*]}{.key}{\"=\"}{.value}{\"|\"}{.effect}{\";\"}{end}",
        ]);

        let taints = match result {
            Ok(value) => value,
            Err(error) => format!("ERROR: {}", error),
        };

        let observation = TaintObservation {
            timestamp_utc: timestamp.to_rfc3339(),
            node: node.to_string(),
            taints: taints.clone(),
        };

        writer.serialize(&observation)?;
        writer.flush()?;

        println!(
            "[TAINT] {} | {} | taints={}",
            timestamp.to_rfc3339(),
            node,
            if taints.is_empty() { "<none>" } else { &taints }
        );

        sleep(Duration::from_secs(1)).await;
    }
}

pub async fn observe_events(node: &str, output_path: String) -> Result<()> {
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(output_path)?;

    let mut writer = Writer::from_writer(file);

    let mut seen_events = std::collections::HashSet::<String>::new();

    loop {
        let timestamp = Utc::now();

        let field_selector = format!("involvedObject.kind=Node,involvedObject.name={}", node);

        let output = kubectl(&[
            "get",
            "events",
            "--all-namespaces",
            "--field-selector",
            &field_selector,
            "-o",
            "jsonpath={range .items[*]}{.metadata.uid}{\"|\"}{.metadata.resourceVersion}{\"|\"}{.metadata.namespace}{\"|\"}{.type}{\"|\"}{.reason}{\"|\"}{.message}{\"|\"}{.lastTimestamp}{\"|\"}{.involvedObject.kind}{\"|\"}{.involvedObject.name}{\"\\n\"}{end}",
        ]);

        match output {
            Ok(events) => {
                for line in events.lines() {
                    let parts: Vec<&str> = line.split('|').collect();

                    if parts.len() != 9 {
                        continue;
                    }

                    let event_id = format!("{}:{}", parts[0], parts[1]);

                    if seen_events.contains(&event_id) {
                        continue;
                    }

                    seen_events.insert(event_id);

                    let observation = EventObservation {
                        timestamp_utc: timestamp.to_rfc3339(),
                        namespace: parts[2].to_string(),
                        event_type: parts[3].to_string(),
                        reason: parts[4].to_string(),
                        message: parts[5].to_string(),
                        event_time: parts[6].to_string(),
                        involved_kind: parts[7].to_string(),
                        involved_name: parts[8].to_string(),
                    };

                    writer.serialize(&observation)?;
                    writer.flush()?;

                    println!(
                        "[EVENT] {} | type={} | reason={} | object={}/{} | message={}",
                        timestamp.to_rfc3339(),
                        parts[3],
                        parts[4],
                        parts[7],
                        parts[8],
                        parts[5]
                    );
                }
            }

            Err(error) => {
                println!("[EVENT] {} | ERROR: {}", timestamp.to_rfc3339(), error);
            }
        }

        sleep(Duration::from_secs(1)).await;
    }
}
