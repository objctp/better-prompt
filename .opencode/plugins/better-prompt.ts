import type { Plugin } from "@opencode-ai/plugin";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// ── Types ──────────────────────────────────────────────────

interface Config {
  enabled: boolean;
  correction: boolean;
  correction_model: string;
  translation: boolean;
  translation_model: string;
  enhancement: boolean;
  enhancement_model: string;
  audit: boolean;
  verbose: boolean;
}

interface PipelineResult {
  result: string;
  corrected: string | null;
  detectedLanguage: string | null;
  mistakes: Array<{ type: string; original: string; correction: string }>;
}

type StageNotifier = (stage: string, status: "starting" | "complete" | "skipped") => void;

const CONFIG_DEFAULTS: Config = {
  enabled: true,
  correction: true,
  correction_model: "haiku",
  translation: false,
  translation_model: "haiku",
  enhancement: false,
  enhancement_model: "sonnet",
  audit: true,
  verbose: false,
};

const CONTEXT_WINDOW = 5;

// ── Model resolution ──────────────────────────────────────
// Agents inherit the session's current model by default.
// When a user sets a model in better-prompt.local.md, resolveModel()
// maps it to a { providerID, modelID } pair that opencode can use.
//
// Resolution order:
//   1. provider/model format (e.g. "opencode-go/deepseek-v4-flash") → used directly
//   2. Short-name aliases ("fast", "capable", "powerful") → resolved
//      dynamically from the user's connected providers via auth.json,
//      environment variables, config, and the models.dev catalogue
//   3. Legacy names ("haiku", "sonnet", "opus") → mapped to short-name
//      aliases for backward compatibility
//
// The catalogue is fetched once from models.dev and cached locally for
// 24 hours. Provider discovery mirrors opencode's own logic:
// auth.json keys + env vars from catalogue + custom provider config,
// minus disabled_providers, intersected with enabled_providers.

type ModelRef = { providerID: string; modelID: string };

interface CatalogModel {
  id: string;
  name?: string;
  tool_call?: boolean;
  limit?: { context?: number; output?: number };
  cost?: { input?: number; output?: number };
}

interface CatalogProvider {
  id: string;
  name?: string;
  env?: string[];
  models?: Record<string, CatalogModel>;
}

type Catalog = Record<string, CatalogProvider>;

const CATALOG_CACHE_PATH = join(homedir(), ".cache", "opencode", "models-dev.json");

const CATALOG_STALE_MS = 24 * 60 * 60 * 1000;

let _catalog: Catalog | null = null;

async function loadCatalog(): Promise<Catalog> {
  if (_catalog) return _catalog;

  const fs = await import("node:fs");
  const famt = fs.promises;

  const isStale = (mtime: number): boolean => Date.now() - mtime > CATALOG_STALE_MS;

  try {
    const stat = await famt.stat(CATALOG_CACHE_PATH);
    if (!isStale(stat.mtimeMs)) {
      const raw = await famt.readFile(CATALOG_CACHE_PATH, "utf-8");
      _catalog = JSON.parse(raw) as Catalog;
      return _catalog;
    }
  } catch {}

  try {
    const res = await fetch("https://models.dev/api.json");
    const data: Catalog = await res.json();
    _catalog = data;
    await famt.mkdir(join(CATALOG_CACHE_PATH, ".."), { recursive: true });
    await famt.writeFile(CATALOG_CACHE_PATH, JSON.stringify(data));
    return data;
  } catch {
    try {
      const raw = await famt.readFile(CATALOG_CACHE_PATH, "utf-8");
      _catalog = JSON.parse(raw) as Catalog;
      return _catalog;
    } catch {
      return {};
    }
  }
}

interface OpenCodeConfig {
  disabled_providers?: string[];
  enabled_providers?: string[];
  provider?: Record<string, { models?: Record<string, unknown> }>;
  [key: string]: unknown;
}

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

async function getConnectedProviders(): Promise<Set<string>> {
  const catalog = await loadCatalog();
  const connected = new Set<string>();

  // 1. Auth.json credentials
  try {
    const authPath = join(homedir(), ".local", "share", "opencode", "auth.json");
    const raw = readFileSync(authPath, "utf-8");
    const auth = JSON.parse(raw);
    for (const key of Object.keys(auth)) connected.add(key);
  } catch {}

  // 2. Environment variables listed in catalogue
  for (const [pid, pdata] of Object.entries(catalog)) {
    for (const envVar of pdata.env ?? []) {
      if (process.env[envVar]) connected.add(pid);
    }
  }

  // 3. Custom providers from opencode config
  const cfg = loadMergedConfig();
  for (const p of Object.keys(cfg.provider ?? {})) connected.add(p);

  // 4. Apply disabled_providers
  for (const d of cfg.disabled_providers ?? []) connected.delete(d);

  // 5. Apply enabled_providers whitelist
  if (cfg.enabled_providers) {
    const wl = new Set(cfg.enabled_providers);
    for (const p of connected) {
      if (!wl.has(p)) connected.delete(p);
    }
  }

  return connected;
}

function loadMergedConfig(): OpenCodeConfig {
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

interface ModelCandidate {
  id: string;
  context: number;
  cost: number;
  toolCall: boolean;
}

function partitionByRole(models: ModelCandidate[]): {
  fast: ModelCandidate | null;
  capable: ModelCandidate | null;
  powerful: ModelCandidate | null;
} {
  const withTools = models.filter((m) => m.toolCall);
  const pool = withTools.length > 0 ? withTools : models;
  const byCost = [...pool].sort((a, b) => a.cost - b.cost);
  const byCtx = [...pool].sort((a, b) => b.context - a.context);

  const fast = byCost[0] || null;
  const powerful = byCtx[0] || null;
  const capable = byCost.length > 2 ? byCost[Math.floor(byCost.length / 2)] : byCost[1] || fast;
  return { fast, capable, powerful };
}

async function resolveShortName(shortName: string): Promise<ModelRef | undefined> {
  const connected = await getConnectedProviders();
  const catalog = await loadCatalog();
  const cfg = loadMergedConfig();

  const allModels: ModelCandidate[] = [];

  for (const pid of connected) {
    const catModels = catalog[pid]?.models ?? {};
    const customModels =
      (cfg.provider as Record<string, Record<string, unknown>>)?.[pid]?.models ?? {};
    const merged = { ...catModels, ...customModels };

    for (const [mid, m] of Object.entries(merged)) {
      const model = m as CatalogModel;
      allModels.push({
        id: `${pid}/${mid}`,
        context: model?.limit?.context ?? 0,
        cost: (model?.cost?.input ?? 0) + (model?.cost?.output ?? 0),
        toolCall: model?.tool_call ?? false,
      });
    }
  }

  const { fast, capable, powerful } = partitionByRole(allModels);

  const ALIASES: Record<string, ModelRef | null> = {
    fast: fast ? { providerID: fast.id.split("/")[0], modelID: fast.id.split("/")[1] } : null,
    capable: capable
      ? {
          providerID: capable.id.split("/")[0],
          modelID: capable.id.split("/")[1],
        }
      : null,
    powerful: powerful
      ? {
          providerID: powerful.id.split("/")[0],
          modelID: powerful.id.split("/")[1],
        }
      : null,
    haiku: fast ? { providerID: fast.id.split("/")[0], modelID: fast.id.split("/")[1] } : null,
    sonnet: capable
      ? {
          providerID: capable.id.split("/")[0],
          modelID: capable.id.split("/")[1],
        }
      : null,
    opus: powerful
      ? {
          providerID: powerful.id.split("/")[0],
          modelID: powerful.id.split("/")[1],
        }
      : null,
  };

  return ALIASES[shortName] ?? undefined;
}

function resolveModel(shortName: string, defaultName: string): Promise<ModelRef | undefined> {
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

// ── Config parsing ─────────────────────────────────────────

function parseConfig(configPath: string): Config {
  if (!existsSync(configPath)) return { ...CONFIG_DEFAULTS };

  const raw = readFileSync(configPath, "utf8");
  const fmMatch = raw.match(/^---\n([\s\S]*?)\n---/);
  if (!fmMatch) return { ...CONFIG_DEFAULTS };

  const fm = fmMatch[1];
  const get = (key: string): string | undefined => {
    const m = fm.match(new RegExp(`^${key}:\\s*(.+)$`, "m"));
    return m ? m[1].trim() : undefined;
  };

  const bool = (key: string, fallback: boolean): boolean => {
    const v = get(key);
    return v !== undefined ? v === "true" : fallback;
  };

  const str = (key: string, fallback: string): string => {
    const v = get(key);
    return v !== undefined ? v : fallback;
  };

  return {
    enabled: bool("enabled", CONFIG_DEFAULTS.enabled),
    correction: bool("correction", CONFIG_DEFAULTS.correction),
    correction_model: str("correction_model", CONFIG_DEFAULTS.correction_model),
    translation: bool("translation", CONFIG_DEFAULTS.translation),
    translation_model: str("translation_model", CONFIG_DEFAULTS.translation_model),
    enhancement: bool("enhancement", CONFIG_DEFAULTS.enhancement),
    enhancement_model: str("enhancement_model", CONFIG_DEFAULTS.enhancement_model),
    audit: bool("audit", CONFIG_DEFAULTS.audit),
    verbose: bool("verbose", CONFIG_DEFAULTS.verbose),
  };
}

function updateConfig(configPath: string, updates: Partial<Config>): void {
  let raw = "";
  if (existsSync(configPath)) {
    raw = readFileSync(configPath, "utf8");
  }

  let fm = "";
  let body = "";
  const fmMatch = raw.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (fmMatch) {
    fm = fmMatch[1];
    body = fmMatch[2];
  }

  for (const [key, value] of Object.entries(updates)) {
    if (value === undefined) continue;
    const line = `${key}: ${value}`;
    const regex = new RegExp(`^${key}: .+$`, "m");
    if (regex.test(fm)) {
      fm = fm.replace(regex, line);
    } else {
      fm += `\n${line}`;
    }
  }

  writeFileSync(configPath, `---\n${fm}\n---\n${body}`);
}

// ── Audit ──────────────────────────────────────────────────

interface AuditEntry {
  date: string;
  prompt: string;
  language: string | null;
  corrected: string | null;
  enhanced: string | null;
  "mistake-nature": string[];
  mistakes: Array<{ type: string; original: string; correction: string }>;
  models: {
    correction: string | null;
    translation: string | null;
    enhancement: string | null;
  };
}

function writeAudit(auditPath: string, entry: AuditEntry): void {
  mkdirSync(join(auditPath, ".."), { recursive: true });
  appendFileSync(auditPath, JSON.stringify(entry) + "\n");
}

// ── Plugin ─────────────────────────────────────────────────

export const BetterPromptPlugin: Plugin = async (ctx) => {
  const { client, directory } = ctx;

  const CONFIG_PATH = join(
    process.env.HOME || "~",
    ".config",
    "opencode",
    "better-prompt.local.md",
  );
  const AUDIT_DIR = join(directory, ".opencode", "better-prompt");
  const AUDIT_PATH = join(AUDIT_DIR, "audit.json");
  const DEBUG_PATH = join(AUDIT_DIR, "debug.log");

  // ── Debug logging ──────────────────────────────────────

  function debugLog(message: string, error?: unknown): void {
    try {
      mkdirSync(AUDIT_DIR, { recursive: true });
      const ts = new Date().toISOString();
      const errStr = error instanceof Error ? error.message : error ? String(error) : "";
      appendFileSync(DEBUG_PATH, `[${ts}] ${message}${errStr ? " — " + errStr : ""}\n`);
    } catch {
      // best effort
    }
  }

  async function toast(
    message: string,
    variant: "info" | "success" | "error" = "info",
    duration = 4000,
  ): Promise<void> {
    try {
      await client.tui.showToast({ body: { message: `[bp] ${message}`, variant, duration } });
    } catch {
      // TUI may not be available in headless/CLI mode
    }
  }

  async function watchSessionEvents(
    childSessionID: string,
    label: string,
    config: Config,
  ): Promise<void> {
    if (!config.verbose) return;
    try {
      const eventStream = await client.event.subscribe();
      for await (const event of eventStream.stream) {
        const e = event as any;
        const sid = e.properties?.sessionID;
        if (sid !== childSessionID) continue;

        if (e.type === "session.idle") {
          debugLog(`[${label}] session idle`);
          break;
        }
        if (e.type === "session.error") {
          debugLog(`[${label}] session error`, JSON.stringify(e.properties?.error));
          break;
        }
        if (e.type === "session.status") {
          debugLog(`[${label}] session status: ${JSON.stringify(e.properties?.status)}`);
        } else if (e.type === "message.part.updated") {
          const part = e.properties?.part;
          if (part?.type === "tool") {
            debugLog(`[${label}] tool: ${part.title || part.tool?.name || "unknown"}`);
          }
        }
      }
    } catch (err) {
      debugLog(`[${label}] event stream error`, err);
    }
  }

  // In-memory prior context: sessionID → sliding window of enhanced prompts
  const priorContexts = new Map<string, string[]>();

  // ── Agent invocation ───────────────────────────────────

  async function invokeAgent(
    agent: string,
    text: string,
    sessionID: string,
    config: Config,
    model?: { providerID: string; modelID: string },
  ): Promise<string> {
    try {
      const { data: child } = await client.session.create({
        body: {},
      });
      if (!child) {
        await toast(`${agent}: could not create session`, "error");
        return text;
      }

      watchSessionEvents(child.id, agent, config).catch(() => {});

      const { data: result } = await client.session.prompt({
        body: {
          agent,
          parts: [{ type: "text", text }],
          ...(model && { model }),
        },
        path: { id: child.id },
      });

      if (!result?.parts) return text;

      const textPart = result.parts.find((p: any) => p.type === "text" && p.text);
      return textPart && "text" in textPart ? (textPart as any).text : text;
    } catch (err) {
      debugLog(`invokeAgent(${agent}) failed`, err);
      await toast(`${agent} error`, "error");
      return text;
    }
  }

  // ── Pipeline ───────────────────────────────────────────

  async function runPipeline(
    text: string,
    sessionID: string,
    config: Config,
    notify: StageNotifier,
  ): Promise<PipelineResult> {
    let working = text;
    let corrected: string | null = null;
    let detectedLanguage: string | null = null;
    let mistakes: Array<{
      type: string;
      original: string;
      correction: string;
    }> = [];

    const { correction, translation, enhancement } = config;
    const anyStage = correction || translation || enhancement;
    if (!anyStage)
      return {
        result: text,
        corrected: null,
        detectedLanguage: null,
        mistakes: [],
      };

    const skipCorrection = enhancement && !translation && correction;
    const correctionOnlyForLanguage = translation && !correction;

    // ── Correction ──
    if (!skipCorrection && (correction || correctionOnlyForLanguage)) {
      notify("correction", "starting");
      const t0 = Date.now();
      const model = await resolveModel(config.correction_model, CONFIG_DEFAULTS.correction_model);
      debugLog(`correction: resolveModel took ${Date.now() - t0}ms`);
      const t1 = Date.now();
      const raw = await invokeAgent("prompt-correction", working, sessionID, config, model);
      debugLog(
        `correction: invokeAgent took ${Date.now() - t1}ms (total so far ${Date.now() - t0}ms)`,
      );

      let correctionFailed = false;
      try {
        const fenceMatch = raw.match(/```(?:json)?\s*\n?([\s\S]*?)\n?\s*```/);
        const cleaned = fenceMatch ? fenceMatch[1].trim() : raw.trim();
        const parsed = JSON.parse(cleaned);
        if (parsed.corrected && typeof parsed.corrected === "string") {
          if (correctionOnlyForLanguage) {
            detectedLanguage = parsed.language || null;
          } else {
            working = parsed.corrected;
            corrected = parsed.corrected;
            detectedLanguage = parsed.language || null;
            if (Array.isArray(parsed.mistakes)) {
              mistakes = parsed.mistakes;
            }
          }
        } else {
          correctionFailed = true;
          debugLog(`correction agent returned JSON without "corrected" field`);
        }
      } catch {
        correctionFailed = true;
        debugLog(`correction agent returned non-JSON (first 200 chars)`, raw?.substring(0, 200));
      }
      if (correctionFailed) {
        await toast("Correction failed — using original prompt", "error", 3000);
      }
      notify("correction", "complete");
    } else {
      notify("correction", "skipped");
    }

    // ── Translation ──
    if (translation) {
      if (detectedLanguage === "en") {
        notify("translation", "skipped");
      } else {
        notify("translation", "starting");
        const model = await resolveModel(
          config.translation_model,
          CONFIG_DEFAULTS.translation_model,
        );
        const translated = await invokeAgent(
          "prompt-translation",
          working,
          sessionID,
          config,
          model,
        );
        if (translated && translated.trim()) working = translated;
        notify("translation", "complete");
      }
    } else {
      notify("translation", "skipped");
    }

    // ── Enhancement ──
    if (enhancement) {
      notify("enhancement", "starting");
      const ctx = priorContexts.get(sessionID) ?? [];
      let enhanceInput = "";
      if (ctx.length > 0) {
        enhanceInput += "Prior prompts in this session:\n";
        for (const p of ctx) {
          enhanceInput += `- ${p}\n`;
        }
        enhanceInput += "\n";
      }
      enhanceInput += working;

      const model = await resolveModel(config.enhancement_model, CONFIG_DEFAULTS.enhancement_model);
      const enhanced = await invokeAgent(
        "prompt-enhancement",
        enhanceInput,
        sessionID,
        config,
        model,
      );
      if (enhanced && enhanced.trim()) working = enhanced;
      notify("enhancement", "complete");
    } else {
      notify("enhancement", "skipped");
    }

    return { result: working, corrected, detectedLanguage, mistakes };
  }

  // ── Hooks ──────────────────────────────────────────────

  return {
    // Clean up in-memory context when session ends
    event: async ({ event }: { event: any }) => {
      if (event.type === "session.deleted") {
        const sid = event.properties?.sessionID ?? event.properties?.info?.id;
        if (sid) priorContexts.delete(sid);
      }
    },

    // Primary pipeline — intercept user messages only
    "chat.message": async (input: any, output: any) => {
      const subAgents = new Set(["prompt-correction", "prompt-translation", "prompt-enhancement"]);
      if (input.agent && subAgents.has(input.agent)) return;

      // Extract text from parts
      const textPart = output.parts?.find((p: any) => p.type === "text" && p.text);
      if (!textPart || !("text" in textPart)) return;

      const originalText = textPart.text;
      if (!originalText || !originalText.trim()) return;

      const config = parseConfig(CONFIG_PATH);
      if (!config.enabled) return;

      // Show initial toast to fix "frozen" UX
      await toast("Processing prompt...", "info", 15000);

      // Stage notifier — shows toast at each pipeline stage start
      const notify: StageNotifier = (stage, status) => {
        if (status === "starting") {
          toast(`${stage}...`, "info", 10000).catch(() => {});
        }
        debugLog(`[pipeline] ${stage} ${status}`);
      };

      let result: string;
      let corrected: string | null;
      let detectedLanguage: string | null;
      let mistakes: PipelineResult["mistakes"];

      try {
        const pipelineResult = await runPipeline(originalText, input.sessionID, config, notify);
        result = pipelineResult.result;
        corrected = pipelineResult.corrected;
        detectedLanguage = pipelineResult.detectedLanguage;
        mistakes = pipelineResult.mistakes;
      } catch (err) {
        debugLog("pipeline failed", err);
        await toast("Pipeline error — original prompt sent", "error", 5000);
        return;
      }

      // Completion toast
      const changed = result !== originalText;
      await toast(changed ? "Prompt modified" : "No changes", changed ? "success" : "info", 3000);

      // Replace text
      textPart.text = result;

      // Update in-memory prior context
      const ctx = priorContexts.get(input.sessionID) ?? [];
      ctx.push(result);
      if (ctx.length > CONTEXT_WINDOW) ctx.shift();
      priorContexts.set(input.sessionID, ctx);

      // Audit
      if (config.audit) {
        const mistakeNature = [...new Set(mistakes.map((m) => m.type))];
        const entry: AuditEntry = {
          date: new Date().toISOString(),
          prompt: originalText,
          language: detectedLanguage,
          corrected: config.correction ? corrected : null,
          enhanced: config.enhancement ? result : null,
          "mistake-nature": mistakeNature,
          mistakes,
          models: {
            correction: config.correction ? config.correction_model : null,
            translation: config.translation ? config.translation_model : null,
            enhancement: config.enhancement ? config.enhancement_model : null,
          },
        };
        writeAudit(AUDIT_PATH, entry);
      }

      // Verbose output — write to debug log (cannot push new parts
      // without messageID, causes SchemaError in OpenCode >=1.16)
      if (config.verbose) {
        const lines: string[] = [`[better-prompt] ${changed ? "prompt modified" : "no changes"}`];

        if (changed) {
          const trunc = (s: string, n = 120) => (s.length > n ? s.slice(0, n) + "..." : s);
          lines.push(`Original:  "${trunc(originalText)}"`);
          lines.push(`Processed: "${trunc(result)}"`);
        }

        if (detectedLanguage) {
          lines.push(`Language: ${detectedLanguage}`);
        }

        if (mistakes.length > 0) {
          lines.push(`Mistakes (${mistakes.length}):`);
          for (const m of mistakes) {
            lines.push(`  - ${m.type}: "${m.original}" → "${m.correction}"`);
          }
        }

        const stages: string[] = [
          config.correction ? "correction ✓" : "correction —",
          config.translation ? "translation ✓" : "translation —",
          config.enhancement ? "enhancement ✓" : "enhancement —",
        ];
        lines.push(`Pipeline: ${stages.join(" | ")}`);

        debugLog(lines.join("\n"));
      }
    },
  };
};

export default {
  id: "better-prompt",
  server: BetterPromptPlugin,
};
