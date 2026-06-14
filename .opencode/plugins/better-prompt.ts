import { appendFileSync, mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { Plugin } from "@opencode-ai/plugin";
import type { Event, Part } from "@opencode-ai/sdk";
import {
  type Config,
  CONFIG_DEFAULTS,
  CONFIG_PATH,
  parseConfig,
  resolveModel,
} from "./better-prompt-models.js";

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

type StageStatus = "starting" | "complete" | "skipped" | "error";
type StageNotifier = (stage: string, status: StageStatus, detail?: string) => void;

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
  mkdirSync(dirname(auditPath), { recursive: true });
  appendFileSync(auditPath, `${JSON.stringify(entry)}\n`);
}

// :::: State :::: /////////////////////////////////////////////

interface StageState {
  status: "pending" | "active" | "complete" | "skipped" | "error";
  durationMs: number | null;
  error?: string;
}

interface PipelineState {
  timestamp: string;
  status: "running" | "modified" | "no_changes" | "error";
  language: string | null;
  mistakes: number;
  stages: {
    correction: StageState;
    translation: StageState;
    context: StageState;
    enhancement: StageState;
  };
  cost: number;
  inputTokens: number;
  outputTokens: number;
  cacheWriteTokens: number;
  cacheReadTokens: number;
  sessionCost: number;
  sessionInputTokens: number;
  sessionOutputTokens: number;
  preview?: {
    original: string;
    processed: string;
    mistakeDetails: Array<{ type: string; original: string; correction: string }>;
  };
}

function writeState(statePath: string, state: PipelineState): void {
  mkdirSync(dirname(statePath), { recursive: true });
  writeFileSync(statePath, `${JSON.stringify(state)}\n`);
}

function clearState(statePath: string): void {
  try {
    unlinkSync(statePath);
  } catch {
    // best effort
  }
}

// :::: Plugin :::: ////////////////////////////////////////////

export const BetterPromptPlugin: Plugin = async (ctx) => {
  const { client, directory } = ctx;

  const AUDIT_DIR = join(directory, ".opencode", "better-prompt");
  const AUDIT_PATH = join(AUDIT_DIR, "audit.json");
  const STATE_PATH = join(homedir(), ".local", "state", "opencode", "better-prompt", "state.json");

  // :::: Error/warn logging via opencode :::: ///////////////

  async function logError(message: string, error?: unknown): Promise<void> {
    try {
      const errStr = error instanceof Error ? error.message : error ? String(error) : "";
      await client.app.log({
        body: {
          service: "better-prompt",
          level: "error",
          message: errStr ? `${message} — ${errStr}` : message,
        },
      });
    } catch {
      // opencode log may be unavailable
    }
  }

  async function logWarn(message: string, detail?: string): Promise<void> {
    try {
      await client.app.log({
        body: {
          service: "better-prompt",
          level: "warn",
          message: detail ? `${message} — ${detail}` : message,
        },
      });
    } catch {
      // opencode log may be unavailable
    }
  }

  // :::: Toast :::: /////////////////////////////////////////

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

  // :::: Session cost accumulator :::: /////////////////////////
  const sessionCost = {
    cost: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheWriteTokens: 0,
    cacheReadTokens: 0,
  };

  // In-memory session context: sessionID → summarised conversation context
  const sessionContexts = new Map<string, SessionContext>();

  // :::: Agent invocation :::: //////////////////////////////

  async function invokeAgent(
    agent: string,
    text: string,
    model?: { providerID: string; modelID: string },
  ): Promise<{ text: string; usage: Usage }> {
    let childId: string | undefined;
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
      childId = child.id;

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

      const textPart = result.parts.find((p: Part) => p.type === "text" && "text" in p);
      const resultText =
        textPart && "text" in textPart ? (textPart as { text: string }).text : text;

      interface PromptInfo {
        cost?: number;
        tokens?: {
          input?: number;
          output?: number;
          cache?: { write?: number; read?: number };
        };
      }
      const info = (result as Record<string, unknown>).info as PromptInfo | undefined;
      const usage: Usage = {
        cost: info?.cost ?? 0,
        inputTokens: info?.tokens?.input ?? 0,
        outputTokens: info?.tokens?.output ?? 0,
        cacheWriteTokens: info?.tokens?.cache?.write ?? 0,
        cacheReadTokens: info?.tokens?.cache?.read ?? 0,
      };

      return { text: resultText, usage };
    } catch (err) {
      void logError(`invokeAgent(${agent}) failed`, err);
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
    } finally {
      if (childId) {
        client.session.delete({ path: { id: childId } }).catch((err: unknown) => {
          void logWarn(
            `invokeAgent: failed to delete child session ${childId}`,
            err instanceof Error ? err.message : String(err),
          );
        });
      }
    }
  }

  // :::: Context summarisation :::: /////////////////////////////

  function formatFullSummaryInput(userMessages: string[], lastAssistant: string): string {
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
    let input = `Given this summary:\n${existingSummary}\n\nUpdate it with this new exchange:\nUser: ${userMsg}`;
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
      if (part?.type === "text" && typeof part.text === "string" && part.text.trim()) {
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
      void logError("summariseContext: session.messages failed", err);
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

    const needFullRefresh =
      !existing || existing.messageCount >= FULL_REFRESH_THRESHOLD || existing.lastMessageID === "";

    let summary: string;
    let summarisationUsage: Usage = { ...zeroUsage };

    if (needFullRefresh) {
      const model = await resolveModel(config.enhancement_model, CONFIG_DEFAULTS.enhancement_model);
      const input = formatFullSummaryInput(userMessages, lastAssistantText);
      const fullResult = await invokeAgent("prompt-summarisation", input, model);
      summary = fullResult.text;
      summarisationUsage = fullResult.usage;
    } else {
      const model = await resolveModel(config.correction_model, CONFIG_DEFAULTS.correction_model);
      const newUserMsg = userMessages[userMessages.length - 1] || "";
      const input = formatIncrementalInput(existing.summary, newUserMsg, lastAssistantText);
      const incrResult = await invokeAgent("prompt-summarisation", input, model);
      summary = incrResult.text;
      summarisationUsage = incrResult.usage;
    }

    if (!summary?.trim()) {
      void logWarn("summarisation: agent returned empty, keeping existing summary");
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
      const model = await resolveModel(config.correction_model, CONFIG_DEFAULTS.correction_model);
      const correctionResult = await invokeAgent("prompt-correction", working, model);
      addUsage(correctionResult.usage);
      const raw = correctionResult.text;

      let correctionFailed = false;
      let correctionError = "";
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
          correctionError = "missing corrected field";
          void logWarn(`correction agent returned JSON without "corrected" field`);
        }
      } catch {
        correctionFailed = true;
        correctionError = "non-JSON response";
        void logWarn(`correction agent returned non-JSON`, raw?.substring(0, 200));
      }
      if (correctionFailed) {
        notify("correction", "error", correctionError);
        await toast("Correction failed — using original prompt", "error", 3000);
      } else {
        notify("correction", "complete");
      }
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
        const translationResult = await invokeAgent("prompt-translation", working, model);
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
      const ctxResult = await summariseContext(sessionID, currentMessageID ?? "", config);
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

      const model = await resolveModel(config.enhancement_model, CONFIG_DEFAULTS.enhancement_model);
      const enhancementResult = await invokeAgent("prompt-enhancement", enhanceInput, model);
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
    event: async ({ event }: { event: Event }) => {
      if (event.type === "session.deleted") {
        const props = event.properties as Record<string, unknown> | undefined;
        const sid = (props?.sessionID ??
          (props?.info as Record<string, unknown> | undefined)?.id) as string | undefined;
        if (sid) {
          sessionContexts.delete(sid);
          clearState(STATE_PATH);
        }
      }
    },

    "chat.message": async (
      input: { sessionID: string; agent?: string; messageID?: string },
      output: { parts: Part[] },
    ) => {
      if (input.agent && SUB_AGENTS.has(input.agent)) return;

      const textPart = output.parts?.find((p: Part) => p.type === "text" && "text" in p);
      if (!textPart || !("text" in textPart)) return;

      const originalText = textPart.text;
      if (!originalText?.trim()) return;

      const config = parseConfig(CONFIG_PATH);
      if (!config.enabled) return;

      // Show initial toast to fix "frozen" UX
      await toast("Processing prompt...", "info", 15000);

      // Stage tracker for timing and live sidebar updates
      const stageTracker: Record<
        string,
        {
          status: string;
          startTime?: number;
          durationMs: number | null;
          error?: string;
        }
      > = {};

      function buildStageStates(): PipelineState["stages"] {
        const names = ["correction", "translation", "context", "enhancement"] as const;
        const result = {} as PipelineState["stages"];
        for (const s of names) {
          const t = stageTracker[s];
          result[s] = {
            status: (t?.status as StageState["status"]) || "pending",
            durationMs: t?.durationMs ?? null,
            ...(t?.error && { error: t.error }),
          };
        }
        return result;
      }

      function writeRunningState() {
        writeState(STATE_PATH, {
          timestamp: new Date().toISOString(),
          status: "running",
          language: null,
          mistakes: 0,
          stages: buildStageStates(),
          cost: 0,
          inputTokens: 0,
          outputTokens: 0,
          cacheWriteTokens: 0,
          cacheReadTokens: 0,
          sessionCost: sessionCost.cost,
          sessionInputTokens: sessionCost.inputTokens,
          sessionOutputTokens: sessionCost.outputTokens,
        });
      }

      const notify: StageNotifier = (stage, status, detail) => {
        const now = Date.now();
        if (status === "starting") {
          stageTracker[stage] = {
            status: "active",
            startTime: now,
            durationMs: null,
          };
        } else {
          const prev = stageTracker[stage];
          const durationMs = prev?.startTime ? now - prev.startTime : null;
          stageTracker[stage] = {
            status,
            durationMs,
            ...(detail && { error: detail }),
          };
        }
        writeRunningState();
      };

      let result: string;
      let corrected: string | null;
      let detectedLanguage: string | null;
      let mistakes: PipelineResult["mistakes"];
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
        usage = pipelineResult.usage;
      } catch (err) {
        void logError("pipeline failed", err);
        writeState(STATE_PATH, {
          timestamp: new Date().toISOString(),
          status: "error",
          language: null,
          mistakes: 0,
          stages: buildStageStates(),
          cost: 0,
          inputTokens: 0,
          outputTokens: 0,
          cacheWriteTokens: 0,
          cacheReadTokens: 0,
          sessionCost: sessionCost.cost,
          sessionInputTokens: sessionCost.inputTokens,
          sessionOutputTokens: sessionCost.outputTokens,
        });
        await toast("Pipeline error — original prompt sent", "error", 5000);
        return;
      }

      // Completion toast
      const changed = result !== originalText;
      await toast(changed ? "Prompt modified" : "No changes", changed ? "success" : "info", 3000);

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

      // Accumulate session cost
      sessionCost.cost += usage.cost;
      sessionCost.inputTokens += usage.inputTokens;
      sessionCost.outputTokens += usage.outputTokens;
      sessionCost.cacheWriteTokens += usage.cacheWriteTokens;
      sessionCost.cacheReadTokens += usage.cacheReadTokens;

      // Write final state for TUI sidebar
      writeState(STATE_PATH, {
        timestamp: new Date().toISOString(),
        status: changed ? "modified" : "no_changes",
        language: detectedLanguage,
        mistakes: mistakes.length,
        stages: buildStageStates(),
        cost: usage.cost,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        cacheWriteTokens: usage.cacheWriteTokens,
        cacheReadTokens: usage.cacheReadTokens,
        sessionCost: sessionCost.cost,
        sessionInputTokens: sessionCost.inputTokens,
        sessionOutputTokens: sessionCost.outputTokens,
        preview: {
          original: originalText,
          processed: result,
          mistakeDetails: mistakes,
        },
      });
    },
  };
};

export default {
  id: "better-prompt",
  server: BetterPromptPlugin,
};
