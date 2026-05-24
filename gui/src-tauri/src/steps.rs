use std::sync::OnceLock;
use regex::Regex;

/// Compiled regex for the @@step:<key>:<label> sentinel emitted by bash scripts.
/// Pattern: ^@@step:([a-z][a-z0-9-]*):(.+)$
///
/// This is the single authoritative sentinel parser for step transitions.
/// Scripts emit `display "@@step:<key>:<label>"` which Rust matches here to
/// produce `InstallerEvent::StepChanged { key, label, detail: "" }`.
///
/// The old `==> <key>:` pattern (parse_step_line) has been removed.
static STEP_RE: OnceLock<Regex> = OnceLock::new();

fn step_regex() -> &'static Regex {
    STEP_RE.get_or_init(|| {
        Regex::new(r"^@@step:([a-z][a-z0-9-]*):(.+)$")
            .expect("@@step regex is valid at compile time")
    })
}

/// Try to parse an `@@step:<key>:<label>` sentinel line.
/// Returns `Some((key, label))` on match, `None` otherwise.
///
/// Called from the Rust event loop on every stdout line. On match, emit
/// `InstallerEvent::StepChanged { key, label, detail: "".into() }` and do NOT
/// emit a `LogLine` for that line.
pub fn parse_step_sentinel(line: &str) -> Option<(String, String)> {
    let caps = step_regex().captures(line.trim())?;
    let key = caps.get(1)?.as_str().to_string();
    let label = caps.get(2)?.as_str().to_string();
    Some((key, label))
}

/// Returns (label_zh, detail_zh) for a step key.
/// Unknown keys return the key itself as the label and empty detail.
///
/// NOTE: This function is NO LONGER called on the live event stream. Labels
/// now travel inline in the `@@step:<key>:<label>` sentinel emitted by the
/// scripts. This function is retained for stub mode / testing / fallback only.
#[allow(dead_code)]
pub fn step_label(key: &str) -> (String, &'static str) {
    match key {
        "base-deps"    => ("Installing base dependencies…".into(), "curl / git / openssl / unzip"),
        "system-tools" => ("Installing system tools…".into(),      "ripgrep / ffmpeg / build chain"),
        "fnm"          => ("Installing fnm…".into(),               "Node version manager"),
        "node"         => ("Configuring Node runtime…".into(),     "Node v24 via fnm"),
        "hermes-node"  => ("Configuring Hermes Node…".into(),      "Node v22 for Hermes"),
        "uv"           => ("Installing uv…".into(),                "Python package manager"),
        "python"       => ("Installing Python…".into(),            "Python 3.11 via uv"),
        "pnpm"         => ("Preparing pnpm…".into(),               "via corepack"),
        "npmrc"        => ("Writing npm registry mirror…".into(),  "~/.npmrc"),
        "shell-rc"     => ("Configuring shell PATH…".into(),       "~/.bashrc / ~/.zshrc"),
        "openclaw"     => ("Installing OpenClaw…".into(),          "pnpm add -g openclaw"),
        "hermes"       => ("Installing Hermes…".into(),            "clone repo + upstream installer"),
        "done"         => ("✓ Done".into(),                        ""),
        other          => (other.to_string(), ""),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // =========================================================================
    // parse_step_sentinel tests (RED-GREEN: new @@step: format)
    // =========================================================================

    #[test]
    fn sentinel_matches_base_deps() {
        let line = "@@step:base-deps:Installing base dependencies…";
        let result = parse_step_sentinel(line);
        assert!(result.is_some());
        let (key, label) = result.unwrap();
        assert_eq!(key, "base-deps");
        assert_eq!(label, "Installing base dependencies…");
    }

    #[test]
    fn sentinel_matches_node() {
        let line = "@@step:node:Configuring Node 24 runtime…";
        let (key, label) = parse_step_sentinel(line).expect("should match");
        assert_eq!(key, "node");
        assert_eq!(label, "Configuring Node 24 runtime…");
    }

    #[test]
    fn sentinel_matches_pnpm() {
        let line = "@@step:pnpm:Preparing the pnpm package manager…";
        let (key, label) = parse_step_sentinel(line).expect("should match");
        assert_eq!(key, "pnpm");
        assert_eq!(label, "Preparing the pnpm package manager…");
    }

    #[test]
    fn sentinel_matches_openclaw_pkg() {
        let line = "@@step:openclaw-pkg:Installing OpenClaw package…";
        let (key, label) = parse_step_sentinel(line).expect("should match");
        assert_eq!(key, "openclaw-pkg");
        assert_eq!(label, "Installing OpenClaw package…");
    }

    #[test]
    fn sentinel_matches_hermes_upstream() {
        let line = "@@step:hermes-upstream:Running upstream Hermes installer (2–5 min on first run)…";
        let (key, label) = parse_step_sentinel(line).expect("should match");
        assert_eq!(key, "hermes-upstream");
        assert_eq!(label, "Running upstream Hermes installer (2–5 min on first run)…");
    }

    #[test]
    fn sentinel_matches_detect_platform() {
        let line = "@@step:detect-platform:Detecting system platform…";
        let (key, label) = parse_step_sentinel(line).expect("should match");
        assert_eq!(key, "detect-platform");
        assert_eq!(label, "Detecting system platform…");
    }

    #[test]
    fn sentinel_label_comes_from_sentinel_not_lookup() {
        // The label in the sentinel is authoritative; step_label() must NOT be
        // called to override it. This test verifies the sentinel returns the
        // label exactly as emitted by the script.
        let line = "@@step:node:Configuring Node runtime (from script)";
        let (_, label) = parse_step_sentinel(line).expect("should match");
        assert_eq!(label, "Configuring Node runtime (from script)");
        // The step_label lookup would return a different string:
        let (lookup_label, _) = step_label("node");
        assert_ne!(label, lookup_label); // they differ — script label wins
    }

    #[test]
    fn sentinel_does_not_match_plain_line() {
        assert!(parse_step_sentinel("Installing base dependencies…").is_none());
    }

    #[test]
    fn sentinel_does_not_match_old_style_arrow() {
        assert!(parse_step_sentinel("==> base-deps: checking curl").is_none());
    }

    #[test]
    fn sentinel_does_not_match_pnpm_output() {
        assert!(parse_step_sentinel("pnpm add -g openclaw@latest").is_none());
    }

    #[test]
    fn sentinel_does_not_match_empty() {
        assert!(parse_step_sentinel("").is_none());
    }

    #[test]
    fn sentinel_does_not_match_partial_prefix() {
        assert!(parse_step_sentinel("@@step:bad").is_none());
        assert!(parse_step_sentinel("@@step::label").is_none());
    }

    #[test]
    fn sentinel_key_must_start_with_lowercase_letter() {
        // Key starting with digit should NOT match (regex requires [a-z] first)
        assert!(parse_step_sentinel("@@step:1bad:label").is_none());
    }

    #[test]
    fn sentinel_handles_leading_whitespace() {
        // trim() is applied before regex match
        let line = "  @@step:fnm:Installing fnm…";
        let result = parse_step_sentinel(line);
        assert!(result.is_some());
        let (key, _) = result.unwrap();
        assert_eq!(key, "fnm");
    }

    #[test]
    fn sentinel_label_may_contain_colons() {
        // Label part is (.+) which matches colons — only first two colons are split
        let line = "@@step:start:Initializing: preparing environment";
        let (key, label) = parse_step_sentinel(line).expect("should match");
        assert_eq!(key, "start");
        assert_eq!(label, "Initializing: preparing environment");
    }

    // =========================================================================
    // step_label tests (stub mode / backward compat — not used on live stream)
    // =========================================================================

    #[test]
    fn step_label_base_deps() {
        let (label, detail) = step_label("base-deps");
        assert_eq!(label, "Installing base dependencies…");
        assert!(!detail.is_empty());
    }

    #[test]
    fn step_label_system_tools() {
        let (label, _) = step_label("system-tools");
        assert_eq!(label, "Installing system tools…");
    }

    #[test]
    fn step_label_fnm() {
        let (label, _) = step_label("fnm");
        assert!(label.contains("fnm"));
    }

    #[test]
    fn step_label_node() {
        let (label, _) = step_label("node");
        assert!(label.contains("Node"));
    }

    #[test]
    fn step_label_pnpm() {
        let (label, _) = step_label("pnpm");
        assert!(label.contains("pnpm"));
    }

    #[test]
    fn step_label_npmrc() {
        let (label, _) = step_label("npmrc");
        assert!(label.contains("registry"));
    }

    #[test]
    fn step_label_shell_rc() {
        let (label, _) = step_label("shell-rc");
        assert!(label.contains("shell"));
    }

    #[test]
    fn step_label_openclaw() {
        let (label, _) = step_label("openclaw");
        assert!(label.contains("OpenClaw"));
    }

    #[test]
    fn step_label_hermes() {
        let (label, _) = step_label("hermes");
        assert!(label.contains("Hermes"));
    }

    #[test]
    fn step_label_done() {
        let (label, detail) = step_label("done");
        assert!(label.contains("Done"));
        assert_eq!(detail, "");
    }

    #[test]
    fn step_label_unknown_key_returns_key_as_label() {
        let (label, detail) = step_label("some-unknown-step");
        assert_eq!(label, "some-unknown-step");
        assert_eq!(detail, "");
    }

    #[test]
    fn step_label_uv() {
        let (label, _) = step_label("uv");
        assert!(label.contains("uv"));
    }

    #[test]
    fn step_label_python() {
        let (label, _) = step_label("python");
        assert!(label.contains("Python"));
    }

    #[test]
    fn step_label_hermes_node() {
        let (label, _) = step_label("hermes-node");
        assert!(label.contains("Hermes"));
    }
}
