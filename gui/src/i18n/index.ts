/**
 * i18n setup for the GUI.
 *
 * - Resources live inline in this module (en + zh, no JSON file fetches).
 *   The bundles are tiny so eager-load is simpler than lazy-load.
 * - Default language: detected from `navigator.language` at startup via
 *   i18next-browser-languagedetector. User's manual choice (set in
 *   AppSettingsPanel) is persisted to claw-installer's config.json, NOT
 *   localStorage — config.json is the single source of truth that survives
 *   `~/.claw-installer/` resets and is shared across reinstalls. The store
 *   bootstrap calls `applyPersistedLanguage` after reading config.json so
 *   the persisted value overrides the navigator-detected one before any
 *   user-visible component has settled.
 * - Fallback: English. Any missing key falls back to the English string
 *   (or — if not in en either — the key itself), which is a safer default
 *   than showing a broken render in production.
 */

import i18n from "i18next";
import LanguageDetector from "i18next-browser-languagedetector";
import { initReactI18next } from "react-i18next";

import { en } from "./resources/en";
import { zh } from "./resources/zh";

export const SUPPORTED_LANGUAGES = ["en", "zh"] as const;
export type Lang = (typeof SUPPORTED_LANGUAGES)[number];

void i18n
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    resources: {
      en: { translation: en },
      zh: { translation: zh },
    },
    fallbackLng: "en",
    supportedLngs: SUPPORTED_LANGUAGES,
    nonExplicitSupportedLngs: true, // "zh-CN" → "zh"
    interpolation: {
      escapeValue: false, // React already escapes
    },
    detection: {
      // No localStorage: config.json is authoritative for the user's choice,
      // applied via applyPersistedLanguage() after bootstrap. Detector only
      // runs to pick an OS-locale-driven default for fresh installs.
      order: ["navigator"],
      caches: [],
    },
  });

export default i18n;

/** Resolve the canonical short code (en/zh) regardless of region. */
export function shortLang(raw: string | undefined): Lang {
  if (!raw) return "en";
  const head = raw.toLowerCase().split("-")[0];
  return (SUPPORTED_LANGUAGES as readonly string[]).includes(head)
    ? (head as Lang)
    : "en";
}

/**
 * Apply a language value read from config.json. Called by the store's
 * bootstrap after `readModelConfigs` lands. Tolerates undefined / unsupported
 * values by leaving the navigator-detected default in place. No-op when the
 * persisted value already matches the current language (avoids a re-render
 * cascade on every bootstrap).
 */
export function applyPersistedLanguage(raw: string | undefined): void {
  if (!raw) return;
  const lang = shortLang(raw);
  if (i18n.resolvedLanguage === lang) return;
  void i18n.changeLanguage(lang);
}
