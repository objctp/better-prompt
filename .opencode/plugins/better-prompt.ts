import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import type { Plugin } from "@opencode-ai/plugin";
import type { Event, Part } from "@opencode-ai/sdk";
import {
  type Config,
  CONFIG_DEFAULTS,
  CONFIG_PATH,
  parseConfig,
  resolveModel,
  // deno-lint-ignore no-sloppy-imports
} from "./better-prompt-models.js";

interface WatchedEventProperties {
  sessionID?: string;
  error?: unknown;
  status?: string;
  part?: { type?: string; title?: string; tool?: string };
  [key: string]: unknown;
}

interface WatchedEvent {
  type: string;
  properties?: WatchedEventProperties;
}

// :::: Types :::: /////////////////////////////////////////////

interface Usage {
  cost: number;
  inputTokens: number;
  outputTokens: number;
  cacheWriteTokens: number;
  cacheReadTokens: number;
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

const SUB_AGENTS = new Set([
  "prompt-correction",
  "prompt-translation",
  "prompt-enhancement",
  "prompt-summarisation",
]);

const FULL_REFRESH_THRESHOLD = 10;

// :::: Audit :::: /////////////////////////////////////////////

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
  appendFileSync(auditPath, `${JSON.stringify(entry)}\n`);
}

// :::: Plugin :::: ////////////////////////////////////////////

// deno-lint-ignore require-await
export const BetterPromptPlugin: Plugin = async (ctx) => {
  const { client, directory } = ctx;

  const AUDIT_DIR = join(directory, ".opencode", "better-prompt");
  const AUDIT_PATH = join(AUDIT_DIR, "audit.json");
  const DEBUG_PATH = join(AUDIT_DIR, "debug.log");

  // :::: Debug logging :::: /////////////////////////////////

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
        `[${ts}] ${message}${errStr ? ` — ${errStr}` : ""}\n`,
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
        const e = event as unknown as WatchedEvent;
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
              `[${label}] tool: ${part.title || part.tool || "unknown"}`,
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

  // :::: Agent invocation :::: //////////////////////////////

  async function invokeAgent(
    agent: string,
    text: string,
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

      const textPart = result.parts.find((p: Part) =>
        p.type === "text" && "text" in p
      );
      const resultText = textPart && "text" in textPart
        ? (textPart as { text: string }).text
        : text;

      interface PromptInfo {
        cost?: number;
        tokens?: {
          input?: number;
          output?: number;
          cache?: { write?: number; read?: number };
        };
      }
      const info = (result as Record<string, unknown>).info as
        | PromptInfo
        | undefined;
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

  // :::: Context summarisation :::: /////////////////////////////

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

  function extractTextFromParts(parts: unknown[]): string {
    if (!parts || !Array.isArray(parts)) return "";
    const texts: string[] = [];
    for (const p of parts) {
      const part = p as Record<string, unknown>;
      if (
        part?.type === "text" && typeof part.text === "string" &&
        part.text.trim()
      ) {
        texts.push(part.text.trim());
      }
    }
    return texts.join("\n");
  }

  async function summariseContext(
    sessionID: string,
    currentMessageID: string,
    config: Config,
  ): Promise<{
    summary: string;
    lastMessageID: string;
    messageCount: number;
    usage: Usage;
  }> {
    const existing = sessionContexts.get(sessionID);
    const zeroUsage: Usage = {
      cost: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheWriteTokens: 0,
      cacheReadTokens: 0,
    };

    if (!existing || existing.messageCount === 0) {
      debugLog("summarisation: skipped (first prompt)");
      return {
        summary: "",
        lastMessageID: existing?.lastMessageID ?? "",
        messageCount: 1,
        usage: zeroUsage,
      };
    }

    let messages: Record<string, unknown>[];
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
      const info = (msg?.info ?? {}) as Record<string, unknown>;
      if (!info?.id) continue;

      if (currentMessageID && info.id === currentMessageID) continue;

      if (info.agent && SUB_AGENTS.has(info.agent as string)) continue;

      const text = extractTextFromParts(msg?.parts as unknown[]);
      if (!text) continue;

      if (info.role === "user") {
        userMessages.push(text);
      } else if (info.role === "assistant") {
        lastAssistantText = text;
      }

      latestMessageID = info.id as string;
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
        config,
        model,
      );
      summary = fullResult.text;
      summarisationUsage = fullResult.usage;
      debugLog(`summarisation (full refresh): took ${Date.now() - t0}ms`);
    } else {
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
        config,
        model,
      );
      summary = incrResult.text;
      summarisationUsage = incrResult.usage;
      debugLog(`summarisation (incremental): took ${Date.now() - t0}ms`);
    }

    if (!summary?.trim()) {
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

  // :::: Pipeline :::: //////////////////////////////////////

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

    // :::: Correction //
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

    // :::: Translation //
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
          config,
          model,
        );
        addUsage(translationResult.usage);
        if (translationResult.text?.trim()) {
          working = translationResult.text;
        }
        notify("translation", "complete");
      }
    } else {
      notify("translation", "skipped");
    }

    // :::: Context summarisation (only with enhancement) //
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

    // :::: Enhancement //
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
        config,
        model,
      );
      addUsage(enhancementResult.usage);
      if (enhancementResult.text?.trim()) {
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

  // :::: Hooks :::: /////////////////////////////////////////

  return {
    // Clean up in-memory context when session ends
    // deno-lint-ignore require-await
    event: async ({ event }: { event: Event }) => {
      if (event.type === "session.deleted") {
        const props = event.properties as Record<string, unknown> | undefined;
        const sid = (props?.sessionID ??
          (props?.info as Record<string, unknown> | undefined)?.id) as
            | string
            | undefined;
        if (sid) sessionContexts.delete(sid);
      }
    },

    "chat.message": async (
      input: { sessionID: string; agent?: string; messageID?: string },
      output: { parts: Part[] },
    ) => {
      if (input.agent && SUB_AGENTS.has(input.agent)) return;

      const textPart = output.parts?.find((p: Part) =>
        p.type === "text" && "text" in p
      );
      if (!textPart || !("text" in textPart)) return;

      const originalText = textPart.text;
      if (!originalText?.trim()) return;

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

      // Verbose output
      if (config.verbose) {
        const lines: string[] = [
          `[better-prompt] ${changed ? "prompt modified" : "no changes"}`,
        ];

        if (changed) {
          const trunc = (
            s: string,
            n = 120,
          ) => (s.length > n ? `${s.slice(0, n)}...` : s);
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
              usage.cost.toFixed(
                6,
              )
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
