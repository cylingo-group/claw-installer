export const openclawLogScript: ReadonlyArray<{ step: string; line: string }> = [
  { step: "base-deps", line: "==> base-deps: checking curl, git, openssl, unzip, ca-certificates" },
  { step: "base-deps", line: "    curl 8.7.1                  preexisting" },
  { step: "base-deps", line: "    git 2.45.2                  preexisting" },
  { step: "base-deps", line: "    openssl 3.3.1               preexisting" },
  { step: "fnm",       line: "==> fnm: installing v1.38.1 (vendored)" },
  { step: "fnm",       line: "    fnm installed -> ~/.local/share/fnm/fnm" },
  { step: "node",      line: "==> node: installing v22.13.1 via fnm" },
  { step: "node",      line: "    Downloading node-v22.13.1-darwin-arm64.tar.xz …" },
  { step: "node",      line: "    Activated node v22.13.1" },
  { step: "pnpm",      line: "==> pnpm: enabling via corepack" },
  { step: "pnpm",      line: "    pnpm 9.15.0 ready" },
  { step: "npmrc",     line: "==> npmrc: writing mirror block to ~/.npmrc" },
  { step: "openclaw",  line: "==> openclaw: pnpm add -g @openclaw/cli" },
  { step: "openclaw",  line: "    + @openclaw/cli 1.4.2" },
  { step: "openclaw",  line: "==> openclaw: applying config" },
  { step: "openclaw",  line: "    gateway.port = 7841" },
  { step: "openclaw",  line: "    gateway.bind = 127.0.0.1" },
  { step: "openclaw",  line: "    workspace    = ~/openclaw" },
  { step: "openclaw",  line: "==> openclaw: starting background service" },
  { step: "openclaw",  line: "    gateway daemon ready on http://127.0.0.1:7841" },
  { step: "done",      line: "✓ openclaw installed in 47.3s — ready" },
];

export const hermesLogScript: ReadonlyArray<{ step: string; line: string }> = [
  { step: "base-deps", line: "==> base-deps: re-checking (already satisfied by openclaw run)" },
  { step: "hermes",    line: "==> hermes: cloning hermes-agent into ~/code/hermes-agent" },
  { step: "hermes",    line: "    Resolving deltas: 100% (2841/2841), done." },
  { step: "hermes",    line: "==> hermes: running upstream install.sh" },
  { step: "hermes",    line: "    Installing Python 3.11 via uv …" },
  { step: "hermes",    line: "    uv pip install -e . (218 packages)" },
  { step: "hermes",    line: "==> hermes: installing browser runtime (Playwright)" },
  { step: "hermes",    line: "    Chromium 125.0.6422 downloaded" },
  { step: "hermes",    line: "==> hermes: linking ~/.local/bin/hermes" },
  { step: "done",      line: "✓ hermes installed in 1m 12s — ready" },
];

export const recentRuns = [
  { id: "install-2026-05-18T12-04-11Z.log", label: "今天 20:04", agent: "openclaw", outcome: "success" as const },
  { id: "install-2026-05-17T22-51-03Z.log", label: "昨天 06:51", agent: "hermes",   outcome: "failed"  as const },
  { id: "install-2026-05-17T03-12-58Z.log", label: "5 月 17 日", agent: "openclaw", outcome: "success" as const },
];
