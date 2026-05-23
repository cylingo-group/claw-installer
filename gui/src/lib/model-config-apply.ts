// Map the GUI's ModelConfig (Active Provider + per-provider credentials) into
// the shape each agent's CLI expects. Pure functions; no IO.
//
//  - OpenClaw: a single JSON patch consumed via `openclaw config patch --file`.
//    Schema: models.providers.<id>.{baseUrl, auth, apiKey, api, models[]} +
//            agents.defaults.model = "<provider>/<modelId>".
//  - Hermes:  three `hermes config set` calls (model.provider/default/base_url)
//            plus an entry in ~/.hermes/.env keyed by `<PROVIDER>_API_KEY`.

import {
  isCustomFilled,
  isProviderFilled,
  type ApiStyle,
  type CustomCredentials,
  type KnownProvider,
  type ModelConfig,
  type ModelProvider,
  type ProviderCredentials,
} from "@/store/installer-store";

interface KnownProviderDefaults {
  baseUrl: string;
  openclawApi: OpenclawApiAdapter;
  /** When true, the GUI also writes the `models` array in the openclaw patch
   *  (and opts into the protected-path replace). Required for providers whose
   *  catalog openclaw doesn't ship out of the box. */
  managesModels?: boolean;
}

type OpenclawApiAdapter =
  | "openai-completions"
  | "openai-responses"
  | "anthropic-messages"
  | "ollama";

const KNOWN_PROVIDER_DEFAULTS: Record<KnownProvider, KnownProviderDefaults> = {
  deepseek: {
    baseUrl: "https://api.deepseek.com",
    openclawApi: "openai-completions",
  },
  kimi: {
    baseUrl: "https://api.moonshot.cn/v1",
    openclawApi: "openai-completions",
  },
  // Kimi Coding Plan ships under a separate domain with the `kimi-for-coding`
  // model id; treat it as its own provider slug in both openclaw and hermes.
  // openclaw doesn't bundle a catalog for this provider, so include `models`
  // in the patch and own the array.
  "kimi-coding": {
    baseUrl: "https://api.kimi.com/coding/v1",
    openclawApi: "openai-completions",
    managesModels: true,
  },
  minimax: {
    baseUrl: "https://api.minimaxi.com/v1",
    openclawApi: "openai-completions",
  },
};

/** Resolve which inner provider the user has selected as Active. */
export type ResolvedProvider =
  | { kind: "xinyuan" }
  | { kind: "custom"; creds: CustomCredentials }
  | { kind: "known"; id: KnownProvider; creds: ProviderCredentials };

export function resolveActiveProvider(model: ModelConfig): ResolvedProvider {
  switch (model.active) {
    case "xinyuan":
      return { kind: "xinyuan" };
    case "custom":
      return { kind: "custom", creds: model.custom };
    default:
      return {
        kind: "known",
        id: model.active,
        creds: model[model.active],
      };
  }
}

/** Whether the active provider's credentials are complete enough to save. */
export function isActiveProviderSavable(model: ModelConfig): boolean {
  const resolved = resolveActiveProvider(model);
  if (resolved.kind === "xinyuan") return false;
  if (resolved.kind === "custom") return isCustomFilled(resolved.creds);
  return isProviderFilled(resolved.creds);
}

// ---- OpenClaw patch -----------------------------------------------------------

function customApiAdapter(style: ApiStyle): OpenclawApiAdapter {
  return style === "anthropic" ? "anthropic-messages" : "openai-completions";
}

/** Slug used as the provider key inside openclaw's config (a-z0-9_-, ≤64 chars). */
export function providerIdForActive(active: ModelProvider): string {
  // Xinyuan should never reach here; callers gate on isActiveProviderSavable.
  if (active === "custom") return "custom";
  return active;
}

interface OpenclawProviderEntry {
  baseUrl: string;
  auth: "api-key";
  apiKey: string;
  api: OpenclawApiAdapter;
  /** Catalog of models under this provider. Omitted for built-in providers so
   *  openclaw's existing catalog (deepseek-chat / -reasoner / -v4-flash …) is
   *  preserved by recursive object merge. */
  models?: { id: string; name: string }[];
}

export interface OpenclawPatch {
  models: {
    providers: Record<string, OpenclawProviderEntry>;
  };
  agents: {
    defaults: {
      model: string;
    };
  };
}

export interface OpenclawPatchPlan {
  patch: OpenclawPatch;
  /** Paths the patch is intentionally replacing in full, opting out of the
   *  protected-array safety net. */
  replacePaths: string[];
}

export function buildOpenclawPatch(model: ModelConfig): OpenclawPatchPlan {
  const resolved = resolveActiveProvider(model);
  if (resolved.kind === "xinyuan") {
    throw new Error("xinyuan provider has no saveable config yet");
  }

  let providerId: string;
  let baseUrl: string;
  let api: OpenclawApiAdapter;
  let apiKey: string;
  let modelName: string;
  let includeModels: boolean;
  const replacePaths: string[] = [];

  if (resolved.kind === "custom") {
    providerId = "custom";
    baseUrl = resolved.creds.baseUrl;
    api = customApiAdapter(resolved.creds.apiStyle);
    apiKey = resolved.creds.apiKey;
    modelName = resolved.creds.modelName;
    // Custom provider has no built-in catalog — declare exactly the user's
    // chosen model and opt into replacing the models array on re-save.
    includeModels = true;
    replacePaths.push(`models.providers.${providerId}.models`);
  } else {
    providerId = resolved.id;
    const defaults = KNOWN_PROVIDER_DEFAULTS[resolved.id];
    baseUrl = defaults.baseUrl;
    api = defaults.openclawApi;
    apiKey = resolved.creds.apiKey;
    modelName = resolved.creds.modelName;
    // Most built-ins use openclaw's bundled catalog and leave `models`
    // untouched (recursive merge preserves it). Providers flagged
    // `managesModels` opt into owning the array — same path as the custom
    // provider.
    includeModels = defaults.managesModels === true;
    if (includeModels) {
      replacePaths.push(`models.providers.${providerId}.models`);
    }
  }

  const providerEntry: OpenclawProviderEntry = {
    baseUrl,
    auth: "api-key",
    apiKey,
    api,
  };
  if (includeModels) {
    providerEntry.models = [{ id: modelName, name: modelName }];
  }

  return {
    patch: {
      models: {
        providers: {
          [providerId]: providerEntry,
        },
      },
      agents: {
        defaults: {
          model: `${providerId}/${modelName}`,
        },
      },
    },
    replacePaths,
  };
}

// ---- Hermes plan --------------------------------------------------------------

export interface HermesPlan {
  /** value for `model.provider` */
  provider: string;
  /** value for `model.default` (model id) */
  defaultModel: string;
  /** value for `model.base_url` */
  baseUrl: string;
  /** uppercase env var name to write to ~/.hermes/.env */
  envVarName: string;
  /** the actual API key */
  apiKey: string;
}

/**
 * Translate a `provider` slug into the env-var name Hermes' `.env` is expected
 * to expose. Convention: `<UPPER_PROVIDER>_API_KEY` with non-alphanum → `_`.
 */
function envVarForProvider(providerSlug: string): string {
  const upper = providerSlug
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  return `${upper || "PROVIDER"}_API_KEY`;
}

export function buildHermesPlan(model: ModelConfig): HermesPlan {
  const resolved = resolveActiveProvider(model);
  if (resolved.kind === "xinyuan") {
    throw new Error("xinyuan provider has no saveable config yet");
  }

  if (resolved.kind === "custom") {
    const c = resolved.creds;
    // Use the user-supplied display name (slugified) as the hermes provider id
    // when present; fall back to literal "custom" if the user didn't name it.
    const slug =
      c.name
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "") || "custom";
    return {
      provider: slug,
      defaultModel: c.modelName,
      baseUrl: c.baseUrl,
      envVarName: envVarForProvider(slug),
      apiKey: c.apiKey,
    };
  }

  const defaults = KNOWN_PROVIDER_DEFAULTS[resolved.id];
  return {
    provider: resolved.id,
    defaultModel: resolved.creds.modelName,
    baseUrl: defaults.baseUrl,
    envVarName: envVarForProvider(resolved.id),
    apiKey: resolved.creds.apiKey,
  };
}
