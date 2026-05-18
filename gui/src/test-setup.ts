import "@testing-library/jest-dom";

// Ensure __TAURI_INTERNALS__ is absent in test environment
// (tests run in jsdom, not a Tauri webview)
if (typeof window !== "undefined") {
  delete (window as Record<string, unknown>)["__TAURI_INTERNALS__"];
}
