import { homedir } from "node:os";
import { join } from "node:path";
import type { Plugin } from "@opencode-ai/plugin";
import type { Event, Part } from "@opencode-ai/sdk";
import { CONFIG_PATH, parseConfig } from "./better-prompt/config";
import { runPipeline } from "./better-prompt/pipeline";
import { SUB_AGENTS } from "./better-prompt/agents";
import { clearState, writeAudit, writeState } from "./better-prompt/state";
import type {
  AuditEntry,
  PipelineDeps,
  PipelineResult,
  PipelineState,
  SessionContext,
  StageNotifier,
  StageState,
  ToastVariant,
  Usage,
} from "./better-prompt/types";

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
    variant: ToastVariant = "info",
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

  // :::: Session state :::: /////////////////////////////////

  const sessionCost = {
    cost: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheWriteTokens: 0,
    cacheReadTokens: 0,
  };

  const sessionContexts = new Map<string, SessionContext>();

  const deps: PipelineDeps = { client, logError, logWarn, toast, sessionContexts };

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
          deps,
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
