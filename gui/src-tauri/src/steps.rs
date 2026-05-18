/// Returns (label_zh, detail_zh) for a step key.
/// Unknown keys return the key itself as the label and empty detail.
pub fn step_label(key: &str) -> (String, &'static str) {
    match key {
        "base-deps"    => ("正在安装系统依赖…".into(),    "curl / git / openssl / unzip"),
        "system-tools" => ("正在安装系统工具…".into(),    "ripgrep / ffmpeg / build 工具链"),
        "fnm"          => ("正在安装 fnm…".into(),         "Node 版本管理器"),
        "node"         => ("正在配置 Node 运行时…".into(), "Node v24 via fnm"),
        "hermes-node"  => ("正在配置 Hermes Node…".into(), "Node v22 for Hermes"),
        "uv"           => ("正在安装 uv…".into(),           "Python 包管理器"),
        "python"       => ("正在安装 Python…".into(),       "Python 3.11 via uv"),
        "pnpm"         => ("正在准备 pnpm…".into(),         "via corepack"),
        "npmrc"        => ("正在写入镜像源…".into(),        "~/.npmrc"),
        "shell-rc"     => ("正在配置 Shell 环境…".into(),   "~/.bashrc / ~/.zshrc"),
        "openclaw"     => ("正在安装 OpenClaw…".into(),     "pnpm add -g openclaw"),
        "hermes"       => ("正在安装 Hermes…".into(),       "克隆代码仓库 + 上游安装脚本"),
        "done"         => ("✓ 完成".into(),                 ""),
        other          => (other.to_string(), ""),
    }
}

/// Parse a stdout line from the installer. Returns Some(step_key) if the line
/// matches the step-header pattern `==> <key>:`.
pub fn parse_step_line(line: &str) -> Option<&str> {
    let trimmed = line.trim();
    if let Some(rest) = trimmed.strip_prefix("==> ") {
        if let Some(colon_pos) = rest.find(':') {
            return Some(&rest[..colon_pos]);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- parse_step_line tests (TDD: red written first, impl above makes green) ----

    #[test]
    fn parse_step_line_matches_base_deps() {
        let line = "==> base-deps: checking curl, git, openssl, unzip";
        assert_eq!(parse_step_line(line), Some("base-deps"));
    }

    #[test]
    fn parse_step_line_matches_fnm() {
        let line = "==> fnm: installing v1.38.1 (vendored)";
        assert_eq!(parse_step_line(line), Some("fnm"));
    }

    #[test]
    fn parse_step_line_matches_node() {
        let line = "==> node: installing v22.13.1 via fnm";
        assert_eq!(parse_step_line(line), Some("node"));
    }

    #[test]
    fn parse_step_line_matches_pnpm() {
        let line = "==> pnpm: enabling via corepack";
        assert_eq!(parse_step_line(line), Some("pnpm"));
    }

    #[test]
    fn parse_step_line_matches_npmrc() {
        let line = "==> npmrc: writing mirror block to ~/.npmrc";
        assert_eq!(parse_step_line(line), Some("npmrc"));
    }

    #[test]
    fn parse_step_line_matches_openclaw() {
        let line = "==> openclaw: pnpm add -g @openclaw/cli";
        assert_eq!(parse_step_line(line), Some("openclaw"));
    }

    #[test]
    fn parse_step_line_matches_hermes() {
        let line = "==> hermes: cloning hermes-agent into ~/code/hermes-agent";
        assert_eq!(parse_step_line(line), Some("hermes"));
    }

    #[test]
    fn parse_step_line_matches_system_tools() {
        let line = "==> system-tools: installing ripgrep, ffmpeg";
        assert_eq!(parse_step_line(line), Some("system-tools"));
    }

    #[test]
    fn parse_step_line_matches_shell_rc() {
        let line = "==> shell-rc: updating ~/.bashrc";
        assert_eq!(parse_step_line(line), Some("shell-rc"));
    }

    #[test]
    fn parse_step_line_matches_uv() {
        let line = "==> uv: installing python package manager";
        assert_eq!(parse_step_line(line), Some("uv"));
    }

    #[test]
    fn parse_step_line_matches_python() {
        let line = "==> python: installing 3.11 via uv";
        assert_eq!(parse_step_line(line), Some("python"));
    }

    #[test]
    fn parse_step_line_matches_hermes_node() {
        let line = "==> hermes-node: configuring Node v22";
        assert_eq!(parse_step_line(line), Some("hermes-node"));
    }

    #[test]
    fn parse_step_line_does_not_match_non_step_line() {
        let line = "    curl 8.7.1                  preexisting";
        assert_eq!(parse_step_line(line), None);
    }

    #[test]
    fn parse_step_line_does_not_match_plain_arrow() {
        let line = "==> some line without colon";
        assert_eq!(parse_step_line(line), None);
    }

    #[test]
    fn parse_step_line_handles_leading_whitespace() {
        let line = "  ==> base-deps: checking";
        assert_eq!(parse_step_line(line), Some("base-deps"));
    }

    #[test]
    fn parse_step_line_returns_none_for_empty() {
        assert_eq!(parse_step_line(""), None);
    }

    // ---- step_label tests ----
    // Note: step_label returns (String, &'static str)

    #[test]
    fn step_label_base_deps() {
        let (label, detail) = step_label("base-deps");
        assert_eq!(label, "正在安装系统依赖…");
        assert!(!detail.is_empty());
    }

    #[test]
    fn step_label_system_tools() {
        let (label, _) = step_label("system-tools");
        assert_eq!(label, "正在安装系统工具…");
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
        assert!(label.contains("镜像源"));
    }

    #[test]
    fn step_label_shell_rc() {
        let (label, _) = step_label("shell-rc");
        assert!(label.contains("Shell"));
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
        assert!(label.contains("完成"));
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
