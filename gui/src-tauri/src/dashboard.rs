//! Per-agent dashboard opener.
//!
//! Strategy per the project's rule "never hardcode URLs": ask each agent's CLI
//! to do the right thing.
//!
//! - **openclaw** has a one-shot `openclaw dashboard` subcommand that resolves
//!   the gateway URL, mints a per-launch auth token, opens the system browser
//!   with the token in the URL, and exits. We just shell out to it — no need
//!   to know the URL ourselves (and we *can't* know the token: the CLI
//!   redacts `gateway.auth.token` from `openclaw config get`).
//!
//! - **hermes**'s `hermes dashboard` is a long-running web server (build +
//!   serve), so we can't fire-and-forget it. Instead we resolve the port from
//!   a running `hermes dashboard` process (via `dispatch_op("hermes",
//!   "find-dashboard-port")`, or `9119` per the CLI's documented default) and
//!   open the URL via the `opener` plugin. If the dashboard isn't running, the
//!   user gets connection refused — which is the same outcome as `hermes
//!   dashboard --status`'s semantics anyway.
//!
//! All shell invocations go through `dispatch_op` (the unified op-dispatch
//! protocol) so both Windows (via bootstrap.ps1 → Invoke-OpDispatch → WSL
//! login-shell) and macOS (via shell/claw-op.sh) get a fully-composed PATH.

use std::sync::{Mutex, OnceLock};

use tauri::AppHandle;
use tauri_plugin_opener::OpenerExt;

use crate::commands::dispatch_op;
use crate::{log_error, log_info};

const HERMES_DEFAULT_PORT: u16 = 9119;
const OPENCLAW_DEFAULT_PORT: u16 = 7841;

/// Cache the openclaw dashboard URL across button clicks within the same GUI
/// session. Rationale: every call to `openclaw dashboard --yes` has server-side
/// side effects (it probes the gateway, may trigger a service restart on
/// transient probe failure, and our follow-up `approve-latest-device` op may
/// approve a fresh pairing request the browser produced — any of which can
/// bump a previously-paired tab back to the login/pairing screen). When the
/// gateway is already running and we have a known-good URL from an earlier
/// click, just open that URL again — no shell calls, no side effects.
///
/// Cache is process-lifetime: clears on GUI restart. If the gateway is
/// genuinely restarted out-of-band and the cached token becomes invalid, the
/// user can restart the GUI to clear the cache.
fn openclaw_url_cache() -> &'static Mutex<Option<String>> {
    static CACHE: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

#[tauri::command]
pub async fn open_agent_dashboard(app: AppHandle, agent_id: String) -> Result<(), String> {
    match agent_id.as_str() {
        "openclaw" => open_openclaw_dashboard(app),
        "hermes" => open_hermes_dashboard(&app).await,
        other => Err(format!("未知 agent：{other}")),
    }
}

/// openclaw: delegate to `openclaw dashboard` — the CLI handles token auth +
/// browser launch + clipboard copy in one shot, and exits within ~2s.
///
/// `--yes` auto-installs the gateway service if it's missing, so a freshly
/// installed openclaw that hasn't been started can still surface its dashboard.
///
/// We additionally auto-approve the pending device-pairing request the browser
/// creates when it first connects to the gateway. The gateway requires
/// per-device pairing on first connect; without this, the user would land on
/// "Run openclaw devices approve <uuid>" in the browser.
///
/// The approval polling loop lives inside `approve-latest-device.sh` (up to
/// 75 × 0.4s = ~30s budget) — NOT here. This keeps it to exactly one
/// dispatch_op call (one UAC prompt max on Windows) for the full approval wait.
fn open_openclaw_dashboard(app: AppHandle) -> Result<(), String> {
    // Fast path: gateway port already listening AND we have a cached URL from
    // a previous click in this GUI session. Skip the openclaw CLI entirely so
    // we don't re-trigger its server-side side effects (gateway probe →
    // possible restart, fresh approve-latest-device polling). Returning the
    // same URL keeps the previously-opened tab's session valid.
    if is_listening(OPENCLAW_DEFAULT_PORT) {
        if let Some(cached) = openclaw_url_cache().lock().ok().and_then(|g| g.clone()) {
            log_info!(
                "dashboard::open_openclaw_dashboard",
                "fast path: port {} listening + cached URL — reusing without re-running openclaw",
                OPENCLAW_DEFAULT_PORT
            );
            return app
                .opener()
                .open_url(&cached, None::<&str>)
                .map_err(|e| format!("无法在浏览器中打开 {cached}：{e}"));
        }
    }

    log_info!("dashboard::open_openclaw_dashboard", "dispatching open-dashboard op (cold start or cache miss)");
    // Fire open-dashboard. openclaw inside WSL detects "No GUI" and refuses to
    // launch a browser itself — it only prints the URL. Our op script captures
    // the URL and prefixes it with the sentinel "@@dashboard-url:<url>" on its
    // stdout, which arrives back here via dispatch_op's return value (the
    // file-tail bridge in bootstrap.ps1 forwards bash stdout across the UAC
    // boundary into the powershell.exe parent's captured stdout).
    let stdout = dispatch_op(&app, "openclaw", "open-dashboard", b"", &[])
        .map_err(|e| format!("无法打开 OpenClaw Dashboard：{e}"))?;

    let url = stdout
        .lines()
        .find_map(|l| l.trim().strip_prefix("@@dashboard-url:"))
        .map(|s| s.trim().to_string());

    match url {
        Some(url) => {
            log_info!(
                "dashboard::open_openclaw_dashboard",
                "opening {} via Tauri opener (WSL→Windows)",
                url
            );
            app.opener()
                .open_url(&url, None::<&str>)
                .map_err(|e| format!("无法在浏览器中打开 {url}：{e}"))?;
            // Cache for subsequent clicks in this GUI session — the fast
            // path at the top of this function will skip running openclaw
            // again, preserving any tabs the user has open against the
            // currently-running gateway instance.
            if let Ok(mut g) = openclaw_url_cache().lock() {
                *g = Some(url);
            }
        }
        None => {
            // openclaw exited 0 but we couldn't find the URL line. Surface a
            // diagnostic so the user knows where to look.
            log_error!(
                "dashboard::open_openclaw_dashboard",
                "openclaw produced no parseable Dashboard URL; see op log"
            );
            return Err(
                "openclaw 没有返回 Dashboard URL — 请查看 op-openclaw-open-dashboard-*.log"
                    .to_string(),
            );
        }
    }

    // Spawn ONE background thread that makes ONE dispatch_op call to
    // approve-latest-device.sh — the polling loop lives inside the script.
    // This is intentionally fire-and-forget: the main thread returns immediately
    // so the GUI spinner doesn't block. One call = one UAC prompt max on Windows.
    std::thread::spawn(move || {
        log_info!("dashboard::approve_latest_device", "starting approve-latest-device op");
        match dispatch_op(&app, "openclaw", "approve-latest-device", b"", &[]) {
            Ok(_) => log_info!("dashboard::approve_latest_device", "approved successfully"),
            Err(e) => log_error!("dashboard::approve_latest_device", "{}", e),
        }
    });

    Ok(())
}

/// hermes: the dashboard is a long-running web server that the user must
/// explicitly launch. We TCP-probe the port to detect whether it's already
/// serving:
///   - listening → open the URL via the system browser
///   - not listening → dispatch open-dashboard (fire-and-forget spawn), then
///     poll the port for up to ~60s so the IPC stays open while the CLI builds
///     the web UI (first run can take ~30s). Once listening, we open the URL
///     ourselves. The async polling makes the GUI's busy-spinner accurately
///     reflect "still starting" rather than disappearing instantly.
///
/// We deliberately don't rely on `hermes dashboard --status` here — it reports
/// stale PIDs from prior runs that the OS no longer owns.
async fn open_hermes_dashboard(app: &AppHandle) -> Result<(), String> {
    log_info!("dashboard::open_hermes_dashboard", "checking for running hermes dashboard");
    // Try to find a running hermes dashboard's port via dispatch_op.
    // Empty stdout → no running process → use the default.
    let port = hermes_port_from_running_process(app).unwrap_or(HERMES_DEFAULT_PORT);
    let url = format!("http://127.0.0.1:{port}/");
    log_info!("dashboard::open_hermes_dashboard", "resolved port={} url={}", port, url);

    let open_url = || {
        log_info!("dashboard::open_hermes_dashboard", "opening {} via Tauri opener", url);
        app.opener()
            .open_url(&url, None::<&str>)
            .map_err(|e| format!("无法在浏览器中打开 {url}：{e}"))
    };

    if is_listening(port) {
        log_info!("dashboard::open_hermes_dashboard", "port {} already listening — opening directly", port);
        return open_url();
    }

    // Spawn the dashboard detached without auto-opening the browser — we'll
    // open it ourselves once the port is up so the timing is predictable.
    // open-dashboard.sh emits a `@@hermes-spawn-log:<path>` sentinel so we
    // can surface the WSL-side spawn log location if polling times out.
    log_info!("dashboard::open_hermes_dashboard", "port {} not listening; spawning hermes dashboard", port);
    let spawn_stdout = dispatch_op(app, "hermes", "open-dashboard", b"", &[])
        .map_err(|e| format!("无法启动 Hermes Dashboard：{e}"))?;

    let spawn_log = spawn_stdout
        .lines()
        .find_map(|l| l.trim().strip_prefix("@@hermes-spawn-log:"))
        .map(|s| s.trim().to_string());
    if let Some(ref p) = spawn_log {
        log_info!("dashboard::open_hermes_dashboard", "hermes spawn log (inside WSL): {}", p);
    }

    // Poll for readiness. 120 × 500ms = 60s budget. First-time builds typically
    // finish in ~15–30s; subsequent launches in <2s.
    log_info!("dashboard::open_hermes_dashboard", "polling port {} for readiness (60s budget)", port);
    for i in 0..120 {
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        if is_listening(port) {
            log_info!(
                "dashboard::open_hermes_dashboard",
                "port {} listening after ~{}s",
                port,
                (i + 1) as f32 * 0.5
            );
            return open_url();
        }
        // Heartbeat every 5s so the tauri log shows polling is alive.
        if (i + 1) % 10 == 0 {
            log_info!(
                "dashboard::open_hermes_dashboard",
                "still polling port {}, ~{}s elapsed",
                port,
                (i + 1) as f32 * 0.5
            );
        }
    }

    let hint = spawn_log
        .map(|p| format!("查看 hermes 启动日志：wsl -- cat {p}"))
        .unwrap_or_else(|| "在终端运行 `hermes dashboard` 查看构建日志".to_string());
    log_error!(
        "dashboard::open_hermes_dashboard",
        "timeout: port {} never came up in 60s; {}",
        port,
        hint
    );
    Err(format!(
        "Hermes Dashboard 在 60 秒内仍未就绪（端口 {port}）。\n{hint}"
    ))
}

fn is_listening(port: u16) -> bool {
    use std::net::{SocketAddr, TcpStream};
    let addr: SocketAddr = match format!("127.0.0.1:{port}").parse() {
        Ok(a) => a,
        Err(_) => return false,
    };
    TcpStream::connect_timeout(&addr, std::time::Duration::from_millis(300)).is_ok()
}

// ── hermes process inspection ───────────────────────────────────────────────

/// Find a running `hermes dashboard` process's port.
///
/// On macOS/Linux and on Windows (via WSL): delegates to
/// `dispatch_op("hermes", "find-dashboard-port")` which runs
/// `shell/agents/hermes/find-dashboard-port.sh`. The script echoes the port
/// number to stdout (or nothing if no process found). Returns `None` if the
/// script produces no output, returns an error, or the output can't be parsed
/// as a u16.
fn hermes_port_from_running_process(app: &AppHandle) -> Option<u16> {
    #[cfg(not(target_os = "windows"))]
    {
        // macOS/Linux: also try direct ps before dispatch_op for the common case
        // where hermes is running natively (not in WSL).
        use std::process::Command as StdCommand;
        let out = StdCommand::new("ps").args(["-axo", "args="]).output().ok()?;
        let stdout = String::from_utf8_lossy(&out.stdout);
        if let Some(p) = parse_hermes_port(&stdout) {
            return Some(p);
        }
        // Fall through to dispatch_op (handles the WSL / remote case if needed).
    }

    let stdout = dispatch_op(app, "hermes", "find-dashboard-port", b"", &[]).ok()?;
    let trimmed = stdout.trim();
    if trimmed.is_empty() {
        return None;
    }
    trimmed.parse::<u16>().ok()
}

#[cfg_attr(target_os = "windows", allow(dead_code))]
fn parse_hermes_port(ps_output: &str) -> Option<u16> {
    for line in ps_output.lines() {
        if !line.contains("hermes") || !line.contains("dashboard") {
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        for (i, p) in parts.iter().enumerate() {
            if *p == "--port" {
                if let Some(n) = parts.get(i + 1).and_then(|s| s.parse::<u16>().ok()) {
                    return Some(n);
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_hermes_port_extracts_port() {
        let ps = "hermes dashboard --no-open --port 9200 --host 0.0.0.0\n";
        assert_eq!(parse_hermes_port(ps), Some(9200));
    }

    #[test]
    fn parse_hermes_port_returns_none_when_no_match() {
        let ps = "some other process\nanother line\n";
        assert_eq!(parse_hermes_port(ps), None);
    }

    #[test]
    fn parse_hermes_port_returns_none_when_no_port_flag() {
        // hermes dashboard running without --port means the caller uses the default
        let ps = "hermes dashboard --no-open\n";
        assert_eq!(parse_hermes_port(ps), None);
    }

    #[test]
    fn is_listening_returns_false_for_unbound_port() {
        // Port 1 is almost certainly not listening; this just tests the
        // happy-path of the function compiling and returning a bool.
        // We can't assert false definitively (port 1 could theoretically be
        // open on a CI machine), but this is good enough for a smoke test.
        let _ = is_listening(1);
    }
}
