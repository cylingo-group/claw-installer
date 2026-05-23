//! wsl-rust-probe — verify the bash-via-wsl.exe path used by claw-installer's
//! commands.rs::run_in_wsl_with_stdin BEFORE we change the real code.
//!
//! Mirrors exactly how the GUI app spawns wsl.exe:
//!   - std::process::Command::new("wsl.exe")
//!   - env WSL_UTF8=1
//!   - CREATE_NO_WINDOW flag
//!   - args ["--", "bash", "-lc", <script>]
//!   - stdin pipe → bash inside WSL
//!
//! Does NOT depend on openclaw / hermes — uses cat / wc / ls / echo only.
//!
//! Build (from macOS, cross-compile to Windows):
//!   cd tools/wsl-rust-probe
//!   cargo xwin build --release --target x86_64-pc-windows-msvc
//!
//! Resulting .exe at:
//!   target/x86_64-pc-windows-msvc/release/wsl-rust-probe.exe
//!
//! Copy to Windows host, double-click or run in cmd/PowerShell. Output to
//! stdout. Paste back to the conversation.

use std::io::Write;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

fn main() {
    println!("════════════════════════════════════════════════════════════");
    println!(" wsl-rust-probe — Rust → wsl.exe → bash transport tests");
    println!("════════════════════════════════════════════════════════════");
    println!("Tests the exact code path commands.rs uses for");
    println!("apply_openclaw_model_config / apply_hermes_model_config.");
    println!();

    print_wsl_version();

    // Tests run in order of increasing complexity. If A passes, that's the
    // simplest fix path for the real code. B is the control (current code).
    // C is the fallback if A doesn't pan out.
    test_a_single_line();
    test_b_multi_line();
    test_c_file_based();

    println!("════════════════════════════════════════════════════════════");
    println!(" done — please paste this entire output back");
    println!("════════════════════════════════════════════════════════════");
}

// ─────────────────────────────────────────────────────────────────────────
fn print_wsl_version() {
    println!("─── wsl.exe --version ───");
    let mut cmd = Command::new("wsl.exe");
    cmd.arg("--version").env("WSL_UTF8", "1");
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);
    match cmd.output() {
        Ok(o) => {
            print!("{}", String::from_utf8_lossy(&o.stdout));
            if !o.stderr.is_empty() {
                eprintln!("(stderr) {}", String::from_utf8_lossy(&o.stderr));
            }
        }
        Err(e) => eprintln!("failed to run wsl.exe --version: {}", e),
    }
    println!();
}

// ─────────────────────────────────────────────────────────────────────────
// TEST A — single-line script with `;` separators. Our proposed fix.
// ─────────────────────────────────────────────────────────────────────────
fn test_a_single_line() {
    println!("─── TEST A: SINGLE-LINE script (`;` separators) ───");
    let tmp = format!("/tmp/probeA-{}-{}.json", pid(), nanos());

    // The script is one logical line — no \n anywhere. Even if some layer
    // (wsl.exe, bash startup) had CRLF / line-ending bugs, there's nothing
    // here for them to corrupt.
    let script = format!(
        r#"set -e; tmp={tmp}; trap 'rm -f "$tmp"' EXIT; umask 077; cat > "$tmp"; echo "bytes:$(wc -c < "$tmp")"; ls -l "$tmp"; echo content:; cat "$tmp""#,
        tmp = tmp
    );
    show("script (literal, as bash will see it)", &script);

    let payload = br#"{"hello":"from-rust","method":"A"}"#;
    let (code, stdout, stderr) = run_wsl(&script, Some(payload));
    report(code, &stdout, &stderr);

    if code == 0 && stdout.contains(r#"{"hello":"from-rust","method":"A"}"#) {
        println!("✓ TEST A PASSED — single-line method works");
    } else {
        println!("✗ TEST A FAILED");
    }
    println!();
}

// ─────────────────────────────────────────────────────────────────────────
// TEST B — multi-line script (LF only). Current code shape.
// ─────────────────────────────────────────────────────────────────────────
fn test_b_multi_line() {
    println!("─── TEST B: MULTI-LINE script (LF only, control) ───");
    let tmp = format!("/tmp/probeB-{}-{}.json", pid(), nanos());

    // Same logic, but newlines between statements. This is exactly the shape
    // commands.rs currently emits. If B fails but A passes, the bug IS in
    // multi-line transport.
    let script = format!(
        "set -e\n\
         tmp={tmp}\n\
         trap 'rm -f \"$tmp\"' EXIT\n\
         umask 077\n\
         cat > \"$tmp\"\n\
         echo \"bytes:$(wc -c < \"$tmp\")\"\n\
         ls -l \"$tmp\"\n\
         echo content:\n\
         cat \"$tmp\"\n",
        tmp = tmp
    );
    show("script (literal)", &script);

    let payload = br#"{"hello":"from-rust","method":"B"}"#;
    let (code, stdout, stderr) = run_wsl(&script, Some(payload));
    report(code, &stdout, &stderr);

    if code == 0 && stdout.contains(r#"{"hello":"from-rust","method":"B"}"#) {
        println!("✓ TEST B PASSED — multi-line method works (current code shape)");
    } else {
        println!("✗ TEST B FAILED — multi-line breaks somewhere in transport");
    }
    println!();
}

// ─────────────────────────────────────────────────────────────────────────
// TEST C — file-based two-step. Most robust fallback.
//   Step 1: pipe script body via stdin to a /tmp/.sh file inside WSL
//   Step 2: bash -l that file, with the JSON payload on stdin
// ─────────────────────────────────────────────────────────────────────────
fn test_c_file_based() {
    println!("─── TEST C: FILE-BASED two-step ───");
    let script_path = format!("/tmp/probeC-{}-{}.sh", pid(), nanos());
    let data_tmp = format!("/tmp/probeC-data-{}-{}.json", pid(), nanos());

    let script_body = format!(
        "set -e\n\
         tmp={tmp}\n\
         trap 'rm -f \"$tmp\"' EXIT\n\
         umask 077\n\
         cat > \"$tmp\"\n\
         echo \"bytes:$(wc -c < \"$tmp\")\"\n\
         ls -l \"$tmp\"\n\
         echo content:\n\
         cat \"$tmp\"\n",
        tmp = data_tmp
    );

    // Step 1: short single-line command that just receives the script body
    // on stdin and writes it to a file. Even if multi-line script-as-arg is
    // broken, this step uses ONLY a single-line bash command, with the
    // multi-line content riding on stdin (which is reliable).
    let step1 = format!(
        "cat > {sp} && chmod 755 {sp} && echo wrote:{sp}",
        sp = script_path
    );
    println!("[step 1] script-arg to bash -lc:");
    show("step 1 cmd", &step1);
    let (c1, o1, e1) = run_wsl(&step1, Some(script_body.as_bytes()));
    report(c1, &o1, &e1);

    if c1 != 0 {
        println!("✗ TEST C step 1 failed — skipping step 2");
        println!();
        return;
    }

    // Step 2: simple single-line invocation of bash on the file we wrote.
    // The actual multi-line logic lives in the file now, where bash reads
    // it from disk (which is always reliable).
    let step2 = format!("bash -l {}", script_path);
    println!("[step 2] script-arg to bash -lc:");
    show("step 2 cmd", &step2);
    let payload = br#"{"hello":"from-rust","method":"C"}"#;
    let (c2, o2, e2) = run_wsl(&step2, Some(payload));
    report(c2, &o2, &e2);

    // Best-effort cleanup of the script file (not critical).
    let _ = run_wsl(&format!("rm -f {}", script_path), None);

    if c2 == 0 && o2.contains(r#"{"hello":"from-rust","method":"C"}"#) {
        println!("✓ TEST C PASSED — file-based two-step works");
    } else {
        println!("✗ TEST C FAILED");
    }
    println!();
}

// ─────────────────────────────────────────────────────────────────────────
// Shared invocation helper. Identical shape to commands.rs::run_in_wsl_with_stdin.
// ─────────────────────────────────────────────────────────────────────────
fn run_wsl(script: &str, stdin_bytes: Option<&[u8]>) -> (i32, String, String) {
    let distro = std::env::var("INSTALLER_WSL_DISTRO").ok();
    let mut cmd = Command::new("wsl.exe");
    if let Some(ref d) = distro {
        cmd.args(["-d", d.as_str()]);
    }
    cmd.args(["--", "bash", "-lc", script])
        .env("WSL_UTF8", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return (-1, String::new(), format!("spawn wsl.exe failed: {}", e)),
    };

    if let Some(bytes) = stdin_bytes {
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(bytes);
            // stdin dropped here → pipe closes → bash sees EOF on `cat`
        }
    }

    let output = match child.wait_with_output() {
        Ok(o) => o,
        Err(e) => return (-2, String::new(), format!("wait_with_output failed: {}", e)),
    };

    let code = output.status.code().unwrap_or(-3);
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    (code, stdout, stderr)
}

fn show(label: &str, content: &str) {
    println!("[{}]", label);
    for line in content.split('\n') {
        println!("  | {}", line);
    }
    println!();
}

fn report(code: i32, stdout: &str, stderr: &str) {
    println!("[exit] {}", code);
    if !stdout.is_empty() {
        println!("[stdout]");
        for line in stdout.lines() {
            println!("  > {}", line);
        }
    }
    if !stderr.is_empty() {
        println!("[stderr]");
        for line in stderr.lines() {
            println!("  ! {}", line);
        }
    }
}

fn pid() -> u32 {
    std::process::id()
}
fn nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}
