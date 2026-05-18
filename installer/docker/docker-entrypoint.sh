#!/usr/bin/env bash
# Container entrypoint. install-openclaw.sh already ran at image build time
# (see Dockerfile), so here we only:
#  1) optionally register DeepSeek as the default provider via env vars
#  2) exec gateway in foreground so the container lifetime = gateway lifetime
set -euo pipefail

export FNM_DIR="$HOME/.local/share/fnm"
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME/bin:$PNPM_HOME:$FNM_DIR:$PATH"
eval "$(fnm env --shell bash 2>/dev/null)" 2>/dev/null || true

if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
  echo "[entrypoint] registering DeepSeek provider..."
  DEEPSEEK_BASE_URL="${DEEPSEEK_BASE_URL:-https://api.deepseek.com}"
  DEEPSEEK_MODEL="${DEEPSEEK_MODEL:-deepseek-v4-flash}"
  cat <<JSON | openclaw config patch --stdin
{
  "models": {
    "providers": {
      "deepseek": {
        "baseUrl": "${DEEPSEEK_BASE_URL}",
        "auth": "api-key",
        "apiKey": "${DEEPSEEK_API_KEY}",
        "api": "openai-completions",
        "models": [
          { "id": "${DEEPSEEK_MODEL}", "name": "DeepSeek" },
          { "id": "deepseek-chat", "name": "DeepSeek Chat" }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": "deepseek/${DEEPSEEK_MODEL}"
    }
  }
}
JSON
  openclaw config validate
fi

exec openclaw gateway --port "${INSTALLER_GATEWAY_PORT:-18789}" --verbose
