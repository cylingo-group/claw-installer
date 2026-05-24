//! Persistent per-launch Tauri log file.
//!
//! Opens `<tmp_dir>/claw-installer/logs/tauri-<unix-ts>.log` once at process start,
//! appends log lines in `<ISO-8601-UTC> <LEVEL> [<module>] <message>\n` format,
//! and mirrors to stderr in debug builds.
//!
//! # Usage
//!
//! Call `log_init()` once from `lib.rs::run()` before any other backend code.
//! Then use `log_info!`, `log_warn!`, `log_error!` anywhere:
//!
//! ```ignore
//! log_info!("commands::run_installer", "agents={:?} log={:?}", agents, log_path);
//! log_error!("dashboard::approve_latest_device", "dispatch failed: {}", e);
//! ```
//!
//! If `log_init` was never called (e.g., in unit tests) the macros silently
//! write to stderr only — they never panic.
//!
//! # Constraints
//!
//! - No external logging crates. `std` only.
//! - Thread-safe: `OnceLock<Mutex<File>>` holds the writer; each `log_*!` call
//!   acquires the lock, writes a line, and releases it.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

// ── Internal state ────────────────────────────────────────────────────────────

/// Global log file writer. Set once by `log_init`; `None` until then.
static LOG_FILE: OnceLock<Mutex<fs::File>> = OnceLock::new();

/// Path of the log file opened by `log_init`. Used by `log_path()`.
static LOG_PATH: OnceLock<PathBuf> = OnceLock::new();

// ── Public API ────────────────────────────────────────────────────────────────

/// Initialise the logger.
///
/// Creates `<tmp_dir>/claw-installer/logs/` and opens
/// `tauri-<unix-ts>.log` in append mode. Called once from `lib.rs::run()`.
///
/// On failure (e.g. permission denied on `tmp_dir`) the function logs the
/// error to stderr and returns — it does NOT panic. Subsequent `log_*!` calls
/// gracefully fall back to stderr-only.
///
/// Returns the path of the opened log file so the caller can stash it.
pub fn log_init() -> PathBuf {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let mut dir = std::env::temp_dir();
    dir.push("claw-installer");
    dir.push("logs");
    if let Err(e) = fs::create_dir_all(&dir) {
        eprintln!(
            "[claw-installer] logger: failed to create log dir {}: {}",
            dir.display(),
            e
        );
        return dir.join(format!("tauri-{}.log", ts));
    }

    let path = dir.join(format!("tauri-{}.log", ts));

    match fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        Ok(file) => {
            // Only set once; subsequent calls are no-ops.
            let _ = LOG_FILE.set(Mutex::new(file));
            let _ = LOG_PATH.set(path.clone());
            // Write a header line so the file is findable and timestamped.
            write_line("INFO", "logger", "tauri log opened");
        }
        Err(e) => {
            eprintln!(
                "[claw-installer] logger: failed to open {}: {}",
                path.display(),
                e
            );
        }
    }

    // Always store the path even when open failed, so log_path() is usable.
    let _ = LOG_PATH.set(path.clone());
    path
}

/// Return the path of the current log file, or `None` if `log_init` has not
/// been called yet (e.g. in unit tests).
pub fn log_path() -> Option<&'static Path> {
    LOG_PATH.get().map(|p| p.as_path())
}

/// Write one log line. Called by the `log_info!` / `log_warn!` / `log_error!`
/// macros. Public so the macros can call it from any module.
#[doc(hidden)]
pub fn write_line(level: &str, module: &str, message: &str) {
    let now = format_utc_now();
    let line = format!("{} {} [{}] {}\n", now, level, module, message);

    // Mirror to stderr in debug builds (always useful during development).
    #[cfg(debug_assertions)]
    eprint!("[claw-installer] {}", line);

    // Write to the persistent log file when available.
    if let Some(mutex) = LOG_FILE.get() {
        if let Ok(mut file) = mutex.lock() {
            let _ = file.write_all(line.as_bytes());
        }
    }
}

// ── Macros ────────────────────────────────────────────────────────────────────

/// Log at INFO level. Usage: `log_info!("module::function", "msg {}", val)`.
#[macro_export]
macro_rules! log_info {
    ($module:expr, $($arg:tt)*) => {
        $crate::logger::write_line("INFO", $module, &format!($($arg)*))
    };
}

/// Log at WARN level. Usage: `log_warn!("module::function", "msg {}", val)`.
#[macro_export]
macro_rules! log_warn {
    ($module:expr, $($arg:tt)*) => {
        $crate::logger::write_line("WARN", $module, &format!($($arg)*))
    };
}

/// Log at ERROR level. Usage: `log_error!("module::function", "msg {}", val)`.
#[macro_export]
macro_rules! log_error {
    ($module:expr, $($arg:tt)*) => {
        $crate::logger::write_line("ERROR", $module, &format!($($arg)*))
    };
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Format the current time as an ISO-8601 UTC timestamp, e.g.
/// `2026-05-23T09:14:02Z`. Uses only `std::time` — no chrono dependency.
pub(crate) fn format_utc_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Convert Unix seconds to (year, month, day, H, M, S) via Gregorian calendar.
    let (y, mo, d, h, mi, s) = unix_secs_to_parts(secs);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, mo, d, h, mi, s)
}

/// Decompose a Unix timestamp (seconds since 1970-01-01T00:00:00Z) into
/// `(year, month, day, hour, minute, second)` via the Gregorian proleptic
/// calendar. Pure integer arithmetic; no libc calls.
fn unix_secs_to_parts(secs: u64) -> (u64, u64, u64, u64, u64, u64) {
    let s = secs % 60;
    let total_min = secs / 60;
    let mi = total_min % 60;
    let total_hours = total_min / 60;
    let h = total_hours % 24;
    let mut days = total_hours / 24; // days since 1970-01-01

    // Gregorian calendar: 400-year cycle = 146097 days.
    let (y, mut m, mut d);
    let n400 = days / 146097;
    days %= 146097;
    let n100 = (days / 36524).min(3);
    days -= n100 * 36524;
    let n4 = days / 1461;
    days %= 1461;
    let n1 = (days / 365).min(3);
    days -= n1 * 365;
    y = n400 * 400 + n100 * 100 + n4 * 4 + n1 + 1970;

    // Day-of-year to month/day. Leap year if divisible by 4 but not 100,
    // or divisible by 400.
    let is_leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days: [u64; 12] = if is_leap {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    m = 0u64;
    d = days;
    for md in &month_days {
        if d < *md {
            break;
        }
        d -= md;
        m += 1;
    }
    (y, m + 1, d + 1, h, mi, s)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// `log_path_returns_some_after_init` — confirms `log_init` populates the
    /// OnceLock so `log_path()` returns `Some`.
    ///
    /// Note: because `OnceLock` is global and can only be set once per process,
    /// this test relies on being the first (or only) test that calls `log_init`.
    /// Calling `log_init` in multiple tests is idempotent — the second call
    /// returns immediately without re-opening the file.
    #[test]
    fn log_path_returns_some_after_init() {
        let path = log_init();
        // log_path() must return Some now that log_init has been called.
        assert!(
            log_path().is_some(),
            "log_path() returned None after log_init()"
        );
        // The returned PathBuf and the static path should agree.
        let static_path = log_path().unwrap();
        // Both should be inside claw-installer temp dir.
        assert!(
            path.to_string_lossy().contains("claw-installer"),
            "expected claw-installer in path, got {:?}",
            path
        );
        assert!(
            static_path.to_string_lossy().contains("claw-installer"),
            "expected claw-installer in static path, got {:?}",
            static_path
        );
        assert!(
            path.to_string_lossy().contains("tauri-"),
            "expected tauri- prefix, got {:?}",
            path
        );
    }

    /// `log_macros_compile` — sanity check that macros expand without
    /// requiring `log_init` to have been called first (they should silently
    /// write to stderr-only when the file isn't open).
    #[test]
    fn log_macros_compile() {
        // These must compile and not panic.
        log_info!("test::module", "info message {}", 42);
        log_warn!("test::module", "warn message {}", "foo");
        log_error!("test::module", "error message {}", true);
    }

    #[test]
    fn format_utc_now_looks_like_iso8601() {
        let s = format_utc_now();
        // Should match YYYY-MM-DDTHH:MM:SSZ (19 chars + Z = 20)
        assert_eq!(s.len(), 20, "unexpected format: {:?}", s);
        assert!(s.ends_with('Z'), "should end with Z: {:?}", s);
        assert!(s.contains('T'), "should contain T: {:?}", s);
    }

    #[test]
    fn unix_secs_to_parts_epoch() {
        // Unix epoch = 1970-01-01 00:00:00 UTC
        let (y, mo, d, h, mi, s) = unix_secs_to_parts(0);
        assert_eq!((y, mo, d, h, mi, s), (1970, 1, 1, 0, 0, 0));
    }

    #[test]
    fn unix_secs_to_parts_known_date() {
        // 2026-05-23 09:00:00 UTC = 1779526800
        let (y, mo, d, h, mi, s) = unix_secs_to_parts(1779526800);
        assert_eq!(y, 2026);
        assert_eq!(mo, 5);
        assert_eq!(d, 23);
        assert_eq!(h, 9);
        assert_eq!(mi, 0);
        assert_eq!(s, 0);
    }

    #[test]
    fn unix_secs_to_parts_leap_year() {
        // 2024-02-29 00:00:00 UTC — leap day
        // 2024-02-29 = 1709164800
        let (y, mo, d, h, mi, s) = unix_secs_to_parts(1709164800);
        assert_eq!((y, mo, d, h, mi, s), (2024, 2, 29, 0, 0, 0));
    }
}
