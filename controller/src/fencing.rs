use anyhow::{Result, anyhow};
use chrono::Utc;
use std::process::Command;

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

pub fn execute_fence(
    fencing_required: bool,
    fencing_supported: bool,
    fencing_command: &str,
) -> Result<FencingResult> {
    if !fencing_required {
        return Ok(FencingResult {
            state: FencingState::NotRequired,

            command: String::new(),

            message: "fencing is not required for this recovery".to_string(),
        });
    }

    if !fencing_supported {
        return Ok(FencingResult {
            state: FencingState::Failed,

            command: fencing_command.to_string(),

            message: "fencing is required but no supported fencing mechanism is available"
                .to_string(),
        });
    }

    if fencing_command.trim().is_empty() {
        return Err(anyhow!("fencing is required but fencing_command is empty"));
    }

    println!(
        "[FENCING] {} | executing={}",
        Utc::now().to_rfc3339(),
        fencing_command
    );

    let output = Command::new("sh").arg("-c").arg(fencing_command).output()?;

    if output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();

        println!(
            "[FENCING RESULT] {} | state=Succeeded | output={}",
            Utc::now().to_rfc3339(),
            stdout
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

        println!(
            "[FENCING RESULT] {} | state=Failed | error={}",
            Utc::now().to_rfc3339(),
            stderr
        );

        Ok(FencingResult {
            state: FencingState::Failed,

            command: fencing_command.to_string(),

            message: stderr,
        })
    }
}
