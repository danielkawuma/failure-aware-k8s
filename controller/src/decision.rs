use crate::awareness::{AwarenessContext, OperationalState};
use crate::recovery_safety::RecoverySafetyState;
use crate::resource::ResourceState;

#[derive(Debug, Clone, PartialEq)]
pub enum RecoveryDecision {
    Preserve,
    Recover,
}

#[derive(Debug, Clone)]
pub struct DecisionResult {
    pub decision: RecoveryDecision,
    pub reason: String,
    pub fencing_required: bool,

    /*
     * None preserves the original controller behaviour.
     * Some(node) is populated only when multi-candidate
     * selection is enabled and a destination was selected.
     */
    pub selected_candidate: Option<String>,
}

pub fn decide(context: &AwarenessContext) -> DecisionResult {
    match context.operational_state {
        OperationalState::ReachableOutsideControlPlane => {
            DecisionResult {
                decision:
                    RecoveryDecision::Preserve,

                reason:
                    "workload remains reachable outside the control-plane path; unnecessary recovery is avoided"
                        .to_string(),

                fencing_required: false,
                selected_candidate: None,
            }
        }

        OperationalState::Indeterminate => {
            DecisionResult {
                decision:
                    RecoveryDecision::Preserve,

                reason:
                    "operational state is indeterminate; disruptive recovery is not justified"
                        .to_string(),

                fencing_required: false,
                selected_candidate: None,
            }
        }

        OperationalState::Unreachable => {
            if context.resources.state
                != ResourceState::Available
            {
                return DecisionResult {
                    decision:
                        RecoveryDecision::Preserve,

                    reason:
                        "no suitable recovery capacity is currently available"
                            .to_string(),

                    fencing_required: false,
                    selected_candidate: None,
                };
            }

            let selected_candidate =
                if context
                    .resources
                    .multi_candidate_selection
                {
                    Some(
                        context
                            .resources
                            .candidate_node
                            .clone()
                    )
                } else {
                    None
                };

            match context.recovery_safety.state {
                RecoverySafetyState::Safe => {
                    DecisionResult {
                        decision:
                            RecoveryDecision::Recover,

                        reason:
                            "workload is unreachable, recovery capacity is available, and recovery is safe"
                                .to_string(),

                        fencing_required: false,
                        selected_candidate,
                    }
                }

                RecoverySafetyState::FencingRequired => {
                    DecisionResult {
                        decision:
                            RecoveryDecision::Recover,

                        reason:
                            "workload is unreachable and recovery is viable, but fencing must complete before replacement"
                                .to_string(),

                        fencing_required: true,
                        selected_candidate,
                    }
                }

                RecoverySafetyState::Unsafe => {
                    DecisionResult {
                        decision:
                            RecoveryDecision::Preserve,

                        reason:
                            "recovery cannot safely proceed because required fencing is unavailable"
                                .to_string(),

                        fencing_required: true,
                        selected_candidate: None,
                    }
                }
            }
        }
    }
}
