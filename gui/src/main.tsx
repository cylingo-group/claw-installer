import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles/index.css";
import "./styles/tokens.css";
// Initialize i18n before React mounts so the first paint already sees
// the resolved language. Side-effect-only import — no exports used here.
import "./i18n";

const root = createRoot(document.getElementById("root")!);
root.render(
  <StrictMode>
    <App />
  </StrictMode>
);

// Remove the pre-mount skeleton (index.html #boot-splash) once React has
// committed its first paint. requestAnimationFrame gives the browser a chance
// to flush the React tree onto the screen first, so we crossfade out only
// after the real UI is visible — preventing a brief flash of blank between
// splash removal and React mount.
requestAnimationFrame(() => {
  const splash = document.getElementById("boot-splash");
  if (!splash) return;
  splash.classList.add("bs-hidden");
  splash.addEventListener("transitionend", () => splash.remove(), { once: true });
  // Fallback in case transitionend never fires (e.g. CSS overridden in tests).
  setTimeout(() => splash.remove(), 400);
});
