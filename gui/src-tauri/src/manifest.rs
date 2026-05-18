/// Manifest TSV parser.
///
/// Format (per installer/lib/manifest.sh):
///   timestamp TAB action TAB target TAB status TAB note
///   (5 columns, 0-indexed: 0=ts, 1=action, 2=target, 3=status, 4=note)
///
/// Comment lines start with '#'. Blank lines are ignored.

#[derive(Debug, PartialEq)]
pub struct AgentInstallStatus {
    pub openclaw: InstallStatus,
    pub hermes: InstallStatus,
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum InstallStatus {
    Installed,
    NotInstalled,
}

impl InstallStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            InstallStatus::Installed => "installed",
            InstallStatus::NotInstalled => "not-installed",
        }
    }
}

/// Parse a manifest TSV string into install status for openclaw and hermes.
///
/// Rules:
/// - openclaw: row where action=="pnpm_global_pkg" AND target=="openclaw",
///   status "installed" or "preexisting" → Installed
/// - hermes: row where action=="hermes_bin",
///   status "installed" or "preexisting" → Installed
pub fn parse_manifest(content: &str) -> AgentInstallStatus {
    let mut openclaw = InstallStatus::NotInstalled;
    let mut hermes = InstallStatus::NotInstalled;

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // Use splitn to get at most 5 parts; extra tabs in note are preserved
        let cols: Vec<&str> = line.splitn(5, '\t').collect();
        if cols.len() < 4 {
            // Malformed line — skip silently (not enough columns)
            continue;
        }
        let action = cols[1];
        let target = cols[2];
        let status = cols[3];
        let is_present = status == "installed" || status == "preexisting";

        if action == "pnpm_global_pkg" && target == "openclaw" && is_present {
            openclaw = InstallStatus::Installed;
        }
        if action == "hermes_bin" && is_present {
            hermes = InstallStatus::Installed;
        }
    }

    AgentInstallStatus { openclaw, hermes }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Helper: build a TSV line
    fn row(ts: &str, action: &str, target: &str, status: &str, note: &str) -> String {
        format!("{}\t{}\t{}\t{}\t{}", ts, action, target, status, note)
    }

    fn ts() -> &'static str {
        "2026-05-19T00:00:00Z"
    }

    // ---- Typical row tests ----

    #[test]
    fn typical_openclaw_row_is_installed() {
        let content = format!(
            "# claw-installer manifest\n# fields: ...\n{}",
            row(ts(), "pnpm_global_pkg", "openclaw", "installed", "v1.4.2")
        );
        let result = parse_manifest(&content);
        assert_eq!(result.openclaw, InstallStatus::Installed);
        assert_eq!(result.hermes, InstallStatus::NotInstalled);
    }

    #[test]
    fn typical_hermes_row_is_installed() {
        let content = row(ts(), "hermes_bin", "hermes", "installed", "");
        let result = parse_manifest(&content);
        assert_eq!(result.hermes, InstallStatus::Installed);
        assert_eq!(result.openclaw, InstallStatus::NotInstalled);
    }

    #[test]
    fn both_agents_installed() {
        let content = format!(
            "{}\n{}",
            row(ts(), "pnpm_global_pkg", "openclaw", "installed", ""),
            row(ts(), "hermes_bin", "hermes", "installed", "")
        );
        let result = parse_manifest(&content);
        assert_eq!(result.openclaw, InstallStatus::Installed);
        assert_eq!(result.hermes, InstallStatus::Installed);
    }

    // ---- Preexisting row ----

    #[test]
    fn preexisting_openclaw_counts_as_installed() {
        let content = row(ts(), "pnpm_global_pkg", "openclaw", "preexisting", "");
        let result = parse_manifest(&content);
        assert_eq!(result.openclaw, InstallStatus::Installed);
    }

    #[test]
    fn preexisting_hermes_counts_as_installed() {
        let content = row(ts(), "hermes_bin", "hermes", "preexisting", "");
        let result = parse_manifest(&content);
        assert_eq!(result.hermes, InstallStatus::Installed);
    }

    // ---- Partial install ----

    #[test]
    fn partial_install_only_openclaw_present() {
        let content = format!(
            "{}\n{}\n{}",
            row(ts(), "apt_pkg", "curl", "preexisting", ""),
            row(ts(), "pnpm_global_pkg", "openclaw", "installed", ""),
            row(ts(), "fnm_install", "fnm", "installed", ""),
        );
        let result = parse_manifest(&content);
        assert_eq!(result.openclaw, InstallStatus::Installed);
        assert_eq!(result.hermes, InstallStatus::NotInstalled);
    }

    #[test]
    fn partial_install_only_hermes_present() {
        let content = row(ts(), "hermes_bin", "hermes", "installed", "");
        let result = parse_manifest(&content);
        assert_eq!(result.openclaw, InstallStatus::NotInstalled);
        assert_eq!(result.hermes, InstallStatus::Installed);
    }

    // ---- Missing file ----

    #[test]
    fn empty_content_returns_not_installed() {
        let result = parse_manifest("");
        assert_eq!(result.openclaw, InstallStatus::NotInstalled);
        assert_eq!(result.hermes, InstallStatus::NotInstalled);
    }

    #[test]
    fn only_comments_returns_not_installed() {
        let content = "# claw-installer manifest — auto-generated, do not edit by hand.\n# fields: timestamp\taction\ttarget\tstatus\tnote\n";
        let result = parse_manifest(content);
        assert_eq!(result.openclaw, InstallStatus::NotInstalled);
        assert_eq!(result.hermes, InstallStatus::NotInstalled);
    }

    // ---- Malformed lines ----

    #[test]
    fn malformed_line_too_few_cols_is_skipped() {
        let content = "not\tenough";
        let result = parse_manifest(content);
        assert_eq!(result.openclaw, InstallStatus::NotInstalled);
        assert_eq!(result.hermes, InstallStatus::NotInstalled);
    }

    #[test]
    fn malformed_line_mixed_with_valid_does_not_break_parsing() {
        let content = format!(
            "bad_line_no_tabs\n{}",
            row(ts(), "pnpm_global_pkg", "openclaw", "installed", "")
        );
        let result = parse_manifest(&content);
        assert_eq!(result.openclaw, InstallStatus::Installed);
    }

    #[test]
    fn unknown_action_is_ignored() {
        let content = row(ts(), "unknown_action", "openclaw", "installed", "");
        let result = parse_manifest(&content);
        // unknown action should not trigger openclaw=installed
        assert_eq!(result.openclaw, InstallStatus::NotInstalled);
    }

    #[test]
    fn status_failed_does_not_count_as_installed() {
        let content = row(ts(), "pnpm_global_pkg", "openclaw", "failed", "");
        let result = parse_manifest(&content);
        assert_eq!(result.openclaw, InstallStatus::NotInstalled);
    }

    #[test]
    fn blank_lines_are_skipped() {
        let content = format!(
            "\n\n{}\n\n",
            row(ts(), "hermes_bin", "hermes", "installed", "")
        );
        let result = parse_manifest(&content);
        assert_eq!(result.hermes, InstallStatus::Installed);
    }

    #[test]
    fn note_column_with_tabs_does_not_corrupt_parsing() {
        // Note column can have arbitrary content; splitn(5) ensures it's captured correctly
        let content = format!(
            "{}\t{}\t{}\t{}\t{}",
            ts(), "pnpm_global_pkg", "openclaw", "installed", "note with\ttab inside"
        );
        let result = parse_manifest(&content);
        assert_eq!(result.openclaw, InstallStatus::Installed);
    }
}
