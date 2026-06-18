export function formatCost(cost: number): string {
  if (cost === 0) return "$0/M";
  if (cost < 0.01) return `$${cost.toFixed(4)}/M`;
  if (cost < 1) return `$${cost.toFixed(2)}/M`;
  return `$${cost.toFixed(2)}/M`;
}

export function formatContext(ctx: number): string {
  if (ctx >= 1_000_000) {
    return `${(ctx / 1_000_000).toFixed(ctx % 1_000_000 === 0 ? 0 : 1)}M`;
  }
  if (ctx >= 1_000) return `${Math.round(ctx / 1_000)}K`;
  return String(ctx);
}

export function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

export function formatDuration(ms: number | null): string {
  if (ms === null) return "";
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}
