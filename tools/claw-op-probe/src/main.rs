//! claw-op-probe — End-to-end verification of the proposed op-dispatch
//! architecture for claw-installer.
//!
//! Runs a battery of scenarios on Windows:
//!
//!   E. Environment       (info — what does WSL look like?)
//!   P. PowerShell parse  (does the new glue layer parse on this PS version?)
//!   G. Glue layer        (PS → bash dispatch + validation)
//!   S. Stdin transport   (INSTALLER_OP_STDIN_B64 → temp-file inside WSL)
//!   N. common.sh source  (the architectural fix — does PATH get composed?)
//!   X. End-to-end        (apply-model-config dry-run, no mutation)
//!
//! All output is mirrored to stdout AND `claw-op-probe.log` next to the .exe.
//! Each scenario reports PASS / FAIL with the command, exit code, stdout,
//! and stderr captured.
//!
//! Build (from macOS, cross-compile to Windows):
//!   cd tools/claw-op-probe
//!   cargo xwin build --release --target x86_64-pc-windows-msvc
//!
//! Resulting .exe at:
//!   target/x86_64-pc-windows-msvc/release/claw-op-probe.exe
//!
//! Ship the .exe + the shell-overlay/ directory together (same parent dir).

use std::env;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;

#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

// ─────────────────────────────────────────────────────────────────────────
// Mirrored stdout + file logger.

struct Logger {
    file: File,
    pass: u32,
    fail: u32,
    skip: u32,
}

impl Logger {
    fn new(path: &Path) -> std::io::Result<Self> {
        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(path)?;
        Ok(Self { file, pass: 0, fail: 0, skip: 0 })
    }

    fn line(&mut self, msg: &str) {
        println!("{}", msg);
        let _ = writeln!(self.file, "{}", msg);
        let _ = self.file.flush();
    }

    fn blank(&mut self) {
        self.line("");
    }

    fn section(&mut self, title: &str) {
        self.blank();
        self.line("════════════════════════════════════════════════════════════════");
        self.line(&format!(" {}", title));
        self.line("════════════════════════════════════════════════════════════════");
    }

    fn scenario(&mut self, tag: &str, desc: &str) {
        self.blank();
        self.line(&format!("─── {} — {} ───", tag, desc));
    }

    fn pass(&mut self, tag: &str, why: &str) {
        self.pass += 1;
        self.line(&format!("✓ {} PASS — {}", tag, why));
    }

    fn fail(&mut self, tag: &str, why: &str) {
        self.fail += 1;
        self.line(&format!("✗ {} FAIL — {}", tag, why));
    }

    fn skip(&mut self, tag: &str, why: &str) {
        self.skip += 1;
        self.line(&format!("⚠ {} SKIP — {}", tag, why));
    }

    fn dump_result(&mut self, r: &RunResult) {
        self.line(&format!("[exit] {:?}", r.code));
        if !r.stdout.is_empty() {
            self.line("[stdout]");
            for l in r.stdout.lines() {
                self.line(&format!("  > {}", l));
            }
        }
        if !r.stderr.is_empty() {
            self.line("[stderr]");
            for l in r.stderr.lines() {
                self.line(&format!("  ! {}", l));
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Process helpers.

struct RunResult {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

impl RunResult {
    fn ok(&self) -> bool {
        self.code == Some(0)
    }
    fn merged(&self) -> String {
        let mut s = self.stdout.clone();
        if !self.stderr.is_empty() {
            if !s.is_empty() {
                s.push('\n');
            }
            s.push_str(&self.stderr);
        }
        s
    }
}

fn run_cmd(cmd: &mut Command) -> RunResult {
    run_cmd_with_stdin(cmd, &[])
}

fn run_cmd_with_stdin(cmd: &mut Command, stdin: &[u8]) -> RunResult {
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());

    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return RunResult {
                code: None,
                stdout: String::new(),
                stderr: format!("spawn failed: {}", e),
            };
        }
    };

    if !stdin.is_empty() {
        if let Some(mut s) = child.stdin.take() {
            let _ = s.write_all(stdin);
            // drop closes the pipe
        }
    } else {
        // Close stdin even when empty (cat/read inside the child would otherwise block).
        let _ = child.stdin.take();
    }

    match child.wait_with_output() {
        Ok(out) => RunResult {
            code: out.status.code(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        },
        Err(e) => RunResult {
            code: None,
            stdout: String::new(),
            stderr: format!("wait_with_output failed: {}", e),
        },
    }
}

/// Run a multi-line bash script inside WSL via base64-encoded pipeline.
/// Avoids wsl.exe's argv reparser corrupting embedded quotes — the
/// production transport pattern (Invoke-WslBashStreamed). Uses `bash -l`
/// for the inner shell so .profile is sourced; the script itself runs
/// in that login shell.
fn wsl_via_b64(script: &str) -> Command {
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(script.as_bytes());
    let remote = format!("echo {} | base64 -d | bash -l", b64);
    let mut c = Command::new("wsl.exe");
    c.args(["--", "bash", "-c", &remote]).env("WSL_UTF8", "1");
    c
}

fn powershell(args: &[&str]) -> Command {
    let mut c = Command::new("powershell.exe");
    c.args([
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
    ]);
    c.args(args);
    c
}

// ─────────────────────────────────────────────────────────────────────────
// E. Environment.

fn e1_powershell_version(log: &mut Logger) {
    log.scenario("E1", "PowerShell version (is this PS 5.1 or PS 7+?)");
    let mut c = powershell(&["-Command", "$PSVersionTable | Out-String"]);
    let r = run_cmd(&mut c);
    log.dump_result(&r);
    if r.ok() {
        // Heuristic: stdout contains a "PSVersion" line with the major.
        let major = r
            .stdout
            .lines()
            .find(|l| l.trim_start().starts_with("PSVersion"))
            .and_then(|l| l.split_whitespace().last())
            .and_then(|v| v.split('.').next())
            .and_then(|m| m.parse::<u32>().ok());
        match major {
            Some(5) => log.fail("E1", "PowerShell 5.1 detected — `??` operator will NOT parse"),
            Some(v) if v >= 7 => log.pass("E1", &format!("PowerShell {} — `??` operator works", v)),
            _ => log.skip("E1", "could not parse PSVersion"),
        }
    } else {
        log.fail("E1", "powershell.exe failed to run");
    }
}

fn e2_wsl_version(log: &mut Logger) {
    log.scenario("E2", "wsl.exe --version");
    let mut c = Command::new("wsl.exe");
    c.arg("--version").env("WSL_UTF8", "1");
    let r = run_cmd(&mut c);
    log.dump_result(&r);
    if r.ok() {
        log.pass("E2", "wsl.exe responds to --version");
    } else {
        log.fail("E2", "wsl.exe --version did not exit 0");
    }
}

fn e3_wsl_distros(log: &mut Logger) {
    log.scenario("E3", "wsl.exe -l -v (list distros + default)");
    let mut c = Command::new("wsl.exe");
    c.args(["-l", "-v"]).env("WSL_UTF8", "1");
    let r = run_cmd(&mut c);
    log.dump_result(&r);
    if r.ok() {
        log.pass("E3", "distros listed");
    } else {
        log.fail("E3", "could not list distros");
    }
}

fn e4_wsl_identity(log: &mut Logger) {
    log.scenario("E4", "WSL identity (whoami / pwd / uname)");
    let mut c = wsl_via_b64("echo whoami=$(whoami)\necho pwd=$(pwd)\nuname -a\n");
    let r = run_cmd(&mut c);
    log.dump_result(&r);
    if r.ok() {
        log.pass("E4", "wsl.exe → bash -lc executed");
    } else {
        log.fail("E4", "bash inside WSL did not exit 0");
    }
}

fn e5_path_baseline(log: &mut Logger) {
    log.scenario("E5", "PATH in fresh `bash -lc` (no common.sh)");
    let mut c = wsl_via_b64("printf 'PATH=%s\\n' \"$PATH\"\necho\nprintf '%s\\n' \"$PATH\" | tr ':' '\\n'\n");
    let r = run_cmd(&mut c);
    log.dump_result(&r);
    if r.ok() {
        log.pass("E5", "PATH printed");
    } else {
        log.fail("E5", "could not read PATH");
    }
}

fn e6_command_baseline(log: &mut Logger) {
    log.scenario("E6", "command -v for node/openclaw/pnpm/fnm (BEFORE source)");
    let script = r#"for c in node openclaw pnpm fnm hermes; do
  p=$(command -v "$c" 2>/dev/null || echo "(not found)")
  printf '  %-10s %s\n' "$c" "$p"
done"#;
    let mut c = wsl_via_b64(script);
    let r = run_cmd(&mut c);
    log.dump_result(&r);
    if r.ok() {
        let has_node = r.stdout.contains("node ") && !r.stdout.contains("node       (not found)");
        let has_openclaw = !r.stdout.contains("openclaw   (not found)");
        log.line(&format!(
            "[summary] baseline node-findable={} openclaw-findable={}",
            has_node, has_openclaw
        ));
        log.pass("E6", "resolution checked");
    } else {
        log.fail("E6", "could not run command -v");
    }
}

fn e7_common_sh_exists(log: &mut Logger) {
    log.scenario("E7", "common.sh exists at ~/claw-installer-src/lib/common.sh");
    let mut c = wsl_via_b64("ls -la $HOME/claw-installer-src/lib/common.sh 2>&1; echo exit=$?");
    let r = run_cmd(&mut c);
    log.dump_result(&r);
    let found = r.stdout.contains("common.sh") && !r.stdout.contains("No such file");
    if found {
        log.pass("E7", "common.sh present");
    } else {
        log.fail("E7", "common.sh missing — installer may not have been run yet");
    }
}

fn e8_path_after_source(log: &mut Logger) {
    log.scenario("E8", "PATH AFTER source common.sh (the architectural fix)");
    let script = r#"COMMON="$HOME/claw-installer-src/lib/common.sh"
if [ ! -f "$COMMON" ]; then
  echo "FATAL: $COMMON missing"
  exit 2
fi
source "$COMMON"
echo "PATH=$PATH"
echo
for c in node openclaw pnpm fnm hermes; do
  p=$(command -v "$c" 2>/dev/null || echo "(not found)")
  printf '  %-10s %s\n' "$c" "$p"
done"#;
    let mut c = wsl_via_b64(script);
    let r = run_cmd(&mut c);
    log.dump_result(&r);
    let has_node = r.ok() && r.stdout.contains("node ")
        && !r.stdout.contains("node       (not found)");
    let has_openclaw = r.ok() && !r.stdout.contains("openclaw   (not found)");
    if has_node && has_openclaw {
        log.pass("E8", "node + openclaw both resolvable after source — fix works in principle");
    } else if r.ok() {
        log.fail(
            "E8",
            &format!(
                "source common.sh succeeded but node-findable={} openclaw-findable={}",
                has_node, has_openclaw
            ),
        );
    } else {
        log.fail("E8", "could not source common.sh");
    }
}

// ─────────────────────────────────────────────────────────────────────────
// P. PowerShell parse.

fn parse_ps_file(log: &mut Logger, tag: &str, path: &Path) -> bool {
    log.line(&format!("file: {}", path.display()));
    if !path.exists() {
        log.skip(tag, "file does not exist on this host");
        return false;
    }
    // Use [ScriptBlock]::Create on the file's raw text. If the file uses
    // PS-7-only syntax (e.g. `??`), this throws on PS 5.1.
    let script = format!(
        "$ErrorActionPreference='Stop'; $t = Get-Content -Raw -LiteralPath '{}'; \
         try {{ $null = [ScriptBlock]::Create($t); 'PARSE_OK' }} catch {{ \
         Write-Host 'PARSE_FAIL'; Write-Host $_.Exception.Message; exit 1 }}",
        path.display().to_string().replace('\'', "''")
    );
    let mut c = powershell(&["-Command", &script]);
    let r = run_cmd(&mut c);
    log.dump_result(&r);
    if r.ok() && r.stdout.contains("PARSE_OK") {
        log.pass(tag, "parses cleanly on this PowerShell version");
        true
    } else {
        log.fail(tag, "parser rejected the file (see [stdout]/[stderr])");
        false
    }
}

fn p1_parse_probe(log: &mut Logger, overlay: &Path) {
    log.scenario("P1", "Parse probe's bootstrap-probe.ps1 (must be PS 5.1 OK)");
    let p = overlay.join("bootstrap-probe.ps1");
    parse_ps_file(log, "P1", &p);
}

fn p2_parse_prod(log: &mut Logger) {
    log.scenario("P2", "Parse production shell/windows/bootstrap.ps1 (sanity)");
    // The probe doesn't ship prod ps1, so we look for it via env-var override or skip.
    let prod = std::env::var("CLAW_PROBE_PROD_PS1").ok().map(PathBuf::from);
    if let Some(p) = prod {
        parse_ps_file(log, "P2", &p);
    } else {
        log.skip(
            "P2",
            "CLAW_PROBE_PROD_PS1 not set — set it to your bootstrap.ps1 path to test",
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────
// G. Glue layer (using bootstrap-probe.ps1).

fn invoke_probe_glue(
    overlay: &Path,
    op: &str,
    agent: &str,
    extra_args: &[&str],
    stdin_b64: Option<&str>,
    op_envs: &[(&str, &str)],
) -> RunResult {
    let ps_path = overlay.join("bootstrap-probe.ps1");
    let mut args = vec!["-File", ps_path.to_str().unwrap(), "-Op", op, "-Agent", agent];
    args.extend_from_slice(extra_args);
    let mut c = powershell(&args);
    if let Some(b64) = stdin_b64 {
        c.env("INSTALLER_OP_STDIN_B64", b64);
    } else {
        c.env_remove("INSTALLER_OP_STDIN_B64");
    }
    for (k, v) in op_envs {
        c.env(*k, *v);
    }
    run_cmd(&mut c)
}

fn g1_dryrun(log: &mut Logger, overlay: &Path) {
    log.scenario("G1", "-Op noop -Agent test -DryRun (validation table)");
    let r = invoke_probe_glue(overlay, "noop", "test", &["-DryRun"], None, &[]);
    log.dump_result(&r);
    if r.ok() && r.merged().contains("DRY-RUN") {
        log.pass("G1", "dispatch table accepted noop/test");
    } else {
        log.fail("G1", "dry-run did not complete");
    }
}

fn g2_noop_live(log: &mut Logger, overlay: &Path) {
    log.scenario("G2", "-Op noop -Agent test (LIVE — full PS→WSL chain)");
    let r = invoke_probe_glue(
        overlay,
        "noop",
        "test",
        &[],
        None,
        &[("INSTALLER_OP_HELLO", "from-probe-G2")],
    );
    log.dump_result(&r);
    let landed = r.merged().contains("noop.sh — diagnostic op");
    let env_forwarded = r.merged().contains("INSTALLER_OP_HELLO=from-probe-G2");
    if r.ok() && landed && env_forwarded {
        log.pass("G2", "full PS → WSL → bash chain works, env forwarded");
    } else if r.ok() && landed {
        log.fail("G2", "script landed but INSTALLER_OP_HELLO env not forwarded");
    } else {
        log.fail("G2", "chain broke (check stdout above)");
    }
}

fn g3_unknown_op(log: &mut Logger, overlay: &Path) {
    log.scenario("G3", "-Op bad-op -Agent test (must REJECT)");
    let r = invoke_probe_glue(overlay, "bad-op", "test", &[], None, &[]);
    log.dump_result(&r);
    if !r.ok() && r.merged().contains("Unknown op") {
        log.pass("G3", "rejected as expected");
    } else {
        log.fail("G3", "should have rejected unknown op");
    }
}

fn g4_unknown_agent(log: &mut Logger, overlay: &Path) {
    log.scenario("G4", "-Op echo-stdin -Agent openclaw (must REJECT, table mismatch)");
    let r = invoke_probe_glue(overlay, "echo-stdin", "openclaw", &[], None, &[]);
    log.dump_result(&r);
    if !r.ok() && r.merged().contains("does not support agent") {
        log.pass("G4", "rejected agent mismatch");
    } else {
        log.fail("G4", "should have rejected agent mismatch");
    }
}

// ─────────────────────────────────────────────────────────────────────────
// S. Stdin transport (env-var base64).

fn b64(s: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(s)
}

fn md5_of(bytes: &[u8]) -> String {
    // Simple md5 to verify the round-trip. Use the wsl side's md5sum
    // as the cross-check; here we just need a marker. Compute on the
    // Windows side via PS so the probe stays dependency-light.
    use std::fmt::Write as _;
    // Minimal MD5 — Cargo dep would bloat the binary. We rely on
    // PS to compute and read back, so this is just a sanity tag.
    // Instead, we'll compare via the WSL md5 echoed by echo-stdin.sh.
    let mut s = String::new();
    for b in bytes.iter().take(8) {
        write!(&mut s, "{:02x}", b).ok();
    }
    if bytes.len() > 8 { s.push_str("…"); }
    s
}

fn stdin_check(log: &mut Logger, overlay: &Path, tag: &str, desc: &str, payload: &[u8]) {
    log.scenario(tag, desc);
    log.line(&format!(
        "payload: {} bytes, first8={}",
        payload.len(),
        md5_of(payload)
    ));
    let stdin_b64 = if payload.is_empty() { None } else { Some(b64(payload)) };
    let r = invoke_probe_glue(
        overlay,
        "echo-stdin",
        "test",
        &[],
        stdin_b64.as_deref(),
        &[],
    );
    log.dump_result(&r);
    // Pull the "bytes:" line and md5 from echo-stdin.sh's output.
    let got_bytes = r.merged()
        .lines()
        .find(|l| l.contains("[echo-stdin] bytes:"))
        .and_then(|l| l.split_whitespace().last())
        .and_then(|s| s.parse::<usize>().ok());
    let got_md5 = r.merged()
        .lines()
        .find(|l| l.contains("[echo-stdin] md5:"))
        .and_then(|l| l.split_whitespace().last())
        .map(|s| s.to_string());
    log.line(&format!(
        "expected bytes={} got bytes={:?} md5={:?}",
        payload.len(),
        got_bytes,
        got_md5
    ));
    if r.ok() && got_bytes == Some(payload.len()) {
        log.pass(tag, "stdin round-tripped, byte count matches");
    } else {
        log.fail(tag, "stdin transport broke");
    }
}

fn s1_ascii(log: &mut Logger, overlay: &Path) {
    stdin_check(log, overlay, "S1", "ASCII payload", b"hello-from-claw-op-probe-12345");
}

fn s2_utf8(log: &mut Logger, overlay: &Path) {
    stdin_check(
        log,
        overlay,
        "S2",
        "UTF-8 multi-line payload (中文 + newlines)",
        "你好世界\n第二行\nThird line\n".as_bytes(),
    );
}

fn s3_large(log: &mut Logger, overlay: &Path) {
    // ~5 KB JSON-ish payload
    let mut buf = String::from("{\n  \"models\": [\n");
    for i in 0..200 {
        buf.push_str(&format!(
            "    {{\"id\":\"m-{:03}\",\"name\":\"Model {:03}\"}},\n",
            i, i
        ));
    }
    buf.push_str("    {\"id\":\"m-end\",\"name\":\"end\"}\n  ]\n}\n");
    stdin_check(log, overlay, "S3", "~5KB JSON payload", buf.as_bytes());
}

fn s4_empty(log: &mut Logger, overlay: &Path) {
    log.scenario("S4", "empty stdin (no INSTALLER_OP_STDIN_B64)");
    let r = invoke_probe_glue(overlay, "echo-stdin", "test", &[], None, &[]);
    log.dump_result(&r);
    let got_bytes = r.merged()
        .lines()
        .find(|l| l.contains("[echo-stdin] bytes:"))
        .and_then(|l| l.split_whitespace().last())
        .and_then(|s| s.parse::<usize>().ok());
    if r.ok() && got_bytes == Some(0) {
        log.pass("S4", "empty stdin handled — 0 bytes received");
    } else {
        log.fail("S4", &format!("expected 0 bytes, got {:?}", got_bytes));
    }
}

// ─────────────────────────────────────────────────────────────────────────
// N. common.sh sourcing (architectural fix).

fn n1_path_after_source(log: &mut Logger, overlay: &Path) {
    log.scenario("N1", "noop.sh sources common.sh → node + openclaw findable");
    let r = invoke_probe_glue(overlay, "noop", "openclaw", &[], None, &[]);
    log.dump_result(&r);
    let merged = r.merged();
    // Look at the "AFTER source" block.
    let after_idx = merged.find("PATH AFTER sourcing");
    let has_node_after = after_idx
        .map(|i| {
            let tail = &merged[i..];
            tail.contains("node       /") || tail.contains("node      /") || tail.contains("/node\n") || tail.contains("/node ")
        })
        .unwrap_or(false);
    let has_openclaw_after = after_idx
        .map(|i| {
            let tail = &merged[i..];
            tail.contains("/openclaw\n") || tail.contains("openclaw   /")
        })
        .unwrap_or(false);
    log.line(&format!(
        "[summary] post-source node-findable={} openclaw-findable={}",
        has_node_after, has_openclaw_after
    ));
    if r.ok() && has_node_after && has_openclaw_after {
        log.pass("N1", "PATH composition works — node + openclaw resolvable");
    } else {
        log.fail("N1", "PATH composition incomplete (see [stdout]/[stderr])");
    }
}

// ─────────────────────────────────────────────────────────────────────────
// X. End-to-end.

fn x1_dry_apply(log: &mut Logger, overlay: &Path) {
    log.scenario(
        "X1",
        "apply-model-config-dry: source common.sh + read stdin + openclaw --version",
    );
    let patch = br#"{"models":{"providers":{"custom":{"models":[{"id":"x1-probe","name":"probe"}]}}}}"#;
    let r = invoke_probe_glue(
        overlay,
        "apply-model-config-dry",
        "openclaw",
        &[],
        Some(&b64(patch)),
        &[],
    );
    log.dump_result(&r);
    let merged = r.merged();
    let openclaw_ok = merged.contains("openclaw --version PASSED");
    if r.ok() && openclaw_ok {
        log.pass(
            "X1",
            "openclaw --version succeeded — production apply-model-config would also work",
        );
    } else if merged.contains("node not on PATH") {
        log.fail("X1", "REPRODUCED THE BUG — node not on PATH inside op script");
    } else {
        log.fail("X1", "dry-apply did not complete (see [stdout]/[stderr])");
    }
}

// ─────────────────────────────────────────────────────────────────────────
// F. fnm self-diagnosis.

fn f1_fnm_state(log: &mut Logger, overlay: &Path) {
    log.scenario(
        "F1",
        "fnm-state.sh — ask fnm directly (current, list, env, exec which node)",
    );
    let r = invoke_probe_glue(overlay, "fnm-state", "test", &[], None, &[]);
    log.dump_result(&r);
    let merged = r.merged();
    let has_fnm_env_output = merged.contains("export PATH=") || merged.contains("export FNM_");
    let fnm_env_says_node = merged
        .lines()
        .any(|l| l.contains("fnm exec --using=default") || l.contains("/installation/bin/node"));
    let installation_exists = merged.contains("✓ installation/bin exists");
    log.line(&format!(
        "[summary] fnm_env_has_output={} fnm_can_locate_node={} installation_bin_exists={}",
        has_fnm_env_output, fnm_env_says_node, installation_exists
    ));
    if r.ok() {
        log.pass(
            "F1",
            "fnm-state ran — interpret manually from sections above to pinpoint the bug",
        );
    } else {
        log.fail("F1", "fnm-state op did not complete");
    }
}

fn f2_fnm_env_direct(log: &mut Logger, overlay: &Path) {
    log.scenario(
        "F2",
        "After eval $(fnm env), is node on PATH? (canonical mechanism)",
    );
    // Embed a focused script via noop's framework — but noop doesn't eval
    // fnm env. Use a custom op script via apply-model-config-dry approach?
    // Simpler: run a one-shot via wsl_via_b64.
    let script = r#"set -u
FNM_DIR_GUESS=""
for d in "$HOME/.local/share/fnm" "$HOME/.fnm"; do
  if [ -d "$d" ]; then FNM_DIR_GUESS="$d"; break; fi
done
echo "FNM_DIR_GUESS=$FNM_DIR_GUESS"
if [ -n "$FNM_DIR_GUESS" ]; then
  export PATH="$FNM_DIR_GUESS:$PATH"
fi
echo "Before eval: command -v node = $(command -v node 2>/dev/null || echo none)"
if command -v fnm >/dev/null 2>&1; then
  echo "fnm found: $(command -v fnm)"
  fnm_output="$(fnm env --shell bash 2>&1)"
  echo "fnm env output (${#fnm_output} bytes):"
  echo "$fnm_output" | sed 's/^/    /'
  eval "$fnm_output" 2>/dev/null || echo "(eval failed)"
  echo "After eval: command -v node = $(command -v node 2>/dev/null || echo none)"
  echo "After eval: command -v openclaw = $(command -v openclaw 2>/dev/null || echo none)"
else
  echo "fnm not on PATH — cannot test fnm env"
fi"#;
    let mut c = wsl_via_b64(script);
    let _ = overlay; // unused
    let r = run_cmd(&mut c);
    log.dump_result(&r);
    let merged = r.merged();
    let node_after_eval = merged
        .lines()
        .find(|l| l.contains("After eval: command -v node ="))
        .map(|l| l.contains("/node") && !l.contains("= none"))
        .unwrap_or(false);
    log.line(&format!(
        "[summary] node_findable_after_fnm_env_eval={}",
        node_after_eval
    ));
    if r.ok() && node_after_eval {
        log.pass(
            "F2",
            "`eval $(fnm env)` adds node to PATH — this is the canonical fix for common.sh",
        );
    } else if r.ok() {
        log.fail(
            "F2",
            "fnm env did NOT make node findable — fnm install may be broken",
        );
    } else {
        log.fail("F2", "could not run fnm env probe");
    }
}

fn f3_verify_fix(log: &mut Logger, overlay: &Path) {
    log.scenario(
        "F3",
        "verify-fnm-fix.sh — apply proposed fix in-memory, check node+openclaw work",
    );
    let r = invoke_probe_glue(overlay, "verify-fnm-fix", "openclaw", &[], None, &[]);
    log.dump_result(&r);
    let merged = r.merged();
    let fix_pass = merged.contains("[verify-fix] PASS");
    let node_works = merged.contains("v24.") || merged.contains("v22.") || merged.contains("v20.");
    let openclaw_works = merged
        .lines()
        .skip_while(|l| !l.contains("openclaw:"))
        .nth(1)
        .map(|l| !l.contains("exec: node: not found") && !l.contains("not found"))
        .unwrap_or(false);
    log.line(&format!(
        "[summary] fix_pass={} node_runs={} openclaw_runs={}",
        fix_pass, node_works, openclaw_works
    ));
    if r.ok() && fix_pass {
        log.pass(
            "F3",
            "FIX VERIFIED — apply same diff to prod common.sh and the bug is gone",
        );
    } else {
        log.fail("F3", "fix did not produce a working node+openclaw — needs another pass");
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Q. PATH pollution resilience.

fn q1_pollution(log: &mut Logger, overlay: &Path) {
    log.scenario(
        "Q1",
        "Polluted PATH: does common.sh's prepend win over fake /tmp/fake-bin/?",
    );
    let r = invoke_probe_glue(overlay, "pollution", "test", &[], None, &[]);
    log.dump_result(&r);
    let merged = r.merged();
    let pass_marker = merged.contains("PASS: common.sh's prepend won");
    let leak_count = merged.lines().filter(|l| l.contains("← LEAK!")).count();
    log.line(&format!(
        "[summary] leaks_detected={} pass_marker_present={}",
        leak_count, pass_marker
    ));
    if r.ok() && pass_marker && leak_count == 0 {
        log.pass(
            "Q1",
            "common.sh successfully overrides polluted PATH for the binaries it manages",
        );
    } else {
        log.fail(
            "Q1",
            &format!("pollution resilience broken (leaks={})", leak_count),
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────
// main.

fn ts() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{}", secs)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let exe = env::current_exe()?;
    let exe_dir = exe.parent().unwrap().to_path_buf();
    let overlay = exe_dir.join("shell-overlay");
    let log_path = exe_dir.join(format!("claw-op-probe-{}.log", ts()));

    let mut log = Logger::new(&log_path)?;
    log.line("════════════════════════════════════════════════════════════════");
    log.line(" claw-op-probe — op-dispatch architecture verification");
    log.line("════════════════════════════════════════════════════════════════");
    log.line(&format!("exe:     {}", exe.display()));
    log.line(&format!("overlay: {}", overlay.display()));
    log.line(&format!("log:     {}", log_path.display()));

    if !overlay.exists() {
        log.fail(
            "BOOTSTRAP",
            &format!(
                "shell-overlay/ not found at {}. Ship the .exe + the overlay directory together.",
                overlay.display()
            ),
        );
        return Ok(());
    }

    log.section("E. ENVIRONMENT");
    e1_powershell_version(&mut log);
    e2_wsl_version(&mut log);
    e3_wsl_distros(&mut log);
    e4_wsl_identity(&mut log);
    e5_path_baseline(&mut log);
    e6_command_baseline(&mut log);
    e7_common_sh_exists(&mut log);
    e8_path_after_source(&mut log);

    log.section("P. POWERSHELL PARSE");
    p1_parse_probe(&mut log, &overlay);
    p2_parse_prod(&mut log);

    log.section("G. GLUE LAYER");
    g1_dryrun(&mut log, &overlay);
    g2_noop_live(&mut log, &overlay);
    g3_unknown_op(&mut log, &overlay);
    g4_unknown_agent(&mut log, &overlay);

    log.section("S. STDIN TRANSPORT");
    s1_ascii(&mut log, &overlay);
    s2_utf8(&mut log, &overlay);
    s3_large(&mut log, &overlay);
    s4_empty(&mut log, &overlay);

    log.section("N. COMMON.SH SOURCING");
    n1_path_after_source(&mut log, &overlay);

    log.section("F. FNM SELF-DIAGNOSIS");
    f1_fnm_state(&mut log, &overlay);
    f2_fnm_env_direct(&mut log, &overlay);
    f3_verify_fix(&mut log, &overlay);

    log.section("Q. PATH POLLUTION RESILIENCE");
    q1_pollution(&mut log, &overlay);

    log.section("X. END-TO-END");
    x1_dry_apply(&mut log, &overlay);

    log.section("SUMMARY");
    log.line(&format!(
        "pass={} fail={} skip={}",
        log.pass, log.fail, log.skip
    ));
    log.line(&format!("Log saved to: {}", log_path.display()));
    log.line("");
    log.line("Please paste the ENTIRE log file back to the conversation.");
    Ok(())
}
