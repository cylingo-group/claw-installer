import { Minus, Plus, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { IS_TAURI_ENV } from "@/store/installer-store";

// Platform detection via the modern userAgentData API (Chrome 90+) with a
// fallback to the deprecated navigator.platform. Runtime detection (rather
// than #[cfg]) keeps the component file platform-agnostic for browser dev.
function detectMac(): boolean {
  if (typeof navigator === "undefined") return false;
  const platform =
    (navigator as Navigator & { userAgentData?: { platform?: string } })
      .userAgentData?.platform ?? navigator.platform;
  return platform.startsWith("Mac");
}

const isMac = detectMac();

// ── Window helpers (guarded by IS_TAURI_ENV) ──────────────────────────────────

async function hideWindow(): Promise<void> {
  if (!IS_TAURI_ENV) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  await getCurrentWindow().hide();
}

async function minimizeWindow(): Promise<void> {
  if (!IS_TAURI_ENV) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  await getCurrentWindow().minimize();
}

// ── macOS traffic-light cluster ───────────────────────────────────────────────
//
// Sized to macOS Big Sur+ conventions: 12×12 dots, 8 px gap, 11 px from the
// left window edge. Glyphs use Lucide icons at 10 px with strokeWidth 2.75 so
// they read crisply inside the small dot (the previous 8 px Unicode glyphs
// looked thin and undersized).
function MacTrafficLight() {
  // Tailwind `group` + `group-hover` shows glyphs on hover across the whole
  // cluster simultaneously — matches macOS behaviour where moving onto any one
  // dot reveals the icons on all three.
  const { t } = useTranslation();
  return (
    <div
      data-tauri-no-drag
      className="group flex items-center gap-2 pl-[11px]"
    >
      {/* Red — close / hide to tray */}
      <button
        aria-label={t("titlebar.close")}
        onClick={() => void hideWindow()}
        className="relative grid h-3 w-3 shrink-0 place-items-center rounded-full border border-black/10 transition-opacity focus:outline-none focus-visible:ring-2 focus-visible:ring-white/60"
        style={{ backgroundColor: "#FF5F57" }}
      >
        <X
          className="h-2.5 w-2.5 text-black/65 opacity-0 group-hover:opacity-100"
          strokeWidth={2.75}
        />
      </button>

      {/* Yellow — minimize */}
      <button
        aria-label={t("titlebar.minimize")}
        onClick={() => void minimizeWindow()}
        className="relative grid h-3 w-3 shrink-0 place-items-center rounded-full border border-black/10 transition-opacity focus:outline-none focus-visible:ring-2 focus-visible:ring-white/60"
        style={{ backgroundColor: "#FEBC2E" }}
      >
        <Minus
          className="h-2.5 w-2.5 text-black/65 opacity-0 group-hover:opacity-100"
          strokeWidth={2.75}
        />
      </button>

      {/* Green — disabled (window is fixed size, no maximize). Keep the dot for
          visual symmetry; show the glyph dimmed on hover. */}
      <button
        aria-label={t("titlebar.maximize")}
        onClick={() => {
          /* no-op: maximize is disabled for this fixed-size window */
        }}
        className="relative grid h-3 w-3 shrink-0 place-items-center rounded-full border border-black/10 opacity-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-white/60"
        style={{ backgroundColor: "#28C840" }}
      >
        <Plus
          className="h-2.5 w-2.5 text-black/55 opacity-0 group-hover:opacity-100"
          strokeWidth={2.75}
        />
      </button>
    </div>
  );
}

// ── Windows minimize + close buttons ─────────────────────────────────────────

function WindowsControls() {
  const { t } = useTranslation();
  return (
    <div data-tauri-no-drag className="ml-auto flex items-stretch">
      <button
        aria-label={t("titlebar.minimize")}
        onClick={() => void minimizeWindow()}
        className="flex h-8 w-10 items-center justify-center text-foreground/70 transition-colors hover:bg-white/[0.08] focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-white/40"
      >
        <Minus className="h-3.5 w-3.5" strokeWidth={2} />
      </button>
      <button
        aria-label={t("titlebar.close")}
        onClick={() => void hideWindow()}
        className="flex h-8 w-10 items-center justify-center text-foreground/70 transition-colors hover:bg-[#E81123] hover:text-white focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-white/40"
      >
        <X className="h-3.5 w-3.5" strokeWidth={2} />
      </button>
    </div>
  );
}

// ── Titlebar (root component) ─────────────────────────────────────────────────

/**
 * Frameless titlebar. The outer `data-tauri-drag-region` div is the window
 * drag handle; the spacer span fills the area between platform controls so a
 * click anywhere on the empty bar starts a drag. Interactive button clusters
 * carry `data-tauri-no-drag` to opt out.
 */
export function Titlebar() {
  return (
    <div
      data-tauri-drag-region
      className="relative flex h-8 w-full shrink-0 items-center bg-surface"
    >
      {isMac ? (
        <>
          <MacTrafficLight />
          {/* Explicit drag spacer — guarantees the rest of the bar is a drag
              surface even if a child changes flex behaviour. */}
          <div data-tauri-drag-region className="h-full flex-1" />
        </>
      ) : (
        <>
          <div data-tauri-drag-region className="h-full flex-1" />
          <WindowsControls />
        </>
      )}
    </div>
  );
}
