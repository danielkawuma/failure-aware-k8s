use chrono::Utc;

use crate::decision::{
    DecisionResult,
    RecoveryDecision,
};

#[derive(Debug, Clone, PartialEq)]
pub enum EnforcementAction {
    PreserveExisting,
    RecoveryPending,
}

#[derive(Debug, Clone)]
pub struct EnforcementResult {
    pub action: EnforcementAction,
    pub enforced: bool,
    pub message: String,
}

pub fn enforce_decision(
    decision: &DecisionResult,
) -> EnforcementResult {
    match decision.decision {
        RecoveryDecision::Preserve => {
            EnforcementResult {
                action:
                    EnforcementAction::PreserveExisting,

                enforced: true,

                message:
                    "existing workload remains bound; no recovery action initiated"
                        .to_string(),
            }
        }

        RecoveryDecision::Recover => {
            EnforcementResult {
                action:
                    EnforcementAction::RecoveryPending,

                enforced: false,

                message:
                    "recovery selected; recovery execution is handled by the subsequent recovery path"
                        .to_string(),
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
        Utc::now().to_rfc3339(),
        node,
        result.action,
        result.enforced,
        result.message
    );
}