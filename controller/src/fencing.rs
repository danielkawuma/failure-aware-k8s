use anyhow::Result;
use chrono::Utc;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;
use tokio::time::timeout;

#[derive(Debug, Clone, PartialEq)]
pub enum FencingState {
    NotRequired,
    Succeeded,
    Failed,
}

#[derive(Debug, Clone)]
pub struct FencingResult {
    pub state: FencingState,
    pub command: String,
    pub message: String,
}

const DEFAULT_FENCING_TIMEOUT_MS: u64 = 30_000;

fn failed(command: &str, message: String) -> FencingResult {
    FencingResult {
        state: FencingState::Failed,
        command: command.to_string(),
        message,
    }
}

pub async fn execute_fence(
    fencing_required: bool,
    fencing_supported: bool,
    fencing_command: &str,
) -> Result<FencingResult> {
    execute_fence_bounded(
        fencing_required,
        fencing_supported,
        fencing_command,
        DEFAULT_FENCING_TIMEOUT_MS,
    )
    .await
}

pub async fn execute_fence_bounded(
    fencing_required: bool,
    fencing_supported: bool,
    fencing_command: &str,
    timeout_ms: u64,
) -> Result<FencingResult> {
    if !fencing_required {
        return Ok(FencingResult {
            state: FencingState::NotRequired,
            command: String::new(),
            message: "fencing is not required for this recovery".to_string(),
        });
    }

    if !fencing_supported {
        return Ok(failed(
            fencing_command,
            "fencing is required but no supported fencing mechanism is available".to_string(),
        ));
    }

    if fencing_command.trim().is_empty() {
        return Ok(failed(
            fencing_command,
            "fencing is required but fencing_command is empty".to_string(),
        ));
    }

    if timeout_ms == 0 {
        return Ok(failed(
            fencing_command,
            "fencing timeout must be greater than zero".to_string(),
        ));
    }

    println!(
        "[FENCING] {} | starting fencing command | timeout_ms={}",
        Utc::now().to_rfc3339(),
        timeout_ms
    );

    let mut command = Command::new("sh");

    command
        .arg("-c")
        .arg(fencing_command)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return Ok(failed(
                fencing_command,
                format!("failed to start fencing command: {}", error),
            ));
        }
    };

    let result = timeout(Duration::from_millis(timeout_ms), child.wait_with_output()).await;

    match result {
        Ok(Ok(output)) => {
            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();

                println!(
                    "[FENCING RESULT] {} | state=Succeeded",
                    Utc::now().to_rfc3339()
                );

                Ok(FencingResult {
                    state: FencingState::Succeeded,
                    command: fencing_command.to_string(),
                    message: if stdout.is_empty() {
                        "fencing command completed successfully".to_string()
                    } else {
                        stdout
                    },
                })
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

                let message = format!(
                    "fencing command exited with status {}: {}",
                    output.status, stderr
                );

                println!(
                    "[FENCING RESULT] {} | state=Failed | reason={}",
                    Utc::now().to_rfc3339(),
                    message
                );

                Ok(failed(fencing_command, message))
            }
        }

        Ok(Err(error)) => {
            let message = format!("fencing execution failed: {}", error);

            println!(
                "[FENCING RESULT] {} | state=Failed | reason={}",
                Utc::now().to_rfc3339(),
                message
            );

            Ok(failed(fencing_command, message))
        }

        Err(_) => {
            let message = format!(
                "fencing exceeded {} ms; outcome is unverified and recovery must remain blocked",
                timeout_ms
            );

            println!(
                "[FENCING TIMEOUT] {} | timeout_ms={} | recovery_authorized=false",
                Utc::now().to_rfc3339(),
                timeout_ms
            );

            Ok(failed(fencing_command, message))
        }
    }
}
