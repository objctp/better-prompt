import { findModelEntry, MODEL_DEFAULTS, TIER_ALIASES, TIER_CYCLE } from "../catalog";
import { formatContext, formatCost } from "../format";
import type { ModelEntry } from "../types";

type ModelTiers = { fast: ModelEntry[]; capable: ModelEntry[]; powerful: ModelEntry[] };

export function formatModelDisplay(value: string, tiers: ModelTiers | null, key: string): string {
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
