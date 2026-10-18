use anyhow::{anyhow, Result};
use chrono::{DateTime, Utc};
use reqwest::Client;
use serde_json::Value;
use std::env;
use std::net::IpAddr;
use std::time::{Duration, Instant};
use tokio::process::Command;
use tokio::time::{sleep, timeout};

#[derive(Debug, Clone)]
pub struct VerificationResult {
    pub checked_at: DateTime<Utc>,
    pub reachable: bool,
    pub http_status: Option<u16>,
    pub latency_ms: f64,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct VerificationEvidence {
    pub attempts: u32,
    pub successes: u32,
    pub failures: u32,
    pub results: Vec<VerificationResult>,
    pub indeterminate: bool,
}

#[derive(Debug, Clone)]
struct OriginalPod {
    name: String,
    uid: String,
    ip: IpAddr,
}

#[derive(Debug, Clone)]
struct SshPodTarget {
    verifier_host: IpAddr,
    namespace: String,
    node: String,
    selector: String,
}

fn parse_ssh_target(url: &str) -> Result<SshPodTarget> {
    let value = url
        .strip_prefix("ssh-pod://")
        .ok_or_else(|| anyhow!("Invalid SSH Pod verification URL"))?;

    let parts: Vec<&str> = value.split('/').collect();

    if parts.len() != 4 {
        return Err(anyhow!(
            "Expected ssh-pod://IP/namespace/node/selector"
        ));
    }

    let verifier_host: IpAddr = parts[0].parse()?;

    for component in &parts[1..] {
        if component.is_empty()
            || !component.chars().all(|c| {
                c.is_ascii_alphanumeric()
                    || matches!(c, '-' | '_' | '.' | '=')
            })
        {
            return Err(anyhow!(
                "Invalid SSH Pod verification component"
            ));
        }
    }

    Ok(SshPodTarget {
        verifier_host,
        namespace: parts[1].to_string(),
        node: parts[2].to_string(),
        selector: parts[3].to_string(),
    })
}

fn indeterminate_result(message: String) -> VerificationResult {
    VerificationResult {
        checked_at: Utc::now(),
        reachable: false,
        http_status: None,
        latency_ms: 0.0,
        error: Some(format!("VERIFIER_INDETERMINATE: {message}")),
    }
}

fn is_indeterminate(result: &VerificationResult) -> bool {
    result.error.as_deref().is_some_and(|error| {
        error.starts_with("VERIFIER_INDETERMINATE:")
    })
}

async fn discover_original(
    target: &SshPodTarget,
    timeout_ms: u64,
) -> Result<OriginalPod> {
    let mut command = Command::new("kubectl");

    command
        .arg("--request-timeout=5s")
        .arg("get")
        .arg("pods")
        .arg("-n")
        .arg(&target.namespace)
        .arg("-l")
        .arg(&target.selector)
        .arg("-o")
        .arg("json")
        .kill_on_drop(true);

    let output = timeout(
        Duration::from_millis(timeout_ms.max(5000)),
        command.output(),
    )
    .await
    .map_err(|_| anyhow!("Original Pod discovery timed out"))??;

    if !output.status.success() {
        return Err(anyhow!(
            "Kubernetes original Pod discovery failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let response: Value = serde_json::from_slice(&output.stdout)?;

    let items = response["items"]
        .as_array()
        .ok_or_else(|| anyhow!("Invalid Pod discovery response"))?;

    let matching: Vec<&Value> = items
        .iter()
        .filter(|pod| {
            pod["spec"]["nodeName"].as_str()
                == Some(target.node.as_str())
                && pod["metadata"]["deletionTimestamp"].is_null()
        })
        .collect();

    if matching.len() != 1 {
        return Err(anyhow!(
            "Expected exactly one original Pod on {}; found {}",
            target.node,
            matching.len()
        ));
    }

    let pod = matching[0];

    let name = pod["metadata"]["name"]
        .as_str()
        .ok_or_else(|| anyhow!("Original Pod name missing"))?
        .to_string();

    let uid = pod["metadata"]["uid"]
        .as_str()
        .ok_or_else(|| anyhow!("Original Pod UID missing"))?
        .to_string();

    let ip: IpAddr = pod["status"]["podIP"]
        .as_str()
        .ok_or_else(|| anyhow!("Original Pod IP missing"))?
        .parse()?;

    Ok(OriginalPod { name, uid, ip })
}

async fn probe_from_worker4(
    target: &SshPodTarget,
    pod: &OriginalPod,
    timeout_ms: u64,
) -> VerificationResult {
    let checked_at = Utc::now();
    let started = Instant::now();

    let user = env::var("FAILURE_AWARE_VERIFIER_SSH_USER")
        .unwrap_or_else(|_| "ubuntu".to_string());

    if user.is_empty()
        || !user.chars().all(|c| {
            c.is_ascii_alphanumeric() || c == '_' || c == '-'
        })
    {
        return indeterminate_result(
            "Invalid verifier SSH user".to_string()
        );
    }

    let home = env::var("HOME").unwrap_or_default();

    let key = env::var("FAILURE_AWARE_VERIFIER_SSH_KEY")
        .unwrap_or_else(|_| {
            format!("{home}/.ssh/k8s-aware")
        });

    let remote = format!(
        "{}@{}",
        user,
        target.verifier_host
    );

    // Only an IP address obtained from Kubernetes is inserted.
    // The remote command never follows the gateway or Service.
    //
    // Exit status 0 from SSH means the remote probe executed.
    // Its output distinguishes HTTP failure from verifier failure.
    let remote_command = format!(
        "code=$(curl -sS --noproxy '*' \
         --connect-timeout 2 --max-time 3 \
         -o /dev/null -w '%{{http_code}}' \
         'http://{}:8080/openmrs/health/started' \
         2>/dev/null); \
         rc=$?; \
         printf 'PROBE_RESULT:%s:%s\\n' \"$rc\" \"$code\"",
        pod.ip
    );

    let mut command = Command::new("ssh");

    command
        .arg("-i")
        .arg(&key)
        .arg("-o")
        .arg("BatchMode=yes")
        .arg("-o")
        .arg("StrictHostKeyChecking=yes")
        .arg("-o")
        .arg("ConnectTimeout=3")
        .arg("-o")
        .arg("ServerAliveInterval=2")
        .arg("-o")
        .arg("ServerAliveCountMax=1")
        .arg(remote)
        .arg(remote_command)
        .kill_on_drop(true);

    let duration = Duration::from_millis(
        timeout_ms.saturating_add(5000)
    );

    let output = match timeout(duration, command.output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(error)) => {
            return indeterminate_result(format!(
                "SSH execution failed: {error}"
            ));
        }
        Err(_) => {
            return indeterminate_result(
                "SSH verifier timed out".to_string()
            );
        }
    };

    let latency_ms = started.elapsed().as_secs_f64() * 1000.0;

    if !output.status.success() {
        return indeterminate_result(format!(
            "SSH verifier failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);

    let line = match stdout
        .lines()
        .find(|line| line.starts_with("PROBE_RESULT:"))
    {
        Some(line) => line,
        None => {
            return indeterminate_result(
                "Verifier returned no valid probe result".to_string()
            );
        }
    };

    let fields: Vec<&str> = line.split(':').collect();

    if fields.len() != 3 {
        return indeterminate_result(
            "Malformed verifier response".to_string()
        );
    }

    let curl_rc: i32 = match fields[1].parse() {
        Ok(value) => value,
        Err(_) => {
            return indeterminate_result(
                "Invalid remote curl exit code".to_string()
            );
        }
    };

    let status: u16 = match fields[2].parse() {
        Ok(value) => value,
        Err(_) => {
            return indeterminate_result(
                "Invalid remote HTTP status".to_string()
            );
        }
    };

    let reachable = curl_rc == 0 && (200..300).contains(&status);

    VerificationResult {
        checked_at,
        reachable,
        http_status: if status == 0 {
            None
        } else {
            Some(status)
        },
        latency_ms,
        error: if reachable {
            None
        } else {
            Some(format!(
                "Original backend probe failed: curl_rc={curl_rc}, HTTP={status}"
            ))
        },
    }
}

pub async fn verify_http(
    url: &str,
    timeout_ms: u64,
) -> Result<VerificationResult> {
    let client = Client::builder()
        .timeout(Duration::from_millis(timeout_ms))
        .build()?;

    let checked_at = Utc::now();
    let start = Instant::now();

    let result = client.get(url).send().await;

    let latency_ms = start.elapsed().as_secs_f64() * 1000.0;

    match result {
        Ok(response) => {
            let status = response.status().as_u16();

            Ok(VerificationResult {
                checked_at,
                reachable: response.status().is_success(),
                http_status: Some(status),
                latency_ms,
                error: None,
            })
        }

        Err(error) => Ok(VerificationResult {
            checked_at,
            reachable: false,
            http_status: None,
            latency_ms,
            error: Some(error.to_string()),
        }),
    }
}

pub async fn verify_http_bounded(
    url: &str,
    timeout_ms: u64,
    attempts: u32,
    interval_ms: u64,
) -> Result<VerificationEvidence> {
    let mut results = Vec::new();
    let mut successes = 0;
    let mut failures = 0;
    let mut indeterminate = false;

    if attempts == 0 {
        return Err(anyhow!("Verification attempts must be positive"));
    }

    // Resolve the original Pod once for the complete sequence.
    // Never select a replacement between probe attempts.
    let ssh_context = if url.starts_with("ssh-pod://") {
        match parse_ssh_target(url) {
            Ok(target) => {
                match discover_original(&target, timeout_ms).await {
                    Ok(pod) => {
                        println!(
                            "[VERIFY TARGET] pod={} uid={} node={} ip={} verifier={}",
                            pod.name,
                            pod.uid,
                            target.node,
                            pod.ip,
                            target.verifier_host
                        );

                        Some((target, pod))
                    }

                    Err(error) => {
                        println!(
                            "[VERIFY INDETERMINATE] Original Pod discovery: {}",
                            error
                        );

                        return Ok(VerificationEvidence {
                            attempts: 0,
                            successes: 0,
                            failures: 0,
                            results: vec![
                                indeterminate_result(error.to_string())
                            ],
                            indeterminate: true,
                        });
                    }
                }
            }

            Err(error) => {
                return Ok(VerificationEvidence {
                    attempts: 0,
                    successes: 0,
                    failures: 0,
                    results: vec![
                        indeterminate_result(error.to_string())
                    ],
                    indeterminate: true,
                });
            }
        }
    } else {
        None
    };

    for attempt in 1..=attempts {
        let result = match &ssh_context {
            Some((target, pod)) => {
                probe_from_worker4(target, pod, timeout_ms).await
            }
            None => verify_http(url, timeout_ms).await?,
        };

        if is_indeterminate(&result) {
            indeterminate = true;
        } else if result.reachable {
            successes += 1;
        } else {
            failures += 1;
        }

        println!(
            "[VERIFY] attempt={}/{} | reachable={} | HTTP={:?} | latency={:.3} ms | error={:?}",
            attempt,
            attempts,
            result.reachable,
            result.http_status,
            result.latency_ms,
            result.error
        );

        results.push(result);

        if attempt < attempts {
            sleep(Duration::from_millis(interval_ms)).await;
        }
    }

    Ok(VerificationEvidence {
        attempts,
        successes,
        failures,
        results,
        indeterminate,
    })
}