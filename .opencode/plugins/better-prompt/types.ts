import type { PluginInput } from "@opencode-ai/plugin";

// :::: Model / catalog types :::: ///////////////////////////

export type ModelRef = { providerID: string; modelID: string };

export interface ModelEntry {
  id: string;
  providerID: string;
  modelID: string;
  tier: "fast" | "capable" | "powerful";
  context: number;
  cost: number;
  toolCall: boolean;
}

export interface CatalogModel {
  id: string;
  name?: string;
  tool_call?: boolean;
  limit?: { context?: number; output?: number };
  cost?: { input?: number; output?: number };
}

export interface CatalogProvider {
  id: string;
  name?: string;
  env?: string[];
  models?: Record<string, CatalogModel>;
}

export type Catalog = Record<string, CatalogProvider>;

export interface CatalogCandidate {
  id: string;
  context: number;
  cost: number;
  toolCall: boolean;
}

export interface OpenCodeConfig {
  disabled_providers?: string[];
  enabled_providers?: string[];
  provider?: Record<string, { models?: Record<string, unknown> }>;
  [key: string]: unknown;
}

// :::: Pipeline types :::: //////////////////////////////////

export interface Usage {
  cost: number;
  inputTokens: number;
  outputTokens: number;
  cacheWriteTokens: number;
  cacheReadTokens: number;
}

export interface PipelineResult {
  result: string;
  corrected: string | null;
  detectedLanguage: string | null;
  mistakes: Array<{ type: string; original: string; correction: string }>;
  contextSummary: string;
  usage: Usage;
}

export type StageStatus = "starting" | "complete" | "skipped" | "error";
export type StageNotifier = (stage: string, status: StageStatus, detail?: string) => void;

export interface SessionContext {
  summary: string;
  lastMessageID: string;
  messageCount: number;
}

export interface AuditEntry {
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

// :::: State types :::: /////////////////////////////////////

export interface StageState {
  status: "pending" | "active" | "complete" | "skipped" | "error";
  durationMs: number | null;
  error?: string;
}

export interface PipelineState {
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

// :::: Plugin dependency injection :::: /////////////////////

export type ToastVariant = "info" | "success" | "error";

export interface PipelineDeps {
  client: PluginInput["client"];
  logError: (message: string, error?: unknown) => Promise<void>;
  logWarn: (message: string, detail?: string) => Promise<void>;
  toast: (message: string, variant?: ToastVariant, duration?: number) => Promise<void>;
  sessionContexts: Map<string, SessionContext>;
}
