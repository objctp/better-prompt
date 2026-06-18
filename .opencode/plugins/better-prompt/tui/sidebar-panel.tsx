/** @jsxImportSource @opentui/solid */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createEffect, createSignal, onCleanup } from "solid-js";
import { CONFIG_DEFAULTS, CONFIG_PATH, parseConfig } from "../config";
import type { Config } from "../config";
import { formatDuration, formatTokens } from "../format";
import type { PipelineState, StageState } from "../types";

const POLL_MS = 500;

const STATE_PATH = join(homedir(), ".local", "state", "opencode", "better-prompt", "state.json");

const STAGE_DEFS = [
  { key: "correction" as const, label: "correction", enabled: (c: Config) => c.correction },
  { key: "translation" as const, label: "translation", enabled: (c: Config) => c.translation },
  { key: "context" as const, label: "context", enabled: (c: Config) => c.enhancement },
  { key: "enhancement" as const, label: "enhancement", enabled: (c: Config) => c.enhancement },
];

export function SidebarPanel(props: { theme: Record<string, unknown> }) {
  const [state, setState] = createSignal<PipelineState | null>(null);
  const [config, setConfig] = createSignal<Config>({ ...CONFIG_DEFAULTS });

  const accent = () => (props.theme.accent as string) || "#A78BFA";
  const muted = () => (props.theme.textMuted as string) || "#888888";
  const success = () => (props.theme.success as string) || "#22C55E";
  const warning = () => (props.theme.warning as string) || "#F59E0B";
  const info = () => (props.theme.info as string) || "#06B6D4";

  createEffect(() => {
    function load() {
      try {
        setConfig(parseConfig(CONFIG_PATH));
      } catch {
        // config read may fail if file doesn't exist yet
      }
      try {
        if (!existsSync(STATE_PATH)) {
          setState(null);
          return;
        }
        const raw = readFileSync(STATE_PATH, "utf8").trim();
        if (!raw) {
          setState(null);
          return;
        }
        setState(JSON.parse(raw) as PipelineState);
      } catch {
        // stale read is fine
      }
    }
    load();
    const timer = setInterval(load, POLL_MS);
    onCleanup(() => clearInterval(timer));
  });

  const isVisible = () => state() !== null;

  function stageSymbol(status: StageState["status"]): { char: string; color: string } {
    switch (status) {
      case "active":
        return { char: "\u25C6", color: info() };
      case "complete":
        return { char: "\u25C7", color: success() };
      case "skipped":
        return { char: "\u25CB", color: muted() };
      case "error":
        return { char: "\u25B2", color: warning() };
      default:
        return { char: "\u25CB", color: muted() };
    }
  }

  function stageVerb(label: string): string {
    const map: Record<string, string> = {
      correction: "correcting",
      translation: "translating",
      context: "summarising",
      enhancement: "enhancing",
    };
    return map[label] || `${label}...`;
  }

  function stageDetail(def: (typeof STAGE_DEFS)[number], ss: StageState, s: PipelineState): string {
    if (ss.status === "active") {
      return stageVerb(def.label);
    }
    if (ss.status === "complete") {
      const parts: string[] = ["done"];
      const dur = formatDuration(ss.durationMs);
      if (dur) parts.push(dur);
      if (def.key === "correction" && s.mistakes > 0) {
        parts.push(`${s.mistakes} mistake${s.mistakes > 1 ? "s" : ""}`);
      }
      return parts.join(" \u00B7 ");
    }
    if (ss.status === "skipped") {
      const parts: string[] = ["skipped"];
      if (def.key === "translation" && s.language === "en") parts.push("(en)");
      return parts.join(" ");
    }
    if (ss.status === "error") {
      return ss.error || "error";
    }
    return "";
  }

  return (
    <box width="100%" flexDirection="column" marginBottom={isVisible() ? 1 : 0}>
      {isVisible() && (
        <text fg={accent()}>
          <b>Better Prompt</b>
        </text>
      )}

      {isVisible() && (
        <box width="100%" flexDirection="column" paddingLeft={1}>
          {(() => {
            const s = state();
            if (!s) return [];
            const c = config();
            const verbose = c.verbose;
            const visibleStages = STAGE_DEFS.filter((def) => def.enabled(c));
            const elements: unknown[] = [];

            for (let i = 0; i < visibleStages.length; i++) {
              const def = visibleStages[i];
              const ss = s.stages[def.key];
              const sym = stageSymbol(ss.status);
              const isLast = i === visibleStages.length - 1;
              const connector = isLast ? "  " : "\u2502 ";

              elements.push(
                <box flexDirection="row">
                  <text fg={sym.color}>{sym.char}</text>
                  <text fg={accent()}> {def.label}</text>
                </box>,
              );

              const detail = stageDetail(def, ss, s);
              const showLangBadge =
                def.key === "correction" && s.language && ss.status !== "pending";

              elements.push(
                <box flexDirection="row">
                  <text fg={muted()}>{connector}</text>
                  {showLangBadge ? (
                    <>
                      <text bg="#374151" fg="#E5E7EB">
                        {" "}
                        {s.language}{" "}
                      </text>
                      <text fg={ss.status === "error" ? warning() : muted()}> {detail}</text>
                    </>
                  ) : (
                    <text fg={ss.status === "error" ? warning() : muted()}> {detail}</text>
                  )}
                </box>,
              );

              if (
                verbose &&
                def.key === "correction" &&
                ss.status === "complete" &&
                s.preview?.mistakeDetails &&
                s.preview.mistakeDetails.length > 0
              ) {
                for (const m of s.preview.mistakeDetails.slice(0, 5)) {
                  elements.push(
                    <box flexDirection="row">
                      <text fg={muted()}>{connector}</text>
                      <text fg={muted()}>
                        {" "}
                        {m.type}: "{m.original}" → "{m.correction}"
                      </text>
                    </box>,
                  );
                }
              }

              if (!isLast) {
                elements.push(<text fg={muted()}>│</text>);
              }
            }

            if (s.inputTokens > 0 || s.outputTokens > 0) {
              const costParts: string[] = [];
              if (s.cost > 0) costParts.push(`$${s.cost.toFixed(4)}`);
              costParts.push(
                `${formatTokens(s.inputTokens)}\u2192${formatTokens(s.outputTokens)}t`,
              );
              elements.push(
                <box flexDirection="row" marginTop={0}>
                  <text fg={muted()}> </text>
                  {s.cost > 0 ? (
                    <text fg={muted()}> {costParts.join(" \u00B7 ")}</text>
                  ) : (
                    <text fg={muted()}> {costParts[0]}</text>
                  )}
                  {s.sessionInputTokens > 0 ? (
                    <text fg={muted()}>
                      {" "}
                      (sess: {formatTokens(s.sessionInputTokens)}→
                      {formatTokens(s.sessionOutputTokens)}t)
                    </text>
                  ) : null}
                </box>,
              );
            }

            return elements;
          })()}
        </box>
      )}
    </box>
  );
}
