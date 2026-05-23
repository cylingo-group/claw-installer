// Fetch the list of available models from a provider's `/models` endpoint,
// routed through Tauri's HTTP plugin (so the webview CORS layer doesn't
// block external API calls).

import { fetch as tauriFetch } from "@tauri-apps/plugin-http";
import type { ApiStyle, KnownProvider } from "@/store/installer-store";

/** Identifies a known-provider built-in or a freeform custom slot. */
export type ProviderFetchKind =
  | { kind: "known"; id: KnownProvider }
  | { kind: "custom"; baseUrl: string; apiStyle: ApiStyle };

const KNOWN_BASE_URLS: Record<KnownProvider, string> = {
  deepseek: "https://api.deepseek.com",
  kimi: "https://api.moonshot.cn/v1",
  // Kimi 编程套餐 (Kimi Coding Plan). Separate product from the standard
  // Moonshot API: distinct base URL, key prefix (`sk-kimi-…`), and only the
  // single fixed model `kimi-for-coding`. Keys issued for one do not work
  // against the other.
  "kimi-coding": "https://api.kimi.com/coding/v1",
  minimax: "https://api.minimaxi.com/v1",
};

/**
 * Curated "popular models" surfaced in the model-name combobox before the
 * user has supplied an API key (and as a fallback if the `/models` call
 * fails). Not exhaustive — the user can still free-type any id.
 */
const KNOWN_DEFAULT_MODELS: Record<KnownProvider, string[]> = {
  deepseek: ["deepseek-chat", "deepseek-reasoner", "deepseek-coder"],
  kimi: [
    "moonshot-v1-8k",
    "moonshot-v1-32k",
    "moonshot-v1-128k",
    "moonshot-v1-auto",
    "kimi-k2",
  ],
  // Coding plan exposes a single fixed model regardless of OpenAI / Anthropic
  // compatibility mode — no point hitting /models since most coding-plan keys
  // don't have list-models scope.
  "kimi-coding": ["kimi-for-coding"],
  minimax: ["abab6.5s-chat", "abab6.5g-chat", "abab5.5s-chat"],
};

/**
 * Known providers whose model list is fixed by the vendor (no point calling
 * `/models`). We surface the curated list directly and skip the network round
 * trip — fewer spurious 401s in the UI.
 */
const FIXED_MODEL_PROVIDERS: ReadonlySet<KnownProvider> = new Set([
  "kimi-coding",
]);

export function getKnownDefaultModels(id: KnownProvider): string[] {
  return KNOWN_DEFAULT_MODELS[id] ?? [];
}

export function hasFixedModels(id: KnownProvider): boolean {
  return FIXED_MODEL_PROVIDERS.has(id);
}

interface OpenAiModelEnvelope {
  data?: Array<{ id?: string }>;
}

interface AnthropicModelEnvelope {
  data?: Array<{ id?: string }>;
}

/**
 * GET `<baseUrl>/models` (OpenAI-compat) or `<baseUrl>/v1/models` (Anthropic)
 * and return a deduped, sorted list of model ids.
 *
 * Throws with a Chinese-language message describing the failure so callers
 * can surface it inline. Aborts after `timeoutMs`.
 */
export async function fetchProviderModels(
  fetchKind: ProviderFetchKind,
  apiKey: string,
  options: { timeoutMs?: number; signal?: AbortSignal } = {},
): Promise<string[]> {
  if (apiKey.trim() === "") {
    throw new Error("缺少 API Key");
  }

  const apiStyle: ApiStyle =
    fetchKind.kind === "custom" ? fetchKind.apiStyle : "openai";
  const baseUrl =
    fetchKind.kind === "custom"
      ? fetchKind.baseUrl.trim()
      : KNOWN_BASE_URLS[fetchKind.id];

  if (baseUrl === "") {
    throw new Error("缺少 Base URL");
  }

  const url = buildModelsUrl(baseUrl, apiStyle);
  const headers: Record<string, string> = { accept: "application/json" };
  if (apiStyle === "anthropic") {
    headers["x-api-key"] = apiKey;
    headers["anthropic-version"] = "2023-06-01";
  } else {
    headers["authorization"] = `Bearer ${apiKey}`;
  }

  const timeoutMs = options.timeoutMs ?? 10_000;
  const ctrl = new AbortController();
  const linkAbort = () => ctrl.abort();
  options.signal?.addEventListener("abort", linkAbort, { once: true });
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);

  let resp: Response;
  try {
    resp = await tauriFetch(url, {
      method: "GET",
      headers,
      signal: ctrl.signal,
    });
  } catch (err) {
    options.signal?.removeEventListener("abort", linkAbort);
    clearTimeout(timer);
    if (err instanceof DOMException && err.name === "AbortError") {
      throw new Error("请求超时或被取消");
    }
    throw new Error(`请求失败：${err instanceof Error ? err.message : err}`);
  }
  options.signal?.removeEventListener("abort", linkAbort);
  clearTimeout(timer);

  if (!resp.ok) {
    let detail = "";
    try {
      detail = (await resp.text()).slice(0, 200);
    } catch {
      // ignore
    }
    throw new Error(
      `HTTP ${resp.status} ${resp.statusText}${detail ? `: ${detail}` : ""}`,
    );
  }

  let body: OpenAiModelEnvelope | AnthropicModelEnvelope;
  try {
    body = (await resp.json()) as OpenAiModelEnvelope;
  } catch (err) {
    throw new Error(
      `响应不是合法 JSON：${err instanceof Error ? err.message : err}`,
    );
  }

  const ids = Array.isArray(body.data)
    ? body.data
        .map((m) => (typeof m?.id === "string" ? m.id.trim() : ""))
        .filter((id) => id !== "")
    : [];

  if (ids.length === 0) {
    throw new Error("响应中没有可用模型");
  }

  return [...new Set(ids)].sort((a, b) => a.localeCompare(b));
}

function buildModelsUrl(baseUrl: string, apiStyle: ApiStyle): string {
  const trimmed = baseUrl.replace(/\/+$/, "");
  // Anthropic's models endpoint lives under /v1/models regardless of how
  // the user wrote the base URL. OpenAI-compat endpoints already include
  // /v1 in the base URL for most providers; if not, append /models directly.
  if (apiStyle === "anthropic") {
    return trimmed.endsWith("/v1") ? `${trimmed}/models` : `${trimmed}/v1/models`;
  }
  return `${trimmed}/models`;
}
