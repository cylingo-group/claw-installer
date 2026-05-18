use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum InstallerEvent {
    /// A new install step has become active.
    StepChanged {
        key: String,
        label: String,
        detail: String,
    },
    /// An agent's status changed (installed, error, etc.).
    StatusChanged {
        agent: String,
        status: String,
        message: Option<String>,
    },
    /// Install/uninstall process completed.
    Finished {
        success: bool,
        message: Option<String>,
    },
    /// Raw log line (written to disk; not surfaced in UI).
    LogLine { line: String },
}

#[derive(Debug, Serialize, Deserialize)]
pub struct InstallerStatePayload {
    pub openclaw: String, // "installed" | "not-installed"
    pub hermes: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct HostStatusPayload {
    pub status: String, // "ok" | "needs-wsl-install" | "needs-ubuntu-firstrun"
    pub command: Option<String>,
}
