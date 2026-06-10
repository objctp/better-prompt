import type { Plugin } from "@opencode-ai/plugin";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// ── Types ──────────────────────────────────────────────────

interface Usage {
  cost: number;
  inputTokens: number;
  outputTokens: number;
  cacheWriteTokens: number;
  cacheReadTokens: number;
}

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
  contextSummary: string;
  usage: Usage;
}

type StageNotifier = (
  stage: string,
  status: "starting" | "complete" | "skipped",
) => void;

interface SessionContext {
  summary: string;
  lastMessageID: string;
  messageCount: number;
}

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

const SUB_AGENTS = new Set([
  "prompt-correction",
  "prompt-translation",
  "prompt-enhancement",
  "prompt-summarisation",
]);

const FULL_REFRESH_THRESHOLD = 10;

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

const CATALOG_CACHE_PATH = join(
  homedir(),
  ".cache",
  "opencode",
  "models-dev.json",
);

const CATALOG_STALE_MS = 24 * 60 * 60 * 1000;

let _catalog: Catalog | null = null;

async function loadCatalog(): Promise<Catalog> {
  if (_catalog) return _catalog;

  const fs = await import("node:fs");
  const famt = fs.promises;

  const isStale = (mtime: number): boolean =>
    Date.now() - mtime > CATALOG_STALE_MS;

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
    const authPath = join(
      homedir(),
      ".local",
      "share",
      "opencode",
      "auth.json",
    );
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
  const globalCfg = load(
    join(homedir(), ".config", "opencode", "opencode.json"),
  );
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
  const capable = byCost.length > 2
    ? byCost[Math.floor(byCost.length / 2)]
    : byCost[1] || fast;
  return { fast, capable, powerful };
}

async function resolveShortName(
  shortName: string,
): Promise<ModelRef | undefined> {
  const connected = await getConnectedProviders();
  const catalog = await loadCatalog();
  const cfg = loadMergedConfig();

  const allModels: ModelCandidate[] = [];

  for (const pid of connected) {
    const catModels = catalog[pid]?.models ?? {};
    const customModels =
      (cfg.provider as Record<string, Record<string, unknown>>)?.[pid]
        ?.models ?? {};
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
    fast: fast
      ? { providerID: fast.id.split("/")[0], modelID: fast.id.split("/")[1] }
      : null,
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
    haiku: fast
      ? { providerID: fast.id.split("/")[0], modelID: fast.id.split("/")[1] }
      : null,
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

function resolveModel(
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
    translation_model: str(
      "translation_model",
      CONFIG_DEFAULTS.translation_model,
    ),
    enhancement: bool("enhancement", CONFIG_DEFAULTS.enhancement),
    enhancement_model: str(
      "enhancement_model",
      CONFIG_DEFAULTS.enhancement_model,
    ),
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
    context: string | null;
  };
  usage: Usage;
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
      const errStr = error instanceof Error
        ? error.message
        : error
        ? String(error)
        : "";
      appendFileSync(
        DEBUG_PATH,
        `[${ts}] ${message}${errStr ? " — " + errStr : ""}\n`,
      );
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
      await client.tui.showToast({
        body: { message: `[bp] ${message}`, variant, duration },
      });
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
          debugLog(
            `[${label}] session error`,
            JSON.stringify(e.properties?.error),
          );
          break;
        }
        if (e.type === "session.status") {
          debugLog(
            `[${label}] session status: ${
              JSON.stringify(e.properties?.status)
            }`,
          );
        } else if (e.type === "message.part.updated") {
          const part = e.properties?.part;
          if (part?.type === "tool") {
            debugLog(
              `[${label}] tool: ${part.title || part.tool?.name || "unknown"}`,
            );
          }
        }
      }
    } catch (err) {
      debugLog(`[${label}] event stream error`, err);
    }
  }

  // In-memory session context: sessionID → summarised conversation context
  const sessionContexts = new Map<string, SessionContext>();

  // ── Agent invocation ───────────────────────────────────

  async function invokeAgent(
    agent: string,
    text: string,
    sessionID: string,
    config: Config,
    model?: { providerID: string; modelID: string },
  ): Promise<{ text: string; usage: Usage }> {
    try {
      const { data: child } = await client.session.create({
        body: {},
      });
      if (!child) {
        await toast(`${agent}: could not create session`, "error");
        return {
          text,
          usage: {
            cost: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheWriteTokens: 0,
            cacheReadTokens: 0,
          },
        };
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

      if (!result?.parts) {
        return {
          text,
          usage: {
            cost: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheWriteTokens: 0,
            cacheReadTokens: 0,
          },
        };
      }

      const textPart = result.parts.find((p: any) =>
        p.type === "text" && p.text
      );
      const resultText = textPart && "text" in textPart
        ? (textPart as any).text
        : text;

      const info = (result as any).info;
      const usage: Usage = {
        cost: info?.cost ?? 0,
        inputTokens: info?.tokens?.input ?? 0,
        outputTokens: info?.tokens?.output ?? 0,
        cacheWriteTokens: info?.tokens?.cache?.write ?? 0,
        cacheReadTokens: info?.tokens?.cache?.read ?? 0,
      };

      return { text: resultText, usage };
    } catch (err) {
      debugLog(`invokeAgent(${agent}) failed`, err);
      await toast(`${agent} error`, "error");
      return {
        text,
        usage: {
          cost: 0,
          inputTokens: 0,
          outputTokens: 0,
          cacheWriteTokens: 0,
          cacheReadTokens: 0,
        },
      };
    }
  }

  // ── Context summarisation ──────────────────────────────────

  function formatFullSummaryInput(
    userMessages: string[],
    lastAssistant: string,
  ): string {
    let input =
      "Summarise this conversation in 3-5 sentences. Focus on the topic, technical context, user's goal, and key decisions. Be concise.\n\n";
    for (const msg of userMessages) {
      input += `User: ${msg}\n`;
    }
    if (lastAssistant) {
      input += `\nAssistant: ${lastAssistant}\n`;
    }
    input += "\nSummary:";
    return input;
  }

  function formatIncrementalInput(
    existingSummary: string,
    userMsg: string,
    assistantMsg: string,
  ): string {
    let input =
      `Given this summary:\n${existingSummary}\n\nUpdate it with this new exchange:\nUser: ${userMsg}`;
    if (assistantMsg) {
      input += `\nAssistant: ${assistantMsg}`;
    }
    input +=
      "\n\nProvide an updated summary in 3-5 sentences. Drop stale details if no longer relevant.\n\nUpdated summary:";
    return input;
  }

  function extractTextFromParts(parts: any[]): string {
    if (!parts || !Array.isArray(parts)) return "";
    const texts: string[] = [];
    for (const p of parts) {
      if (p?.type === "text" && typeof p.text === "string" && p.text.trim()) {
        texts.push(p.text.trim());
      }
    }
    return texts.join("\n");
  }

  async function summariseContext(
    sessionID: string,
    currentMessageID: string,
    config: Config,
  ): Promise<
    {
      summary: string;
      lastMessageID: string;
      messageCount: number;
      usage: Usage;
    }
  > {
    const existing = sessionContexts.get(sessionID);
    const zeroUsage: Usage = {
      cost: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheWriteTokens: 0,
      cacheReadTokens: 0,
    };

    // First prompt short circuit: nothing to summarise yet
    if (!existing || existing.messageCount === 0) {
      debugLog("summarisation: skipped (first prompt)");
      return {
        summary: "",
        lastMessageID: existing?.lastMessageID ?? "",
        messageCount: 1,
        usage: zeroUsage,
      };
    }

    let messages: any[];
    try {
      const result = await client.session.messages({ path: { id: sessionID } });
      messages = Array.isArray(result) ? result : [];
    } catch (err) {
      debugLog("summariseContext: session.messages failed", err);
      return {
        summary: existing?.summary ?? "",
        lastMessageID: existing?.lastMessageID ?? "",
        messageCount: existing?.messageCount ?? 0,
        usage: zeroUsage,
      };
    }

    const userMessages: string[] = [];
    let lastAssistantText = "";
    let latestMessageID = existing?.lastMessageID ?? "";

    for (const msg of messages) {
      const info = msg?.info;
      if (!info?.id) continue;

      // Exclude the current message being processed
      if (currentMessageID && info.id === currentMessageID) continue;

      // Exclude sub-agent messages
      if (info.agent && SUB_AGENTS.has(info.agent)) continue;

      const text = extractTextFromParts(msg?.parts);
      if (!text) continue;

      if (info.role === "user") {
        userMessages.push(text);
      } else if (info.role === "assistant") {
        lastAssistantText = text;
      }

      latestMessageID = info.id;
    }

    if (userMessages.length === 0 && !lastAssistantText) {
      return {
        summary: existing?.summary ?? "",
        lastMessageID: (latestMessageID || existing?.lastMessageID) ?? "",
        messageCount: existing?.messageCount ?? 0,
        usage: zeroUsage,
      };
    }

    const needFullRefresh = !existing ||
      existing.messageCount >= FULL_REFRESH_THRESHOLD ||
      existing.lastMessageID === "";

    let summary: string;
    let summarisationUsage: Usage = { ...zeroUsage };

    if (needFullRefresh) {
      // Full refresh uses enhancement_model (stronger reasoning for full history)
      const model = await resolveModel(
        config.enhancement_model,
        CONFIG_DEFAULTS.enhancement_model,
      );
      const input = formatFullSummaryInput(userMessages, lastAssistantText);
      debugLog(`summarisation (${config.enhancement_model}): full refresh`);
      const t0 = Date.now();
      const fullResult = await invokeAgent(
        "prompt-summarisation",
        input,
        sessionID,
        config,
        model,
      );
      summary = fullResult.text;
      summarisationUsage = fullResult.usage;
      debugLog(`summarisation (full refresh): took ${Date.now() - t0}ms`);
    } else {
      // Incremental uses correction_model (cheaper, small input)
      const model = await resolveModel(
        config.correction_model,
        CONFIG_DEFAULTS.correction_model,
      );
      const newUserMsg = userMessages[userMessages.length - 1] || "";
      const input = formatIncrementalInput(
        existing.summary,
        newUserMsg,
        lastAssistantText,
      );
      debugLog(`summarisation (${config.correction_model}): incremental`);
      const t0 = Date.now();
      const incrResult = await invokeAgent(
        "prompt-summarisation",
        input,
        sessionID,
        config,
        model,
      );
      summary = incrResult.text;
      summarisationUsage = incrResult.usage;
      debugLog(`summarisation (incremental): took ${Date.now() - t0}ms`);
    }

    if (!summary || !summary.trim()) {
      debugLog("summarisation: agent returned empty, keeping existing summary");
      summary = existing?.summary ?? "";
    }

    return {
      summary: summary.trim(),
      lastMessageID: latestMessageID,
      messageCount: existing ? existing.messageCount + 1 : 2,
      usage: summarisationUsage,
    };
  }

  // ── Pipeline ───────────────────────────────────────────

  async function runPipeline(
    text: string,
    sessionID: string,
    config: Config,
    notify: StageNotifier,
    currentMessageID?: string,
  ): Promise<PipelineResult> {
    let working = text;
    let corrected: string | null = null;
    let detectedLanguage: string | null = null;
    let mistakes: Array<{
      type: string;
      original: string;
      correction: string;
    }> = [];
    const totalUsage: Usage = {
      cost: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheWriteTokens: 0,
      cacheReadTokens: 0,
    };

    function addUsage(u: {
      cost: number;
      inputTokens: number;
      outputTokens: number;
      cacheWriteTokens: number;
      cacheReadTokens: number;
    }) {
      totalUsage.cost += u.cost;
      totalUsage.inputTokens += u.inputTokens;
      totalUsage.outputTokens += u.outputTokens;
      totalUsage.cacheWriteTokens += u.cacheWriteTokens;
      totalUsage.cacheReadTokens += u.cacheReadTokens;
    }

    const { correction, translation, enhancement } = config;
    const anyStage = correction || translation || enhancement;
    if (!anyStage) {
      return {
        result: text,
        corrected: null,
        detectedLanguage: null,
        mistakes: [],
        contextSummary: "",
        usage: totalUsage,
      };
    }

    const skipCorrection = enhancement && !translation && correction;
    const correctionOnlyForLanguage = translation && !correction;

    // ── Correction ──
    if (!skipCorrection && (correction || correctionOnlyForLanguage)) {
      notify("correction", "starting");
      const t0 = Date.now();
      const model = await resolveModel(
        config.correction_model,
        CONFIG_DEFAULTS.correction_model,
      );
      debugLog(`correction: resolveModel took ${Date.now() - t0}ms`);
      const t1 = Date.now();
      const correctionResult = await invokeAgent(
        "prompt-correction",
        working,
        sessionID,
        config,
        model,
      );
      addUsage(correctionResult.usage);
      const raw = correctionResult.text;
      debugLog(
        `correction: invokeAgent took ${Date.now() - t1}ms (total so far ${
          Date.now() - t0
        }ms)`,
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
        debugLog(
          `correction agent returned non-JSON (first 200 chars)`,
          raw?.substring(0, 200),
        );
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
        const translationResult = await invokeAgent(
          "prompt-translation",
          working,
          sessionID,
          config,
          model,
        );
        addUsage(translationResult.usage);
        if (translationResult.text && translationResult.text.trim()) {
          working = translationResult.text;
        }
        notify("translation", "complete");
      }
    } else {
      notify("translation", "skipped");
    }

    // ── Context summarisation (only with enhancement) ──
    let contextSummary = "";
    if (enhancement) {
      notify("context", "starting");
      const ctxResult = await summariseContext(
        sessionID,
        currentMessageID ?? "",
        config,
      );
      contextSummary = ctxResult.summary;
      addUsage(ctxResult.usage);
      sessionContexts.set(sessionID, ctxResult);
      notify("context", "complete");
    }

    // ── Enhancement ──
    if (enhancement) {
      notify("enhancement", "starting");
      let enhanceInput = "";
      if (contextSummary) {
        enhanceInput += `Conversation context: ${contextSummary}\n\n`;
      }
      enhanceInput += working;

      const model = await resolveModel(
        config.enhancement_model,
        CONFIG_DEFAULTS.enhancement_model,
      );
      const enhancementResult = await invokeAgent(
        "prompt-enhancement",
        enhanceInput,
        sessionID,
        config,
        model,
      );
      addUsage(enhancementResult.usage);
      if (enhancementResult.text && enhancementResult.text.trim()) {
        working = enhancementResult.text;
      }
      notify("enhancement", "complete");
    } else {
      notify("enhancement", "skipped");
    }

    return {
      result: working,
      corrected,
      detectedLanguage,
      mistakes,
      contextSummary,
      usage: totalUsage,
    };
  }

  // ── Hooks ──────────────────────────────────────────────

  return {
    // Clean up in-memory context when session ends
    event: async ({ event }: { event: any }) => {
      if (event.type === "session.deleted") {
        const sid = event.properties?.sessionID ?? event.properties?.info?.id;
        if (sid) sessionContexts.delete(sid);
      }
    },

    // Primary pipeline — intercept user messages only
    "chat.message": async (input: any, output: any) => {
      if (input.agent && SUB_AGENTS.has(input.agent)) return;

      // Extract text from parts
      const textPart = output.parts?.find((p: any) =>
        p.type === "text" && p.text
      );
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
      let contextSummary = "";
      let usage: Usage = {
        cost: 0,
        inputTokens: 0,
        outputTokens: 0,
        cacheWriteTokens: 0,
        cacheReadTokens: 0,
      };

      try {
        const pipelineResult = await runPipeline(
          originalText,
          input.sessionID,
          config,
          notify,
          input.messageID,
        );
        result = pipelineResult.result;
        corrected = pipelineResult.corrected;
        detectedLanguage = pipelineResult.detectedLanguage;
        mistakes = pipelineResult.mistakes;
        contextSummary = pipelineResult.contextSummary;
        usage = pipelineResult.usage;
      } catch (err) {
        debugLog("pipeline failed", err);
        await toast("Pipeline error — original prompt sent", "error", 5000);
        return;
      }

      // Completion toast
      const changed = result !== originalText;
      await toast(
        changed ? "Prompt modified" : "No changes",
        changed ? "success" : "info",
        3000,
      );

      // Replace text
      textPart.text = result;

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
            context: config.enhancement ? config.correction_model : null,
          },
          usage,
        };
        writeAudit(AUDIT_PATH, entry);
      }

      // Verbose output — write to debug log (cannot push new parts
      // without messageID, causes SchemaError in OpenCode >=1.16)
      if (config.verbose) {
        const lines: string[] = [
          `[better-prompt] ${changed ? "prompt modified" : "no changes"}`,
        ];

        if (changed) {
          const trunc = (
            s: string,
            n = 120,
          ) => (s.length > n ? s.slice(0, n) + "..." : s);
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
          config.enhancement ? "context ✓" : "",
          config.enhancement ? "enhancement ✓" : "enhancement —",
        ].filter(Boolean);
        lines.push(`Pipeline: ${stages.join(" | ")}`);

        if (contextSummary) {
          lines.push(`Context: ${contextSummary.substring(0, 200)}`);
        }

        if (usage.cost > 0) {
          lines.push(
            `Cost: $${
              usage.cost.toFixed(6)
            } | Tokens: ${usage.inputTokens}in ${usage.outputTokens}out (${usage.cacheWriteTokens}cw ${usage.cacheReadTokens}cr)`,
          );
        }

        debugLog(lines.join("\n"));
      }
    },
  };
};

export default {
  id: "better-prompt",
  server: BetterPromptPlugin,
};
