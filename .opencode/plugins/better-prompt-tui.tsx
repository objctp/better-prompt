/** @jsxImportSource @opentui/solid */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { TuiPlugin, TuiPluginModule } from "@opencode-ai/plugin/tui";
import { useKeyboard } from "@opentui/solid";
import { createSignal } from "solid-js";
import {
  CONFIG_PATH,
  type Config,
  findModelEntry,
  formatContext,
  formatCost,
  getModelTiers,
  MODEL_DEFAULTS,
  MODEL_FIELDS,
  type ModelEntry,
  parseConfig,
  resolveTier,
  TIER_ALIASES,
  TIER_CYCLE,
  updateConfig,
  // deno-lint-ignore no-sloppy-imports
} from "./better-prompt-models.js";

// :::: Types :::: ///////////////////////////////////////////

interface SelectOption {
  title: string;
  description: string;
  value: string;
}

// :::: Reusable SelectView component :::: ///////////////////

function SelectView(props: {
  title: string;
  options: () => SelectOption[];
  onSelect: (opt: SelectOption) => void;
  onAltSelect?: (opt: SelectOption) => void;
  onBack: () => void;
}) {
  const [idx, setIdx] = createSignal(0);

  useKeyboard((key: { name: string }) => {
    const opts = props.options();
    const max = opts.length - 1;
    if (key.name === "up" || key.name === "k") {
      setIdx((i: number) => Math.max(0, i - 1));
    }
    if (key.name === "down" || key.name === "j") {
      setIdx((i: number) => Math.min(max, i + 1));
    }
    if (key.name === "return") {
      const opt = opts[idx()];
      if (opt) props.onSelect(opt);
    }
    if (key.name === "space") {
      if (props.onAltSelect) {
        const opt = opts[idx()];
        if (opt) props.onAltSelect(opt);
      }
    }
    if (key.name === "escape") {
      props.onBack();
    }
  });

  return (
    <box border paddingTop={0} paddingBottom={0} paddingLeft={1} paddingRight={1}>
      <text>
        <strong>{props.title}</strong>
      </text>
      {props.options().map((opt: SelectOption, i: number) => (
        <text fg={idx() === i ? "#ffffff" : "#888888"}>
          {`${idx() === i ? "> " : "  "}${opt.title}  ${opt.description}`}
        </text>
      ))}
      <text fg="#555555">Up/Dn Navigate Enter Cycle Tier Space Pick Model Esc Back</text>
    </box>
  );
}

// :::: Model display formatting :::: ////////////////////////

function formatModelDisplay(
  value: string,
  tiers: { fast: ModelEntry[]; capable: ModelEntry[]; powerful: ModelEntry[] } | null,
  key: string,
): string {
  const isDefault = value === MODEL_DEFAULTS[key];
  if (isDefault) return `${value} (inherits session model)`;

  // Legacy alias: haiku → fast, sonnet → capable, opus → powerful
  const alias = TIER_ALIASES[value];
  if (alias) {
    if (!tiers) return `${value} ≡ ${alias}`;
    const tierModels = tiers[alias as "fast" | "capable" | "powerful"];
    const best = tierModels?.[0];
    return `${value} ≡ ${alias} ${
      best ? `(${best.id}  ${formatCost(best.cost)}  ctx:${formatContext(best.context)})` : ""
    }`;
  }

  // Tier name: fast/capable/powerful
  if (TIER_CYCLE.includes(value)) {
    if (!tiers) return value;
    const tierModels = tiers[value as "fast" | "capable" | "powerful"];
    const best = tierModels?.[0];
    return `${value} ${
      best ? `(${best.id}  ${formatCost(best.cost)}  ctx:${formatContext(best.context)})` : ""
    }`;
  }

  // Explicit provider/model
  if (tiers) {
    const entry = findModelEntry(value, tiers);
    if (entry) {
      return `${value} (${entry.tier}  ${formatCost(entry.cost)}  ctx:${formatContext(
        entry.context,
      )})`;
    }
  }
  return value;
}

// :::: TUI Plugin :::: //////////////////////////////////////

// deno-lint-ignore require-await
const tui: TuiPlugin = async (api) => {
  function getAuditPath(): string {
    return join(api.state.path.directory, ".opencode", "better-prompt", "audit.json");
  }

  // Track previous route so we can navigate back
  let prevRoute: { name: string; params?: Record<string, unknown> } = {
    name: "home",
  };

  function goBack() {
    api.route.navigate(prevRoute.name, prevRoute.params);
  }

  // :::: /better-prompt:toggle :::: /////////////////////////

  function handleToggle() {
    prevRoute = {
      name: api.route.current.name,
      params: (api.route.current as Record<string, unknown>).params as
        | Record<string, unknown>
        | undefined,
    };
    api.route.navigate("better-prompt:toggle");
  }

  function ToggleRoute() {
    const [stages, setStages] = createSignal(
      ["enabled", "correction", "translation", "enhancement", "audit", "verbose"].map((stage) => {
        const config = parseConfig(CONFIG_PATH);
        return {
          title: stage,
          description: `Currently: ${(config as unknown as Record<string, unknown>)[stage] ? "ON" : "OFF"}`,
          value: stage,
        };
      }),
    );

    return (
      <SelectView
        title="Better Prompt: Toggle Stage"
        options={() => stages()}
        onSelect={(opt) => {
          const current = parseConfig(CONFIG_PATH);
          const newVal = !(current as unknown as Record<string, unknown>)[opt.value];
          updateConfig(CONFIG_PATH, { [opt.value]: newVal });
          api.ui.toast({
            variant: "success",
            message: `${opt.value} is now ${newVal ? "ON" : "OFF"}`,
          });
          // Update displayed state — stay open for more toggles
          setStages(
            ["enabled", "correction", "translation", "enhancement", "audit", "verbose"].map(
              (stage) => {
                const cfg = parseConfig(CONFIG_PATH);
                return {
                  title: stage,
                  description: `Currently: ${(cfg as unknown as Record<string, unknown>)[stage] ? "ON" : "OFF"}`,
                  value: stage,
                };
              },
            ),
          );
        }}
        onBack={goBack}
      />
    );
  }

  // :::: /better-prompt:config :::: /////////////////////////

  function handleConfig() {
    prevRoute = {
      name: api.route.current.name,
      params: (api.route.current as Record<string, unknown>).params as
        | Record<string, unknown>
        | undefined,
    };
    api.route.navigate("better-prompt:config");
  }

  function ConfigRoute() {
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
        api.ui.toast({ variant: "error", message: "Could not load model tiers" });
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
        api.ui.toast({
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
        api.ui.toast({ variant: "success", message: `${key}: ${next}` });
        refreshConfig();
      }
    };

    const handleAltSelect = (opt: SelectOption) => {
      const key = opt.value as keyof Config;
      if (!(MODEL_FIELDS as readonly string[]).includes(key)) return;

      const tierData = tiersData();
      if (!tierData) {
        api.ui.toast({
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
        api.ui.toast({
          variant: "error",
          message: `No models available for tier: ${resolvedTier}`,
        });
        return;
      }

      const currentIdx = (cycleIndex()[key] || 0) % modelsInTier.length;
      const picked = modelsInTier[currentIdx];
      updateConfig(CONFIG_PATH, { [key]: picked.id });
      setCycleIndex({ ...cycleIndex(), [key]: currentIdx + 1 });
      api.ui.toast({
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
        onBack={goBack}
      />
    );
  }

  // :::: /better-prompt:audit :::: //////////////////////////

  function handleAudit() {
    const auditPath = getAuditPath();

    if (!existsSync(auditPath)) {
      api.ui.toast({
        variant: "info",
        message: "No audit data available. Enable with /better-prompt:toggle audit on",
      });
      return;
    }

    const allLines = readFileSync(auditPath, "utf8")
      .trim()
      .split("\n")
      .filter((l: string) => l.trim());

    if (allLines.length === 0) {
      api.ui.toast({ variant: "info", message: "Audit trail is empty." });
      return;
    }

    prevRoute = {
      name: api.route.current.name,
      params: (api.route.current as Record<string, unknown>).params as
        | Record<string, unknown>
        | undefined,
    };
    api.route.navigate("better-prompt:audit");
  }

  function AuditRoute() {
    const auditPath = getAuditPath();

    if (!existsSync(auditPath)) {
      return (
        <box border paddingTop={0} paddingBottom={0} paddingLeft={1} paddingRight={1}>
          <text>No audit data available.</text>
        </box>
      );
    }

    const allLines = readFileSync(auditPath, "utf8")
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
            writeFileSync(auditPath, "");
            api.ui.toast({
              variant: "success",
              message: "Audit trail cleared.",
            });
            goBack();
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
            api.ui.toast({
              variant: "info",
              message: details.join("\n"),
              duration: 8000,
            });
          } catch {
            // skip
          }
          goBack();
        }}
        onBack={goBack}
      />
    );
  }

  // :::: Route + Command registration :::: //////////////////

  api.route.register([
    { name: "better-prompt:toggle", render: () => <ToggleRoute /> },
    { name: "better-prompt:config", render: () => <ConfigRoute /> },
    { name: "better-prompt:audit", render: () => <AuditRoute /> },
  ]);

  api.keymap.registerLayer({
    commands: [
      {
        name: "better-prompt.toggle",
        title: "BP: Toggle Stage",
        category: "Better Prompt",
        namespace: "palette",
        slashName: "better-prompt:toggle",
        run: handleToggle,
      },
      {
        name: "better-prompt.config",
        title: "BP: Show Config",
        category: "Better Prompt",
        namespace: "palette",
        slashName: "better-prompt:config",
        run: handleConfig,
      },
      {
        name: "better-prompt.audit",
        title: "BP: Audit Trail",
        category: "Better Prompt",
        namespace: "palette",
        slashName: "better-prompt:audit",
        run: handleAudit,
      },
    ],
  });
};

// :::: Module export :::: ///////////////////////////////////

const plugin: TuiPluginModule & { id: string } = {
  id: "@objctp/opencode-better-prompt",
  tui,
};

export default plugin;
