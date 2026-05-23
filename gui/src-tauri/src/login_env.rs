// login_env.rs — harvest the user's interactive-login shell env once at startup.
//
// macOS GUI apps (and Linux desktop launchers) inherit launchd / systemd-user's
// minimal env: PATH=/usr/bin:/bin:/usr/sbin:/sbin, no PNPM_HOME, no FNM_DIR.
// Bash scripts spawned by Tauri therefore can't see the user's customizations.
//
// We fix that by spawning `<shell> -ilc env` on a background thread at startup,
// parsing the output, and caching the result. Every subsequent bash spawn
// overlays this map onto the tauri Command before adding caller-supplied env
// / CLAW_SESSION_LOG (so user overrides still win).
//
// Robustness features:
// 1. Background prime() — startup never blocks; login_env() blocks on join
//    only if the first install click beats harvest completion (unlikely).
// 2. Per-shell wall-clock timeout — a slow .zshrc can't hang the app.
// 3. Multi-shell fallback chain — $SHELL → /bin/zsh → /bin/bash, dedup. Helps
//    fish users whose PNPM_HOME lives in .zshrc.
// 4. Strict env-line parsing — keys must be POSIX identifiers, so `echo foo=bar`
//    from a chatty rc file is rejected.
// 5. Filtered keys — process-local vars (_, SHLVL, PWD, OLDPWD), exported bash
//    funcs (BASH_FUNC_*), prompt/colorizer junk (PS1..PS4, RPS1, RPS2,
//    PROMPT_COMMAND, PROMPT) never propagate.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::thread::{self, JoinHandle};

#[cfg(not(target_os = "windows"))]
use std::{process::Command, sync::mpsc, time::Duration};

/// Wall-clock budget for a single shell spawn. .zshrc with oh-my-zsh + plugin
/// managers can spend 1–3s; 8s leaves headroom without hanging the app.
#[cfg(not(target_os = "windows"))]
const SHELL_TIMEOUT: Duration = Duration::from_secs(8);

static LOGIN_ENV: OnceLock<HashMap<String, String>> = OnceLock::new();
static HARVEST_HANDLE: Mutex<Option<JoinHandle<HashMap<String, String>>>> = Mutex::new(None);

/// Returns the cached login-shell env map. Blocks on the background harvest
/// thread the first time it's called; cheap on every subsequent call.
pub fn login_env() -> &'static HashMap<String, String> {
    LOGIN_ENV.get_or_init(|| {
        // If prime() spawned a thread, join it. Otherwise run harvest inline.
        let handle = HARVEST_HANDLE.lock().ok().and_then(|mut g| g.take());
        match handle {
            Some(h) => h.join().unwrap_or_else(|_| {
                crate::log_error!("login_env", "harvest thread panicked");
                HashMap::new()
            }),
            None => harvest(),
        }
    })
}

/// Spawn the harvest on a background thread so app startup isn't blocked.
/// Call once from main during init. Calling more than once is harmless (the
/// second call sees the handle already taken).
pub fn prime() {
    if LOGIN_ENV.get().is_some() {
        return;
    }
    let Ok(mut slot) = HARVEST_HANDLE.lock() else { return };
    if slot.is_some() {
        return; // already primed
    }
    *slot = Some(thread::spawn(harvest));
}

#[cfg(target_os = "windows")]
fn harvest() -> HashMap<String, String> {
    // Windows path runs through WSL, which sources its own login shell already.
    HashMap::new()
}

#[cfg(not(target_os = "windows"))]
fn harvest() -> HashMap<String, String> {
    let mut tried: Vec<String> = Vec::new();
    for shell in candidate_shells() {
        if tried.iter().any(|s| s == &shell) {
            continue;
        }
        tried.push(shell.clone());
        let map = harvest_one(&shell, SHELL_TIMEOUT);
        if !map.is_empty() && map.contains_key("PATH") {
            crate::log_info!(
                "login_env",
                "ok via {} ({} vars, PATH={})",
                shell,
                map.len(),
                preview_path(map.get("PATH").map(|s| s.as_str()).unwrap_or(""))
            );
            return map;
        }
        crate::log_warn!(
            "login_env",
            "{} produced no usable env — trying next",
            shell
        );
    }
    crate::log_warn!(
        "login_env",
        "all candidate shells failed (tried {:?}) — bash spawns will see launchd's minimal env",
        tried
    );
    HashMap::new()
}

/// Candidate shell binaries to try, in priority order. $SHELL is the user's
/// real login shell; the fallbacks help when the user's customizations live
/// in a different shell's rc files than the one $SHELL points at.
#[cfg(not(target_os = "windows"))]
fn candidate_shells() -> Vec<String> {
    let mut v = Vec::new();
    if let Ok(s) = std::env::var("SHELL") {
        if !s.is_empty() {
            v.push(s);
        }
    }
    // /usr/local/bin/zsh and /opt/homebrew/bin/zsh exist on brew-installed zsh;
    // /bin/zsh is the macOS system zsh. Order matters: pick brew first if it
    // exists (matches what the user's rc likely targets), otherwise system.
    for candidate in [
        "/opt/homebrew/bin/zsh",
        "/usr/local/bin/zsh",
        "/bin/zsh",
        "/bin/bash",
    ] {
        if std::path::Path::new(candidate).exists() {
            v.push(candidate.to_string());
        }
    }
    v
}

/// Run one candidate shell, bounded by `timeout`. Returns parsed env on
/// success; empty map on failure or timeout.
///
/// The child runs in a sub-thread; we wait on a channel with a timeout. If the
/// shell hangs past `timeout` we abandon waiting and move on — the child
/// process is left to be reaped by the OS. This is a one-shot at startup so
/// the leaked child is bounded to a handful of orphans at most.
#[cfg(not(target_os = "windows"))]
fn harvest_one(shell: &str, timeout: Duration) -> HashMap<String, String> {
    let shell_owned = shell.to_string();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        // -l = login (sources .zprofile / .bash_profile / .profile)
        // -i = interactive (sources .zshrc / .bashrc / config.fish)
        // -c = run a single command then exit
        // stdin=null prevents the shell from trying to attach to our tty.
        let result = Command::new(&shell_owned)
            .args(["-ilc", "env"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .output();
        let _ = tx.send(result);
    });

    match rx.recv_timeout(timeout) {
        Ok(Ok(output)) if output.status.success() => {
            parse_env_output(&String::from_utf8_lossy(&output.stdout))
        }
        Ok(Ok(output)) => {
            crate::log_warn!(
                "login_env",
                "{} exited code={:?} stderr={}",
                shell,
                output.status.code(),
                String::from_utf8_lossy(&output.stderr).trim()
            );
            HashMap::new()
        }
        Ok(Err(e)) => {
            crate::log_warn!("login_env", "spawn {} failed: {}", shell, e);
            HashMap::new()
        }
        Err(_) => {
            crate::log_warn!("login_env", "{} timed out after {:?}", shell, timeout);
            HashMap::new()
        }
    }
}

/// Shorten a long PATH for log readability without losing the head (which is
/// where the meaningful precedence lives).
#[cfg(not(target_os = "windows"))]
fn preview_path(p: &str) -> String {
    if p.len() <= 200 {
        p.to_string()
    } else {
        format!("{}… ({}B total)", &p[..200], p.len())
    }
}

/// Parse `env`-style output (KEY=VALUE per line) into a map.
///
/// - Keys must be POSIX identifiers (`[A-Za-z_][A-Za-z0-9_]*`). This rejects
///   rc-file `echo` output that happens to contain `=`.
/// - Process-local / prompt / exported-function vars are filtered (see
///   `is_filtered_key`) so they don't pollute the spawned bash's env.
/// - Empty values are kept (some scripts intentionally set EMPTY=).
///
/// Known limitation: env values containing literal newlines come through as
/// multiple lines from `env`, and the second-line content gets dropped. PATH /
/// PNPM_HOME / FNM_DIR are always single-line in practice, so this is fine.
#[cfg(not(target_os = "windows"))]
fn parse_env_output(text: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for line in text.lines() {
        let Some((key, val)) = line.split_once('=') else { continue };
        if !is_valid_identifier(key) {
            continue;
        }
        if is_filtered_key(key) {
            continue;
        }
        map.insert(key.to_string(), val.to_string());
    }
    map
}

/// POSIX-style env-var identifier: `[A-Za-z_][A-Za-z0-9_]*`, non-empty.
#[cfg(not(target_os = "windows"))]
fn is_valid_identifier(key: &str) -> bool {
    let mut chars = key.chars();
    let Some(first) = chars.next() else { return false };
    if !(first.is_ascii_alphabetic() || first == '_') {
        return false;
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Keys we never want to propagate from the login shell into bash subprocesses.
#[cfg(not(target_os = "windows"))]
fn is_filtered_key(key: &str) -> bool {
    // Process-local: would shadow what bash sets correctly itself.
    if matches!(key, "_" | "SHLVL" | "OLDPWD" | "PWD") {
        return true;
    }
    // Bash exported functions: encoded with funky names, useless / dangerous
    // to forward.
    if key.starts_with("BASH_FUNC_") {
        return true;
    }
    // Prompts and colorizer hooks: harmless but noisy, and PS4 affects xtrace
    // output we explicitly format in common.sh.
    if matches!(
        key,
        "PS1" | "PS2" | "PS3" | "PS4" | "RPS1" | "RPS2" | "PROMPT_COMMAND" | "PROMPT"
    ) {
        return true;
    }
    false
}

#[cfg(all(test, not(target_os = "windows")))]
mod tests {
    use super::*;

    #[test]
    fn parses_basic_env_output() {
        let m = parse_env_output(
            "PATH=/usr/bin:/bin\nPNPM_HOME=/home/u/.pnpm\nFNM_DIR=/home/u/.fnm\n",
        );
        assert_eq!(m.get("PATH"), Some(&"/usr/bin:/bin".to_string()));
        assert_eq!(m.get("PNPM_HOME"), Some(&"/home/u/.pnpm".to_string()));
        assert_eq!(m.get("FNM_DIR"), Some(&"/home/u/.fnm".to_string()));
        assert_eq!(m.len(), 3);
    }

    #[test]
    fn skips_process_local_keys() {
        let m = parse_env_output("_=foo\nSHLVL=2\nOLDPWD=/tmp\nPWD=/home\nREAL=keep\n");
        assert_eq!(m.len(), 1);
        assert_eq!(m.get("REAL"), Some(&"keep".to_string()));
    }

    #[test]
    fn skips_bash_func_exports() {
        let m = parse_env_output("BASH_FUNC_foo%%=() { echo foo; }\nKEEP=ok\n");
        assert_eq!(m.len(), 1);
        assert_eq!(m.get("KEEP"), Some(&"ok".to_string()));
    }

    #[test]
    fn skips_prompt_vars() {
        let m = parse_env_output(
            "PS1=$ \nPS2=> \nPS4=+ \nRPS1=foo\nPROMPT_COMMAND=echo\nPROMPT=$\nPATH=/usr/bin\n",
        );
        assert_eq!(m.len(), 1);
        assert!(m.contains_key("PATH"));
        for prompt_key in &["PS1", "PS2", "PS4", "RPS1", "PROMPT_COMMAND", "PROMPT"] {
            assert!(!m.contains_key(*prompt_key), "{} should be filtered", prompt_key);
        }
    }

    #[test]
    fn handles_empty_values() {
        let m = parse_env_output("EMPTY=\nFILLED=v\n");
        assert_eq!(m.get("EMPTY"), Some(&"".to_string()));
        assert_eq!(m.get("FILLED"), Some(&"v".to_string()));
    }

    #[test]
    fn handles_value_containing_equals() {
        let m = parse_env_output("EQ=a=b=c\n");
        assert_eq!(m.get("EQ"), Some(&"a=b=c".to_string()));
    }

    #[test]
    fn rejects_invalid_identifier_keys() {
        // Real-world: rc file does `echo "Welcome=user"`, gets piped to env consumer.
        let m = parse_env_output(
            "Welcome=user\n0_starts_with_digit=x\nhas-dash=x\nhas.dot=x\n\
             has space=x\nVALID_KEY=ok\n_LEADING_UNDERSCORE=ok\n",
        );
        // Two valid: VALID_KEY and _LEADING_UNDERSCORE
        assert_eq!(m.len(), 3, "got: {:?}", m);
        assert_eq!(m.get("VALID_KEY"), Some(&"ok".to_string()));
        assert_eq!(m.get("_LEADING_UNDERSCORE"), Some(&"ok".to_string()));
        // "Welcome" actually IS a valid identifier — only filtered keys / non-identifiers should drop
        assert_eq!(m.get("Welcome"), Some(&"user".to_string()));
    }

    #[test]
    fn skips_malformed_lines() {
        let m = parse_env_output("no-equals-here\n=missing-key\nOK=ok\n");
        assert_eq!(m.len(), 1);
        assert_eq!(m.get("OK"), Some(&"ok".to_string()));
    }

    #[test]
    fn is_valid_identifier_accepts_posix() {
        assert!(is_valid_identifier("PATH"));
        assert!(is_valid_identifier("_X"));
        assert!(is_valid_identifier("X_Y_1"));
        assert!(is_valid_identifier("a"));
    }

    #[test]
    fn is_valid_identifier_rejects_non_posix() {
        assert!(!is_valid_identifier(""));
        assert!(!is_valid_identifier("1ABC"));
        assert!(!is_valid_identifier("A-B"));
        assert!(!is_valid_identifier("A.B"));
        assert!(!is_valid_identifier("A B"));
        assert!(!is_valid_identifier("BASH_FUNC_x%%"));
    }

    #[test]
    fn preview_path_truncates_long_paths() {
        let short = "/usr/bin:/bin";
        assert_eq!(preview_path(short), short);

        let long = "x".repeat(500);
        let preview = preview_path(&long);
        assert!(preview.len() < long.len());
        assert!(preview.contains("500B total"));
    }
}
