import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { z } from "zod";

export const CONFIG_PATH = join(homedir(), ".config", "opencode", "better-prompt.local.md");

export const ConfigSchema = z.object({
  enabled: z.boolean(),
  correction: z.boolean(),
  correction_model: z.string(),
  translation: z.boolean(),
  translation_model: z.string(),
  enhancement: z.boolean(),
  enhancement_model: z.string(),
  audit: z.boolean(),
  verbose: z.boolean(),
});

export type Config = z.infer<typeof ConfigSchema>;

export const CONFIG_DEFAULTS: Config = {
  enabled: true,
  correction: true,
  correction_model: "haiku",
  translation: false,
  translation_model: "haiku",
  enhancement: false,
  enhancement_model: "sonnet",
  audit: true,
  verbose: false,
};

export const MODEL_FIELDS: ReadonlyArray<keyof Config> = [
  "correction_model",
  "translation_model",
  "enhancement_model",
] as const;

export function parseConfig(configPath: string): Config {
  if (!existsSync(configPath)) return { ...CONFIG_DEFAULTS };

  const raw = readFileSync(configPath, "utf8");
  const fmMatch = raw.match(/^---\n([\s\S]*?)\n---/);
  if (!fmMatch) return { ...CONFIG_DEFAULTS };

  const fm = fmMatch[1];
  const get = (key: string): string | undefined => {
    const m = fm.match(new RegExp(`^${key}:\\s*(.+)$`, "m"));
    return m ? m[1].trim() : undefined;
  };

  const bool = (key: string, fallback: boolean): boolean => {
    const v = get(key);
    return v !== undefined ? v === "true" : fallback;
  };

  const str = (key: string, fallback: string): string => {
    const v = get(key);
    return v !== undefined ? v : fallback;
  };

  const built = {
    enabled: bool("enabled", CONFIG_DEFAULTS.enabled),
    correction: bool("correction", CONFIG_DEFAULTS.correction),
    correction_model: str("correction_model", CONFIG_DEFAULTS.correction_model),
    translation: bool("translation", CONFIG_DEFAULTS.translation),
    translation_model: str("translation_model", CONFIG_DEFAULTS.translation_model),
    enhancement: bool("enhancement", CONFIG_DEFAULTS.enhancement),
    enhancement_model: str("enhancement_model", CONFIG_DEFAULTS.enhancement_model),
    audit: bool("audit", CONFIG_DEFAULTS.audit),
    verbose: bool("verbose", CONFIG_DEFAULTS.verbose),
  };

  return ConfigSchema.parse(built);
}

export function updateConfig(configPath: string, updates: Partial<Config>): void {
  let raw = "";
  if (existsSync(configPath)) {
    raw = readFileSync(configPath, "utf8");
  }

  let fm = "";
  let body = "";
  const fmMatch = raw.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (fmMatch) {
    fm = fmMatch[1];
    body = fmMatch[2];
  }

  for (const [key, value] of Object.entries(updates)) {
    if (value === undefined) continue;
    const line = `${key}: ${value}`;
    const regex = new RegExp(`^${key}: .+$`, "m");
    if (regex.test(fm)) {
      fm = fm.replace(regex, line);
    } else {
      fm += `\n${line}`;
    }
  }

  writeFileSync(configPath, `---\n${fm}\n---\n${body}`);
}
