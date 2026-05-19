use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
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
    /// User-friendly log line (filtered subset, shown in 5-line strip).
    LogLine { line: String },
    /// Absolute path to the full execution log on disk, emitted once at spawn.
    LogPath { path: String },
    /// Windows only: script exited with code 2 — reboot required to continue.
    /// `kind` is "wsl-feature" (WSL features enabled, must reboot) or
    /// "distro-firstrun" (distro installed, user must complete first-run setup).
    RebootRequired { kind: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reboot_required_wsl_feature_round_trips() {
        let event = InstallerEvent::RebootRequired {
            kind: "wsl-feature".to_string(),
        };
        let json = serde_json::to_string(&event).expect("serialize");
        assert!(json.contains(r#""type":"RebootRequired""#), "tag must be RebootRequired, got: {json}");
        assert!(json.contains(r#""kind":"wsl-feature""#), "kind must be wsl-feature, got: {json}");
        let back: InstallerEvent = serde_json::from_str(&json).expect("deserialize");
        match back {
            InstallerEvent::RebootRequired { kind } => assert_eq!(kind, "wsl-feature"),
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    #[test]
    fn reboot_required_distro_firstrun_round_trips() {
        let event = InstallerEvent::RebootRequired {
            kind: "distro-firstrun".to_string(),
        };
        let json = serde_json::to_string(&event).expect("serialize");
        assert!(json.contains(r#""type":"RebootRequired""#));
        assert!(json.contains(r#""kind":"distro-firstrun""#));
        let back: InstallerEvent = serde_json::from_str(&json).expect("deserialize");
        match back {
            InstallerEvent::RebootRequired { kind } => assert_eq!(kind, "distro-firstrun"),
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    #[test]
    fn finished_success_round_trips() {
        let event = InstallerEvent::Finished { success: true, message: None };
        let json = serde_json::to_string(&event).expect("serialize");
        assert!(json.contains(r#""type":"Finished""#));
        let back: InstallerEvent = serde_json::from_str(&json).expect("deserialize");
        match back {
            InstallerEvent::Finished { success, message } => {
                assert!(success);
                assert!(message.is_none());
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    #[test]
    fn step_changed_round_trips() {
        let event = InstallerEvent::StepChanged {
            key: "base-deps".to_string(),
            label: "正在安装系统依赖…".to_string(),
            detail: String::new(),
        };
        let json = serde_json::to_string(&event).expect("serialize");
        assert!(json.contains(r#""type":"StepChanged""#));
        let back: InstallerEvent = serde_json::from_str(&json).expect("deserialize");
        match back {
            InstallerEvent::StepChanged { key, label, .. } => {
                assert_eq!(key, "base-deps");
                assert_eq!(label, "正在安装系统依赖…");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }
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
