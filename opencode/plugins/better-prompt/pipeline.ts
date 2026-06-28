import { CONFIG_DEFAULTS } from "./config";
import type { Config } from "./config";
import { resolveModel } from "./catalog";
import { invokeAgent, summariseContext } from "./agents";
import type { PipelineDeps, PipelineResult, StageNotifier, Usage } from "./types";

// A correction is consistent when every claimed fix actually appears in the
// corrected text.  A model that lists a fix for text it then dropped has
// rewritten or extracted a subset rather than applying discrete fixes — the
// correction should be discarded and the original kept.
function correctionIsConsistent(
  corrected: string,
  mistakes: Array<{ correction?: string }>,
): boolean {
  for (const m of mistakes) {
    const fix = m.correction;
    if (!fix) continue;
    if (!corrected.toLowerCase().includes(fix.toLowerCase())) {
      return false;
    }
  }
  return true;
}

export async function runPipeline(
  deps: PipelineDeps,
  text: string,
  sessionID: string,
  config: Config,
  notify: StageNotifier,
  currentMessageID?: string,
): Promise<PipelineResult> {
  const { toast, logWarn } = deps;

  let working = text;
  let corrected: string | null = null;
  let detectedLanguage: string | null = null;
  let mistakes: Array<{ type: string; original: string; correction: string }> = [];
  const totalUsage: Usage = {
    cost: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheWriteTokens: 0,
    cacheReadTokens: 0,
  };

  function addUsage(u: Usage) {
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
    const correctionResult = await invokeAgent(deps, "prompt-correction", working, model);
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
          const candidateMistakes = Array.isArray(parsed.mistakes) ? parsed.mistakes : [];
          // Guard: every claimed fix must appear in the corrected text; otherwise
          // the model rewrote/extracted a subset instead of applying discrete fixes
          // — discard and keep the original prompt.
          if (!correctionIsConsistent(parsed.corrected, candidateMistakes)) {
            correctionFailed = true;
            correctionError = "discarded: dropped a claimed fix";
            void logWarn("correction discarded — output dropped a claimed fix; keeping original");
          } else {
            working = parsed.corrected;
            corrected = parsed.corrected;
            detectedLanguage = parsed.language || null;
            mistakes = candidateMistakes;
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
      const discarded = correctionError.startsWith("discarded");
      await toast(
        discarded ? "Correction discarded — keeping original" : "Correction failed — using original prompt",
        discarded ? "info" : "error",
        3000,
      );
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
      const model = await resolveModel(config.translation_model, CONFIG_DEFAULTS.translation_model);
      const translationResult = await invokeAgent(deps, "prompt-translation", working, model);
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
    const ctxResult = await summariseContext(deps, sessionID, currentMessageID ?? "", config);
    contextSummary = ctxResult.summary;
    addUsage(ctxResult.usage);
    deps.sessionContexts.set(sessionID, {
      summary: ctxResult.summary,
      lastMessageID: ctxResult.lastMessageID,
      messageCount: ctxResult.messageCount,
    });
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
    const enhancementResult = await invokeAgent(deps, "prompt-enhancement", enhanceInput, model);
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
