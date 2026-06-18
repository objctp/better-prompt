import { readFileSync } from "node:fs";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import process from "node:process";
import type {
  Catalog,
  CatalogCandidate,
  CatalogModel,
  ModelEntry,
  ModelRef,
  OpenCodeConfig,
} from "./types";

// :::: Constants :::: ///////////////////////////////////////

export const TIER_CYCLE: readonly string[] = ["fast", "capable", "powerful"];

export const TIER_ALIASES: Record<string, string> = {
  haiku: "fast",
  sonnet: "capable",
  opus: "powerful",
};

export const MODEL_DEFAULTS: Record<string, string> = {
  correction_model: "haiku",
  translation_model: "haiku",
  enhancement_model: "sonnet",
};

const CATALOG_CACHE_PATH = join(homedir(), ".cache", "opencode", "models-dev.json");

const CATALOG_STALE_MS = 24 * 60 * 60 * 1000;

let _catalog: Catalog | null = null;

// :::: Catalog loading :::: /////////////////////////////////

export async function loadCatalog(): Promise<Catalog> {
  if (_catalog) return _catalog;

  const isStale = (mtime: number): boolean => Date.now() - mtime > CATALOG_STALE_MS;

  try {
    const info = await stat(CATALOG_CACHE_PATH);
    if (!isStale(info.mtimeMs)) {
      _catalog = JSON.parse(await readFile(CATALOG_CACHE_PATH, "utf-8")) as Catalog;
      return _catalog;
    }
  } catch {
    /* cache read failed, proceed to fetch */
  }

  try {
    const res = await fetch("https://models.dev/api.json");
    const data: Catalog = await res.json();
    _catalog = data;
    await mkdir(dirname(CATALOG_CACHE_PATH), { recursive: true });
    await writeFile(CATALOG_CACHE_PATH, JSON.stringify(data));
    return data;
  } catch {
    try {
      _catalog = JSON.parse(await readFile(CATALOG_CACHE_PATH, "utf-8")) as Catalog;
      return _catalog;
    } catch {
      return {};
    }
  }
}

// :::: OpenCode config merge :::: //////////////////////////

function deepMerge<T extends Record<string, unknown>>(a: T, b: Partial<T>): T {
  const result = { ...a };
  for (const key of Object.keys(b) as (keyof T)[]) {
    const bVal = b[key];
    const aVal = a[key];
    if (
      bVal &&
      typeof bVal === "object" &&
      !Array.isArray(bVal) &&
      aVal &&
      typeof aVal === "object" &&
      !Array.isArray(aVal)
    ) {
      (result as Record<string, unknown>)[key as string] = deepMerge(
        aVal as Record<string, unknown>,
        bVal as Record<string, unknown>,
      );
    } else {
      (result as Record<string, unknown>)[key as string] = bVal;
    }
  }
  return result;
}

export function loadMergedConfig(): OpenCodeConfig {
  const load = (p: string): OpenCodeConfig => {
    try {
      return JSON.parse(readFileSync(p, "utf-8"));
    } catch {
      return {};
    }
  };
  const globalCfg = load(join(homedir(), ".config", "opencode", "opencode.json"));
  const projCfg = load("opencode.json");
  return deepMerge(globalCfg, projCfg);
}

export async function getConnectedProviders(): Promise<Set<string>> {
  const catalog = await loadCatalog();
  const connected = new Set<string>();

  try {
    const authPath = join(homedir(), ".local", "share", "opencode", "auth.json");
    const raw = readFileSync(authPath, "utf-8");
    const auth = JSON.parse(raw);
    for (const key of Object.keys(auth)) connected.add(key);
  } catch {
    /* auth file read failed */
  }

  for (const [pid, pdata] of Object.entries(catalog)) {
    for (const envVar of pdata.env ?? []) {
      if (process.env[envVar]) connected.add(pid);
    }
  }

  const cfg = loadMergedConfig();
  for (const p of Object.keys(cfg.provider ?? {})) connected.add(p);

  for (const d of cfg.disabled_providers ?? []) connected.delete(d);

  if (cfg.enabled_providers) {
    const wl = new Set(cfg.enabled_providers);
    for (const p of connected) {
      if (!wl.has(p)) connected.delete(p);
    }
  }

  return connected;
}

// :::: Tier resolution :::: ////////////////////////////////

export async function getModelTiers(): Promise<{
  fast: ModelEntry[];
  capable: ModelEntry[];
  powerful: ModelEntry[];
}> {
  const connected = await getConnectedProviders();
  const catalog = await loadCatalog();
  const cfg = loadMergedConfig();

  const allCandidates: CatalogCandidate[] = [];
  const entryMap = new Map<string, CatalogModel>();

  for (const pid of connected) {
    const catModels = catalog[pid]?.models ?? {};
    const customModels =
      (cfg.provider as Record<string, Record<string, unknown>>)?.[pid]?.models ?? {};
    const merged = { ...catModels, ...customModels };

    for (const [mid, m] of Object.entries(merged)) {
      const model = m as CatalogModel;
      const id = `${pid}/${mid}`;
      allCandidates.push({
        id,
        context: model?.limit?.context ?? 0,
        cost: (model?.cost?.input ?? 0) + (model?.cost?.output ?? 0),
        toolCall: model?.tool_call ?? false,
      });
      entryMap.set(id, model);
    }
  }

  const withTools = allCandidates.filter((m) => m.toolCall);
  const pool = withTools.length > 0 ? withTools : allCandidates;
  const byCost = [...pool].sort((a, b) => a.cost - b.cost);

  const third = Math.max(1, Math.ceil(byCost.length / 3));
  const fastEntries: ModelEntry[] = [];
  const capableEntries: ModelEntry[] = [];
  const powerfulEntries: ModelEntry[] = [];

  for (let i = 0; i < byCost.length; i++) {
    const c = byCost[i];
    const model = entryMap.get(c.id);
    const entry: ModelEntry = {
      id: c.id,
      providerID: c.id.split("/")[0],
      modelID: c.id.split("/")[1],
      tier: i < third ? "fast" : i < third * 2 ? "capable" : "powerful",
      context: model?.limit?.context ?? 0,
      cost: (model?.cost?.input ?? 0) + (model?.cost?.output ?? 0),
      toolCall: model?.tool_call ?? false,
    };

    if (entry.tier === "fast") fastEntries.push(entry);
    else if (entry.tier === "capable") capableEntries.push(entry);
    else powerfulEntries.push(entry);
  }

  return {
    fast: fastEntries,
    capable: capableEntries,
    powerful: powerfulEntries,
  };
}

export async function resolveShortName(shortName: string): Promise<ModelRef | undefined> {
  const tierName =
    TIER_ALIASES[shortName] ?? (TIER_CYCLE.includes(shortName) ? shortName : undefined);
  if (!tierName) return undefined;

  const tiers = await getModelTiers();
  const entries = tiers[tierName as "fast" | "capable" | "powerful"];
  if (!entries || entries.length === 0) return undefined;

  const entry = entries[0];
  return { providerID: entry.providerID, modelID: entry.modelID };
}

export function resolveModel(
  shortName: string,
  defaultName: string,
): Promise<ModelRef | undefined> {
  if (shortName === defaultName) return Promise.resolve(undefined);

  const slashIdx = shortName.indexOf("/");
  if (slashIdx > 0) {
    return Promise.resolve({
      providerID: shortName.slice(0, slashIdx),
      modelID: shortName.slice(slashIdx + 1),
    });
  }

  return resolveShortName(shortName);
}

export function resolveTier(
  value: string,
  tiers: { fast: ModelEntry[]; capable: ModelEntry[]; powerful: ModelEntry[] } | null,
): "fast" | "capable" | "powerful" | null {
  if (TIER_ALIASES[value]) {
    return TIER_ALIASES[value] as "fast" | "capable" | "powerful";
  }
  if (TIER_CYCLE.includes(value)) {
    return value as "fast" | "capable" | "powerful";
  }

  if (tiers) {
    for (const tier of TIER_CYCLE as ("fast" | "capable" | "powerful")[]) {
      if (tiers[tier].some((e) => e.id === value)) return tier;
    }
  }

  return null;
}

export function findModelEntry(
  value: string,
  tiers: { fast: ModelEntry[]; capable: ModelEntry[]; powerful: ModelEntry[] } | null,
): ModelEntry | null {
  if (!tiers) return null;
  for (const tier of TIER_CYCLE as ("fast" | "capable" | "powerful")[]) {
    const found = tiers[tier].find((e) => e.id === value);
    if (found) return found;
  }
  return null;
}
