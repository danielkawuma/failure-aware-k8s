Backward-compatible controller configuration patch.
Back up controller/src/main.rs before copying.
Default controller/config/controller.json remains unchanged.
For OpenMRS use: FAILURE_AWARE_CONTROLLER_CONFIG="$PWD/controller/config/openmrs-backend.json" ./controller/target/debug/failure-aware-controller
For legacy use the existing command without the variable.
Review CPU/memory requirements and URL against actual Deployment.
Does not enable Scenario C or MariaDB fencing.
