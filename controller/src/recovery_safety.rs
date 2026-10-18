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
    /*
     * Preserve the existing safety policy:
     *
     * Duplication sensitivity determines whether fencing
     * is required before a replacement may be released.
     *
     * Workload reachability alone does not prove that
     * the original writer has lost authority.
     */

    if !workload.duplication_sensitive {
        return RecoverySafetyAwareness {
            state: RecoverySafetyState::Safe,
            fencing_required: false,
            fencing_supported,
        };
    }

    /*
     * Fencing support means a fencing mechanism is
     * configured, not that fencing has succeeded.
     *
     * Actual fencing must be executed and verified
     * by enforcement.rs before releasing recovery.
     */
    if fencing_supported {
        return RecoverySafetyAwareness {
            state: RecoverySafetyState::FencingRequired,
            fencing_required: true,
            fencing_supported: true,
        };
    }

    /*
     * Fail closed when the workload is duplication
     * sensitive and no fencing mechanism is available.
     */
    RecoverySafetyAwareness {
        state: RecoverySafetyState::Unsafe,
        fencing_required: true,
        fencing_supported: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn workload(duplication_sensitive: bool) -> WorkloadAwareness {
        WorkloadAwareness::new(
            "test-workload".to_string(),
            "stateful".to_string(),
            duplication_sensitive,
        )
    }

    #[test]
    fn non_duplication_sensitive_workload_is_safe() {
        let result = evaluate_recovery_safety(&workload(false), false);

        assert_eq!(result.state, RecoverySafetyState::Safe);
        assert!(!result.fencing_required);
    }

    #[test]
    fn duplication_sensitive_workload_requires_fencing() {
        let result = evaluate_recovery_safety(&workload(true), true);

        assert_eq!(result.state, RecoverySafetyState::FencingRequired);

        assert!(result.fencing_required);
        assert!(result.fencing_supported);
    }

    #[test]
    fn duplication_sensitive_workload_without_fencing_is_unsafe() {
        let result = evaluate_recovery_safety(&workload(true), false);

        assert_eq!(result.state, RecoverySafetyState::Unsafe);

        assert!(result.fencing_required);
        assert!(!result.fencing_supported);
    }
}
