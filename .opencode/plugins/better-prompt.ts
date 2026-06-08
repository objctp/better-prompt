import type { Plugin } from "@opencode-ai/plugin";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
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

const AGENT_NAMES = new Set([
  "prompt-correction",
  "prompt-translation",
  "prompt-enhancement",
]);

const CONTEXT_WINDOW = 5;

// ── Model resolution ──────────────────────────────────────
// Agents inherit the session's current model by default.
// MODEL_MAP resolves short names from config overrides to provider/model IDs.
// Users set their preferred models in better-prompt.local.md — the plugin
// only passes an explicit model when a non-default value is configured.

const MODEL_MAP: Record<string, { providerID: string; modelID: string }> = {
  haiku: { providerID: "anthropic", modelID: "claude-haiku-4-20250514" },
  sonnet: { providerID: "anthropic", modelID: "claude-sonnet-4-20250514" },
  opus: { providerID: "anthropic", modelID: "claude-opus-4-20250514" },
};

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

  // In-memory prior context: sessionID → sliding window of enhanced prompts
  const priorContexts = new Map<string, string[]>();

  // ── Agent invocation ───────────────────────────────────

  async function invokeAgent(
    agent: string,
    text: string,
    sessionID: string,
    model?: { providerID: string; modelID: string },
  ): Promise<string> {
    try {
      // Create independent session (no parentID) so the agent doesn't
      // inherit conversation history that confuses the correction prompt
      const { data: child } = await client.session.create({
        body: {},
      });
      if (!child) return text;

      const { data: result } = await client.session.prompt({
        body: {
          agent,
          parts: [{ type: "text", text }],
          ...(model && { model }),
        },
        path: { id: child.id },
      });

      if (!result?.parts) return text;

      const textPart = result.parts.find(
        (p: any) => p.type === "text" && p.text,
      );
      return textPart && "text" in textPart ? (textPart as any).text : text;
    } catch (err) {
      debugLog(`invokeAgent(${agent}) failed`, err);
      return text;
    }
  }

  function resolveModel(
    shortName: string,
    defaultName: string,
  ): { providerID: string; modelID: string } | undefined {
    // Only resolve when user explicitly changed the model from default.
    // When unchanged, return undefined → agent inherits session model.
    if (shortName === defaultName) return undefined;
    // Try MODEL_MAP first (short names like haiku/sonnet/opus)
    const mapped = MODEL_MAP[shortName];
    if (mapped) return mapped;
    // Otherwise treat as providerID/modelID format (e.g. "zai-coding-plan/glm-4.5-air")
    const slashIdx = shortName.indexOf("/");
    if (slashIdx > 0) {
      return {
        providerID: shortName.slice(0, slashIdx),
        modelID: shortName.slice(slashIdx + 1),
      };
    }
    return undefined;
  }

  // ── Pipeline ───────────────────────────────────────────

  async function runPipeline(
    text: string,
    sessionID: string,
    config: Config,
  ): Promise<PipelineResult> {
    let working = text;
    let corrected: string | null = null;
    let detectedLanguage: string | null = null;
    let mistakes: Array<{ type: string; original: string; correction: string }> = [];

    const { correction, translation, enhancement } = config;
    const anyStage = correction || translation || enhancement;
    if (!anyStage) return { result: text, corrected: null, detectedLanguage: null, mistakes: [] };

    // When enhancement is enabled without translation, correction is redundant —
    // enhancement subsumes grammar/spelling fixes.
    const skipCorrection = enhancement && !translation && correction;
    // When translation is enabled without correction, still run correction
    // to detect language — then discard corrections.
    const correctionOnlyForLanguage = translation && !correction;

    // ── Correction ──
    if (!skipCorrection && (correction || correctionOnlyForLanguage)) {
      const model = resolveModel(config.correction_model, CONFIG_DEFAULTS.correction_model);
      const raw = await invokeAgent("prompt-correction", working, sessionID, model);

      try {
        // Strip markdown code fences if the model wrapped the JSON
        const fenceMatch = raw.match(/```(?:json)?\s*\n?([\s\S]*?)\n?\s*```/);
        const cleaned = fenceMatch ? fenceMatch[1].trim() : raw.trim();
        // Agent returns JSON: { corrected, language, mistakes }
        const parsed = JSON.parse(cleaned);
        if (parsed.corrected && typeof parsed.corrected === "string") {
          if (correctionOnlyForLanguage) {
            // Discard corrections — keep only language detection
            detectedLanguage = parsed.language || null;
          } else {
            working = parsed.corrected;
            corrected = parsed.corrected;
            detectedLanguage = parsed.language || null;
            if (Array.isArray(parsed.mistakes)) {
              mistakes = parsed.mistakes;
            }
          }
        }
      } catch {
        // Agent returned non-JSON — keep original text unchanged
        debugLog(`correction agent returned non-JSON (first 200 chars)`, raw?.substring(0, 200));
      }
    }

    // ── Translation ──
    if (translation) {
      if (detectedLanguage === "en") {
        // Already English — skip translation
      } else {
        const model = resolveModel(config.translation_model, CONFIG_DEFAULTS.translation_model);
        const translated = await invokeAgent("prompt-translation", working, sessionID, model);
        if (translated && translated.trim()) working = translated;
      }
    }

    // ── Enhancement ──
    if (enhancement) {
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

      const model = resolveModel(config.enhancement_model, CONFIG_DEFAULTS.enhancement_model);
      const enhanced = await invokeAgent("prompt-enhancement", enhanceInput, sessionID, model);
      if (enhanced && enhanced.trim()) working = enhanced;
    }

    return { result: working, corrected, detectedLanguage, mistakes };
  }

  // ── Hooks ──────────────────────────────────────────────

  return {
    // Clean up in-memory context when session ends
    event: async ({ event }: { event: any }) => {
      if (event.type === "session.deleted") {
        const sid =
          event.properties?.sessionID ?? event.properties?.info?.id;
        if (sid) priorContexts.delete(sid);
      }
    },

    // Primary pipeline — intercept user messages
    "chat.message": async (input: any, output: any) => {
      // Recursion guard: skip processing for our own agents
      if (input.agent && AGENT_NAMES.has(input.agent)) return;

      // Extract text from parts
      const textPart = output.parts?.find(
        (p: any) => p.type === "text" && p.text,
      );
      if (!textPart || !("text" in textPart)) return;

      const originalText = textPart.text;
      if (!originalText || !originalText.trim()) return;

      const config = parseConfig(CONFIG_PATH);
      if (!config.enabled) return;

      // Run pipeline
      const { result, corrected, detectedLanguage, mistakes } =
        await runPipeline(originalText, input.sessionID, config);

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
        const changed = result !== originalText;
        const lines: string[] = [
          `[better-prompt] ${changed ? "prompt modified" : "no changes"}`,
        ];

        if (changed) {
          const trunc = (s: string, n = 120) =>
            s.length > n ? s.slice(0, n) + "..." : s;
          lines.push(`Original:  "${trunc(originalText)}"`);
          lines.push(`Processed: "${trunc(result)}"`);
        }

        if (detectedLanguage) {
          lines.push(`Language: ${detectedLanguage}`);
        }

        if (mistakes.length > 0) {
          lines.push(`Mistakes (${mistakes.length}):`);
          for (const m of mistakes) {
            lines.push(
              `  - ${m.type}: "${m.original}" → "${m.correction}"`,
            );
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
