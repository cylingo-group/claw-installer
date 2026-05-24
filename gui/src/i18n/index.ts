/**
 * i18n setup for the GUI.
 *
 * - Resources live inline in this module (en + zh, no JSON file fetches).
 *   The bundles are tiny so eager-load is simpler than lazy-load.
 * - Default language: auto-detect from navigator.language via
 *   i18next-browser-languagedetector. User's manual choice (set in
 *   AppSettingsPanel) is persisted to localStorage with key
 *   `claw-installer-lang`.
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

const LANG_STORAGE_KEY = "claw-installer-lang";

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
      order: ["localStorage", "navigator"],
      lookupLocalStorage: LANG_STORAGE_KEY,
      caches: ["localStorage"],
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
