import type { Part } from "@opencode-ai/sdk";
import { CONFIG_DEFAULTS } from "./config";
import type { Config } from "./config";
import { resolveModel } from "./catalog";
import type { ModelRef, PipelineDeps, Usage } from "./types";

export const SUB_AGENTS = new Set([
  "prompt-correction",
  "prompt-translation",
  "prompt-enhancement",
  "prompt-summarisation",
]);

export const FULL_REFRESH_THRESHOLD = 10;

interface PromptInfo {
  cost?: number;
  tokens?: {
    input?: number;
    output?: number;
    cache?: { write?: number; read?: number };
  };
}

const ZERO_USAGE: Usage = {
  cost: 0,
  inputTokens: 0,
  outputTokens: 0,
  cacheWriteTokens: 0,
  cacheReadTokens: 0,
};

// :::: Agent invocation :::: ////////////////////////////////

export async function invokeAgent(
  deps: PipelineDeps,
  agent: string,
  text: string,
  model?: ModelRef,
): Promise<{ text: string; usage: Usage }> {
  const { client, toast, logError, logWarn } = deps;
  let childId: string | undefined;
  try {
    const { data: child } = await client.session.create({
      body: {},
    });
    if (!child) {
      await toast(`${agent}: could not create session`, "error");
      return { text, usage: { ...ZERO_USAGE } };
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
      return { text, usage: { ...ZERO_USAGE } };
    }

    const textPart = result.parts.find((p: Part) => p.type === "text" && "text" in p);
    const resultText = textPart && "text" in textPart ? (textPart as { text: string }).text : text;

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
    return { text, usage: { ...ZERO_USAGE } };
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

// :::: Context summarisation :::: ///////////////////////////

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

export async function summariseContext(
  deps: PipelineDeps,
  sessionID: string,
  currentMessageID: string,
  config: Config,
): Promise<{
  summary: string;
  lastMessageID: string;
  messageCount: number;
  usage: Usage;
}> {
  const { sessionContexts, client, logError, logWarn } = deps;
  const existing = sessionContexts.get(sessionID);

  if (!existing || existing.messageCount === 0) {
    return {
      summary: "",
      lastMessageID: existing?.lastMessageID ?? "",
      messageCount: 1,
      usage: { ...ZERO_USAGE },
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
      usage: { ...ZERO_USAGE },
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
      usage: { ...ZERO_USAGE },
    };
  }

  const needFullRefresh =
    !existing || existing.messageCount >= FULL_REFRESH_THRESHOLD || existing.lastMessageID === "";

  let summary: string;
  let summarisationUsage: Usage = { ...ZERO_USAGE };

  if (needFullRefresh) {
    const model = await resolveModel(config.enhancement_model, CONFIG_DEFAULTS.enhancement_model);
    const input = formatFullSummaryInput(userMessages, lastAssistantText);
    const fullResult = await invokeAgent(deps, "prompt-summarisation", input, model);
    summary = fullResult.text;
    summarisationUsage = fullResult.usage;
  } else {
    const model = await resolveModel(config.correction_model, CONFIG_DEFAULTS.correction_model);
    const newUserMsg = userMessages[userMessages.length - 1] || "";
    const input = formatIncrementalInput(existing.summary, newUserMsg, lastAssistantText);
    const incrResult = await invokeAgent(deps, "prompt-summarisation", input, model);
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
