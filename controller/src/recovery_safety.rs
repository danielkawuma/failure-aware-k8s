use crate::workload::WorkloadAwareness;

#[derive(Debug, Clone, PartialEq)]
pub enum RecoverySafetyState {
    Safe,
    FencingRequired,
    Unsafe,
}

#[derive(Debug, Clone)]
pub struct RecoverySafetyAwareness {
    pub state: RecoverySafetyState,
    pub fencing_required: bool,
    pub fencing_supported: bool,
}

pub fn evaluate_recovery_safety(
    workload: &WorkloadAwareness,
    fencing_supported: bool,
) -> RecoverySafetyAwareness {
    if !workload.duplication_sensitive {
        return RecoverySafetyAwareness {
            state: RecoverySafetyState::Safe,
            fencing_required: false,
            fencing_supported,
        };
    }

    if workload.duplication_sensitive && fencing_supported {
        return RecoverySafetyAwareness {
            state: RecoverySafetyState::FencingRequired,
            fencing_required: true,
            fencing_supported: true,
        };
    }

    RecoverySafetyAwareness {
        state: RecoverySafetyState::Unsafe,
        fencing_required: true,
        fencing_supported: false,
    }
}
