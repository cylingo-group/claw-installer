import { useTranslation } from "react-i18next";
import { useInstaller, type MirrorSource } from "@/store/installer-store";
import { cn } from "@/lib/utils";
import { SUPPORTED_LANGUAGES, shortLang, type Lang } from "@/i18n";

interface MirrorOption {
  value: MirrorSource;
  labelKey: string;
  endpoints: { tool: string; host: string }[];
}

const MIRROR_OPTIONS: MirrorOption[] = [
  {
    value: "official",
    labelKey: "appSettings.officialLabel",
    endpoints: [
      { tool: "npm", host: "registry.npmjs.org" },
      { tool: "Homebrew", host: "formulae.brew.sh" },
      { tool: "GitHub", host: "github.com" },
    ],
  },
  {
    value: "accelerated",
    labelKey: "appSettings.mirrorLabel",
    endpoints: [
      { tool: "npm", host: "registry.npmmirror.com" },
      { tool: "Homebrew", host: "mirrors.aliyun.com" },
      { tool: "GitHub", host: "gitee.com" },
    ],
  },
];

export function AppSettingsPanel() {
  const { t, i18n } = useTranslation();
  const open = useInstaller((s) => s.appSettingsOpen);
  const close = useInstaller((s) => s.closeAppSettings);
  const mirrorSource = useInstaller((s) => s.settings.mirrorSource);
  const updateSettings = useInstaller((s) => s.updateSettings);

  const currentLang = shortLang(i18n.resolvedLanguage ?? i18n.language);
  const setLang = (lang: Lang) => {
    void i18n.changeLanguage(lang);
  };

  return (
    <section
      aria-hidden={!open}
      className={cn(
        "absolute inset-0 z-20 flex flex-col bg-surface",
        "transition-transform duration-200 ease-out",
        open ? "translate-x-0" : "translate-x-full pointer-events-none"
      )}
    >
      <header className="flex items-center gap-2 border-b border-border px-3 py-3">
        <button
          onClick={close}
          aria-label={t("common.back")}
          className="grid h-7 w-7 shrink-0 place-items-center rounded text-muted transition-colors hover:bg-background hover:text-foreground"
        >
          <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <path d="M15 6l-6 6 6 6" />
          </svg>
        </button>
        <div className="min-w-0 flex-1 leading-tight">
          <div className="truncate text-sm font-semibold">{t("appSettings.title")}</div>
        </div>
      </header>

      <div className="flex-1 overflow-y-auto px-5 py-5">
        <fieldset>
          <legend className="flex items-center gap-2">
            <span className="grid h-6 w-6 shrink-0 place-items-center rounded-md bg-accent/10 text-accent">
              <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                <ellipse cx="12" cy="5" rx="9" ry="3" />
                <path d="M3 5v6c0 1.66 4.03 3 9 3s9-1.34 9-3V5" />
                <path d="M3 11v6c0 1.66 4.03 3 9 3s9-1.34 9-3v-6" />
              </svg>
            </span>
            <span className="text-sm font-semibold text-foreground">{t("appSettings.installSource")}</span>
          </legend>

          <div role="radiogroup" aria-label={t("appSettings.installSourceAria")} className="mt-3 space-y-2">
            {MIRROR_OPTIONS.map((opt) => {
              const selected = mirrorSource === opt.value;
              return (
                <label
                  key={opt.value}
                  className={cn(
                    "flex cursor-pointer items-start gap-3 rounded-md border px-3.5 py-3 transition-colors",
                    selected
                      ? "border-accent bg-accent/[0.04]"
                      : "border-border hover:border-foreground/30"
                  )}
                >
                  <input
                    type="radio"
                    name="mirror-source"
                    value={opt.value}
                    checked={selected}
                    onChange={() => updateSettings("mirrorSource", opt.value)}
                    className="mt-1 h-3.5 w-3.5 shrink-0 accent-accent"
                  />
                  <div className="min-w-0 flex-1">
                    <div
                      className={cn(
                        "text-sm font-medium",
                        selected ? "text-accent" : "text-foreground"
                      )}
                    >
                      {t(opt.labelKey)}
                    </div>
                    <dl className="mt-1.5 space-y-0.5">
                      {opt.endpoints.map((ep) => (
                        <div key={ep.tool} className="flex items-baseline gap-2 text-[11px]">
                          <dt className="w-16 shrink-0 text-muted">{ep.tool}</dt>
                          <dd className="min-w-0 truncate text-foreground/70" lang="en">
                            {ep.host}
                          </dd>
                        </div>
                      ))}
                    </dl>
                  </div>
                </label>
              );
            })}
          </div>
        </fieldset>

        <fieldset className="mt-6">
          <legend className="flex items-center gap-2">
            <span className="grid h-6 w-6 shrink-0 place-items-center rounded-md bg-accent/10 text-accent">
              <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                <circle cx="12" cy="12" r="10" />
                <path d="M2 12h20" />
                <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
              </svg>
            </span>
            <span className="text-sm font-semibold text-foreground">{t("appSettings.languageHeading")}</span>
          </legend>

          <div role="radiogroup" aria-label={t("appSettings.languageAria")} className="mt-3 space-y-2">
            {SUPPORTED_LANGUAGES.map((lang) => {
              const selected = currentLang === lang;
              const label = lang === "en" ? t("appSettings.langEn") : t("appSettings.langZh");
              return (
                <label
                  key={lang}
                  className={cn(
                    "flex cursor-pointer items-center gap-3 rounded-md border px-3.5 py-2.5 transition-colors",
                    selected
                      ? "border-accent bg-accent/[0.04]"
                      : "border-border hover:border-foreground/30"
                  )}
                >
                  <input
                    type="radio"
                    name="ui-language"
                    value={lang}
                    checked={selected}
                    onChange={() => setLang(lang)}
                    className="h-3.5 w-3.5 shrink-0 accent-accent"
                  />
                  <span
                    className={cn(
                      "text-sm font-medium",
                      selected ? "text-accent" : "text-foreground"
                    )}
                  >
                    {label}
                  </span>
                </label>
              );
            })}
          </div>
        </fieldset>
      </div>
    </section>
  );
}
