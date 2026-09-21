use crate::recovery_safety::RecoverySafetyAwareness;
use crate::resource::ResourceAwareness;
use crate::verification::VerificationEvidence;
use crate::workload::WorkloadAwareness;

#[derive(Debug, Clone, PartialEq)]
pub enum OperationalState {
    ReachableOutsideControlPlane,
    Unreachable,
    Indeterminate,
}

#[derive(Debug, Clone)]
pub struct AwarenessContext {
    pub operational_state: OperationalState,
    pub workload: WorkloadAwareness,
    pub resources: ResourceAwareness,
    pub recovery_safety: RecoverySafetyAwareness,
}

pub fn classify_operational_state(
    evidence: &VerificationEvidence,
) -> OperationalState {
    if evidence.successes > evidence.failures {
        OperationalState::ReachableOutsideControlPlane
    } else if evidence.successes == 0
        && evidence.failures > 0
    {
        OperationalState::Unreachable
    } else {
        OperationalState::Indeterminate
    }
}