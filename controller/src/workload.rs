#[derive(Debug, Clone, PartialEq)]
pub enum WorkloadType {
    Stateless,
    Stateful,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ServiceCriticality {
    Low,
    Medium,
    High,
}

#[derive(Debug, Clone)]
pub struct WorkloadAwareness {
    pub name: String,
    pub workload_type: WorkloadType,
    pub duplication_sensitive: bool,
    pub service_criticality: ServiceCriticality,
}

impl WorkloadType {
    pub fn from_str(value: &str) -> Self {
        match value.to_lowercase().as_str() {
            "stateful" => WorkloadType::Stateful,
            _ => WorkloadType::Stateless,
        }
    }
}

impl ServiceCriticality {
    pub fn from_str(value: &str) -> Self {
        match value.to_lowercase().as_str() {
            "high" => ServiceCriticality::High,
            "low" => ServiceCriticality::Low,
            _ => ServiceCriticality::Medium,
        }
    }
}

impl WorkloadAwareness {
    pub fn new(
        name: String,
        workload_type: String,
        duplication_sensitive: bool,
        service_criticality: String,
    ) -> Self {
        Self {
            name,

            workload_type:
                WorkloadType::from_str(
                    &workload_type
                ),

            duplication_sensitive,

            service_criticality:
                ServiceCriticality::from_str(
                    &service_criticality
                ),
        }
    }
}