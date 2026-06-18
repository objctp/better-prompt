/** @jsxImportSource @opentui/solid */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { TuiPluginApi } from "@opencode-ai/plugin/tui";
import { createSignal } from "solid-js";
import { CONFIG_PATH, MODEL_FIELDS, parseConfig, updateConfig } from "../config";
import type { Config } from "../config";
import { getModelTiers, resolveTier, TIER_ALIASES, TIER_CYCLE } from "../catalog";
import type { ModelEntry } from "../types";
import { formatModelDisplay } from "./format";
import { SelectView, type SelectOption } from "./select-view";

export interface RouteProps {
  api: TuiPluginApi;
  goBack: () => void;
}

function auditPath(api: TuiPluginApi): string {
  return join(api.state.path.directory, ".opencode", "better-prompt", "audit.json");
}

// :::: /better-prompt:toggle :::: ///////////////////////////

export function ToggleRoute(props: RouteProps) {
  const TOGGLE_KEYS = [
    "enabled",
    "correction",
    "translation",
    "enhancement",
    "audit",
    "verbose",
  ] as const;

  const buildStages = (): SelectOption[] => {
    const config = parseConfig(CONFIG_PATH);
    return TOGGLE_KEYS.map((stage) => ({
      title: stage,
      description: `Currently: ${
        (config as unknown as Record<string, unknown>)[stage] ? "ON" : "OFF"
      }`,
      value: stage,
    }));
  };

  const [stages, setStages] = createSignal<SelectOption[]>(buildStages());

  return (
    <SelectView
      title="Better Prompt: Toggle Stage"
      options={() => stages()}
      onSelect={(opt) => {
        const current = parseConfig(CONFIG_PATH);
        const newVal = !(current as unknown as Record<string, unknown>)[opt.value];
        updateConfig(CONFIG_PATH, { [opt.value]: newVal });
        props.api.ui.toast({
          variant: "success",
          message: `${opt.value} is now ${newVal ? "ON" : "OFF"}`,
        });
        setStages(buildStages());
      }}
      onBack={props.goBack}
    />
  );
}

// :::: /better-prompt:config :::: ///////////////////////////

export function ConfigRoute(props: RouteProps) {
  const [configData, setConfigData] = createSignal(parseConfig(CONFIG_PATH));
  const [tiersData, setTiersData] = createSignal<{
    fast: ModelEntry[];
    capable: ModelEntry[];
    powerful: ModelEntry[];
  } | null>(null);
  const [cycleIndex, setCycleIndex] = createSignal<Record<string, number>>({});

  // Load model tiers asynchronously
  getModelTiers()
    .then(setTiersData)
    .catch(() => {
      props.api.ui.toast({
        variant: "error",
        message: "Could not load model tiers",
      });
    });

  const refreshConfig = () => {
    setConfigData(parseConfig(CONFIG_PATH));
  };

  const options = () => {
    const config = configData();
    return Object.entries(config).map(([k, v]) => {
      const isModel = (MODEL_FIELDS as readonly string[]).includes(k);

      if (isModel) {
        const display = formatModelDisplay(String(v), tiersData(), k);
        return {
          title: k,
          description: display,
          value: k,
        };
      }

      const isBool = typeof v === "boolean";
      return {
        title: k,
        description: `${v}${isBool ? "  (select to toggle)" : ""}`,
        value: k,
      };
    });
  };

  const handleSelect = (opt: SelectOption) => {
    const key = opt.value as keyof Config;
    const config = configData();
    const currentVal = config[key];

    if (typeof currentVal === "boolean") {
      updateConfig(CONFIG_PATH, { [key]: !currentVal });
      props.api.ui.toast({
        variant: "success",
        message: `${key}: ${currentVal} -> ${!currentVal}`,
      });
      refreshConfig();
      return;
    }

    // Model field: cycle tier on Enter
    if ((MODEL_FIELDS as readonly string[]).includes(key)) {
      const current = String(currentVal);
      const resolvedTier = resolveTier(current, tiersData());
      const currentTierName = resolvedTier || TIER_ALIASES[current] || current;

      const currentIdx = TIER_CYCLE.indexOf(currentTierName);
      const nextIdx = currentIdx >= 0 ? (currentIdx + 1) % TIER_CYCLE.length : 0;
      const next = TIER_CYCLE[nextIdx];

      updateConfig(CONFIG_PATH, { [key]: next });
      setCycleIndex({ ...cycleIndex(), [key]: 0 });
      props.api.ui.toast({ variant: "success", message: `${key}: ${next}` });
      refreshConfig();
    }
  };

  const handleAltSelect = (opt: SelectOption) => {
    const key = opt.value as keyof Config;
    if (!(MODEL_FIELDS as readonly string[]).includes(key)) return;

    const tierData = tiersData();
    if (!tierData) {
      props.api.ui.toast({
        variant: "error",
        message: "Model data not loaded yet",
      });
      return;
    }

    const config = configData();
    const currentVal = String(config[key]);
    const resolvedTier = resolveTier(currentVal, tierData) || "fast";
    const modelsInTier = tierData[resolvedTier as "fast" | "capable" | "powerful"];
    if (!modelsInTier || modelsInTier.length === 0) {
      props.api.ui.toast({
        variant: "error",
        message: `No models available for tier: ${resolvedTier}`,
      });
      return;
    }

    const currentIdx = (cycleIndex()[key] || 0) % modelsInTier.length;
    const picked = modelsInTier[currentIdx];
    updateConfig(CONFIG_PATH, { [key]: picked.id });
    setCycleIndex({ ...cycleIndex(), [key]: currentIdx + 1 });
    props.api.ui.toast({
      variant: "success",
      message: `${key}: ${picked.id} (${resolvedTier})`,
    });
    refreshConfig();
  };

  return (
    <SelectView
      title="Better Prompt Configuration"
      options={options}
      onSelect={handleSelect}
      onAltSelect={handleAltSelect}
      onBack={props.goBack}
    />
  );
}

// :::: /better-prompt:audit :::: ////////////////////////////

export function AuditRoute(props: RouteProps) {
  const path = auditPath(props.api);

  if (!existsSync(path)) {
    return (
      <box border paddingTop={0} paddingBottom={0} paddingLeft={1} paddingRight={1}>
        <text>No audit data available.</text>
      </box>
    );
  }

  const allLines = readFileSync(path, "utf8")
    .trim()
    .split("\n")
    .filter((l: string) => l.trim());

  if (allLines.length === 0) {
    return (
      <box border paddingTop={0} paddingBottom={0} paddingLeft={1} paddingRight={1}>
        <text>Audit trail is empty.</text>
      </box>
    );
  }

  const recent = allLines.slice(-10);
  const auditOptions: SelectOption[] = [];

  for (let i = 0; i < recent.length; i++) {
    try {
      const entry = JSON.parse(recent[i]);
      const num = allLines.length - recent.length + i + 1;
      const mistakes = entry.mistakes?.length ?? 0;
      const parts: string[] = [entry.prompt.substring(0, 60)];
      if (entry.language) parts.push(`lang: ${entry.language}`);
      if (mistakes > 0) {
        parts.push(`${mistakes} mistake${mistakes > 1 ? "s" : ""}`);
      }
      auditOptions.push({
        title: `Entry #${num}`,
        description: parts.join(" | "),
        value: String(num),
      });
    } catch {
      // skip malformed entries
    }
  }

  auditOptions.push({
    title: "Clear audit trail",
    description: `${allLines.length} entries total`,
    value: "clear",
  });

  return (
    <SelectView
      title="Audit Trail"
      options={() => auditOptions}
      onSelect={(opt) => {
        if (opt.value === "clear") {
          writeFileSync(path, "");
          props.api.ui.toast({
            variant: "success",
            message: "Audit trail cleared.",
          });
          props.goBack();
          return;
        }
        const num = parseInt(opt.value, 10);
        const line = allLines[num - 1];
        try {
          const entry = JSON.parse(line);
          const details: string[] = [`#${num} ${entry.date}`, `Original: "${entry.prompt}"`];
          if (entry.language) details.push(`Language: ${entry.language}`);
          if (entry.corrected) {
            details.push(`Corrected: "${entry.corrected}"`);
          }
          if (entry.enhanced) details.push(`Enhanced: "${entry.enhanced}"`);
          if (entry.mistakes?.length > 0) {
            details.push(
              "Mistakes: " +
                entry.mistakes
                  .map(
                    (m: { type: string; original: string; correction: string }) =>
                      `[${m.type}] "${m.original}" -> "${m.correction}"`,
                  )
                  .join("; "),
            );
          }
          if (entry.models) {
            const used: string[] = [];
            if (entry.models.correction) {
              used.push(`correction=${entry.models.correction}`);
            }
            if (entry.models.translation) {
              used.push(`translation=${entry.models.translation}`);
            }
            if (entry.models.enhancement) {
              used.push(`enhancement=${entry.models.enhancement}`);
            }
            if (used.length) details.push(`Models: ${used.join(", ")}`);
          }
          props.api.ui.toast({
            variant: "info",
            message: details.join("\n"),
            duration: 8000,
          });
        } catch {
          // skip
        }
        props.goBack();
      }}
      onBack={props.goBack}
    />
  );
}
