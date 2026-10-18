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
    // Failure of the independent verification mechanism
    // is not evidence that the original workload failed.
    //
    // Do not authorize recovery on incomplete or
    // unverifiable evidence.
    if evidence.indeterminate || evidence.attempts == 0 {
        return OperationalState::Indeterminate;
    }

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