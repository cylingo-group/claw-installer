import { useInstaller } from "@/store/installer-store";
import { cn } from "@/lib/utils";

export function ConfigForm() {
  const settings = useInstaller((s) => s.settings);
  const update = useInstaller((s) => s.updateSettings);
  const showAdvanced = useInstaller((s) => s.showAdvanced);
  const toggle = useInstaller((s) => s.toggleAdvanced);

  return (
    <section className="rounded-lg border border-border bg-surface">
      <header className="flex items-center justify-between border-b border-border px-5 py-3.5">
        <div>
          <h3 className="text-sm font-semibold">安装选项</h3>
          <p className="text-[11px] text-muted">默认值适合多数用户，按需调整即可</p>
        </div>
        <button
          onClick={toggle}
          className="flex items-center gap-1 rounded px-2 py-1 text-xs text-muted hover:bg-background hover:text-foreground"
        >
          高级
          <ChevronIcon open={showAdvanced} />
        </button>
      </header>

      <div className="grid gap-4 px-5 py-4 sm:grid-cols-2">
        <Field
          label="安装包镜像"
          hint="npm / pnpm registry mirror"
          value={settings.registryMirror}
          onChange={(v) => update("registryMirror", v)}
        />
        <Field
          label="工作目录"
          hint="openclaw workspace"
          value={settings.workspace}
          onChange={(v) => update("workspace", v)}
        />
      </div>

      {showAdvanced && (
        <div className="border-t border-border px-5 py-4">
          <div className="grid gap-4 sm:grid-cols-2">
            <Field
              label="网关端口"
              hint="gateway.port"
              value={String(settings.gatewayPort)}
              onChange={(v) => update("gatewayPort", Number(v) || 7841)}
              mono
            />
            <Field
              label="网关绑定地址"
              hint="gateway.bind"
              value={settings.gatewayBind}
              onChange={(v) => update("gatewayBind", v)}
              mono
            />
            <SelectField
              label="后台服务"
              hint="INSTALLER_SERVICE_MODE"
              value={settings.serviceMode}
              onChange={(v) => update("serviceMode", v as typeof settings.serviceMode)}
              options={[
                { value: "daemon", label: "始终在后台运行" },
                { value: "foreground", label: "仅手动启动" },
                { value: "skip", label: "不安装服务" },
              ]}
            />
            <div className="flex flex-col justify-end gap-2 pb-1">
              <Toggle
                label="强制重新安装所有依赖"
                hint="INSTALLER_FORCE_REINSTALL"
                checked={settings.forceReinstall}
                onChange={(v) => update("forceReinstall", v)}
              />
              <Toggle
                label="跳过浏览器运行时（Hermes）"
                hint="INSTALLER_HERMES_SKIP_BROWSER"
                checked={settings.skipBrowser}
                onChange={(v) => update("skipBrowser", v)}
              />
            </div>
          </div>
        </div>
      )}
    </section>
  );
}

function Field({
  label,
  hint,
  value,
  onChange,
  mono,
}: {
  label: string;
  hint: string;
  value: string;
  onChange: (v: string) => void;
  mono?: boolean;
}) {
  return (
    <label className="flex flex-col gap-1.5">
      <span className="flex items-baseline justify-between gap-2">
        <span className="text-xs font-medium text-foreground">{label}</span>
        <span className="text-[10px] text-muted" lang="en">
          {hint}
        </span>
      </span>
      <input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className={cn(
          "rounded border border-border bg-background px-2.5 py-1.5 text-sm text-foreground",
          "focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/20",
          mono && "font-mono text-[13px]"
        )}
      />
    </label>
  );
}

function SelectField({
  label,
  hint,
  value,
  onChange,
  options,
}: {
  label: string;
  hint: string;
  value: string;
  onChange: (v: string) => void;
  options: ReadonlyArray<{ value: string; label: string }>;
}) {
  return (
    <label className="flex flex-col gap-1.5">
      <span className="flex items-baseline justify-between gap-2">
        <span className="text-xs font-medium text-foreground">{label}</span>
        <span className="text-[10px] text-muted" lang="en">
          {hint}
        </span>
      </span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="rounded border border-border bg-background px-2.5 py-1.5 text-sm text-foreground focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/20"
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </label>
  );
}

function Toggle({
  label,
  hint,
  checked,
  onChange,
}: {
  label: string;
  hint: string;
  checked: boolean;
  onChange: (v: boolean) => void;
}) {
  return (
    <button
      onClick={() => onChange(!checked)}
      className="flex items-start justify-between gap-3 rounded border border-border bg-background px-3 py-2 text-left hover:border-foreground/40"
    >
      <div className="min-w-0">
        <div className="text-xs font-medium text-foreground">{label}</div>
        <div className="text-[10px] text-muted" lang="en">
          {hint}
        </div>
      </div>
      <span
        className={cn(
          "relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors",
          checked ? "bg-accent" : "bg-border"
        )}
      >
        <span
          className={cn(
            "inline-block h-4 w-4 transform rounded-full bg-surface shadow transition-transform",
            checked ? "translate-x-4" : "translate-x-0.5"
          )}
        />
      </span>
    </button>
  );
}

function ChevronIcon({ open }: { open: boolean }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={cn("h-3.5 w-3.5 transition-transform", open && "rotate-180")}
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
    >
      <path d="M6 9l6 6 6-6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
