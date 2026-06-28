// OpenCode loads only a plugin's `./server` entrypoint — it does not discover
// the bundled agents (a separate scanner reads the config dirs only), and
// `postinstall` can't run (OpenCode installs with ignoreScripts). So on load
// the plugin copies its own agents into the config dir matching the install
// scope, and seeds the example user config if absent.
//
// All work is synchronous FS I/O; logging is fire-and-forget. Never throws.

import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import os from "node:os";
import type { PluginInput } from "@opencode-ai/plugin";

// Agents are the only bundled content OpenCode doesn't discover on its own.
const DIRS = ["agents"] as const;

// State lives in OpenCode's state dir (next to plugin-meta.json), not the
// config dir, so it never pollutes ~/.config/opencode or a project's
// .opencode/. Keyed by destination dir: global and each project-local sync
// are independent.
const STATE_DIR = path.join(
  os.homedir(),
  ".local",
  "state",
  "opencode",
  "better-prompt",
);
const STATE_FILE = "sync-state.json";

const PROJECT_CONFIGS = [
  "opencode.json",
  "opencode.jsonc",
  ".opencode/opencode.json",
  ".opencode/opencode.jsonc",
];

// Example user config shipped at config/better-prompt.local.md.example; seeded
// once into the global config dir (postinstall can't run under OpenCode).
const CONFIG_EXAMPLE_REL = path.join("config", "better-prompt.local.md.example");
const CONFIG_EXAMPLE_DEST = path.join(
  os.homedir(),
  ".config",
  "opencode",
  "better-prompt.local.md",
);

export type SyncScope = "global" | "project";

export interface SyncOptions {
  packageRoot: string;
  version: string;
  /** Used to auto-detect scope from the project's config files. */
  packageName: string;
  client: PluginInput["client"];
  /** Overrides auto-detected scope. */
  scope?: SyncScope;
  /** Project directory; required when scope resolves to "project". */
  directory?: string;
  /** Override the destination config directory (tests). */
  configDirOverride?: string;
  /** Override the state directory (tests). */
  stateDirOverride?: string;
}

/**
 * Copy agents into the config dir matching the install scope (auto-detected:
 * listed in a project config ⇒ project-local, else global). Idempotent via a
 * per-target version record in the state dir. Never throws.
 */
export function syncContent(opts: SyncOptions): void {
  const {
    packageRoot,
    version,
    packageName,
    client,
    directory,
    configDirOverride,
    stateDirOverride,
  } = opts;

  const log = (
    level: "debug" | "info" | "warn" | "error",
    message: string,
    extra?: Record<string, unknown>,
  ) => {
    try {
      const ret = client.app.log({
        body: { service: "better-prompt", level, message, extra },
      });
      if (ret && typeof ret.catch === "function") ret.catch(() => {});
    } catch {
      // Logging must never break the plugin.
    }
  };

  // File-plugin/dev mode already exposes content where OpenCode finds it.
  if (!packageRoot.includes("node_modules")) {
    log("debug", "content sync skipped (not an npm install)");
    return;
  }

  if (!existsSync(path.join(packageRoot, "agents"))) {
    log("warn", "content sync skipped (unexpected package layout)", {
      packageRoot,
    });
    return;
  }

  const scope = opts.scope ?? detectInstallScope(directory, packageName);
  const configDir = configDirOverride ??
    (scope === "project" && directory
      ? path.join(directory, ".opencode")
      : path.join(os.homedir(), ".config", "opencode"));

  const stateDir = stateDirOverride ?? STATE_DIR;
  const stateFile = path.join(stateDir, STATE_FILE);
  const synced: Record<string, string> = readState(stateFile);

  // Idempotency guard: skip only when this version was synced AND the content
  // is still in place. State lives outside the config dir (so it survives
  // `rm -rf .opencode`), so trusting the record alone leaves a wiped
  // destination "already up to date" forever — re-sync whenever any expected
  // dir is missing or empty (after a manual wipe or a partial run).
  const alreadySynced = synced[configDir] === version;
  const contentPresent = DIRS.every((dir) => {
    try {
      return readdirSync(path.join(configDir, dir)).length > 0;
    } catch {
      return false;
    }
  });
  if (alreadySynced && contentPresent) {
    log("debug", "content sync skipped (already up to date)", {
      configDir,
      version,
    });
    return;
  }
  if (alreadySynced) {
    log("info", "re-syncing content (state recorded but content missing)", {
      configDir,
      version,
    });
  }

  mkdirSync(configDir, { recursive: true });

  try {
    for (const dir of DIRS) {
      syncDir(path.join(packageRoot, dir), path.join(configDir, dir));
    }
  } catch (error) {
    log("error", "content sync failed", { error: String(error), configDir });
    return; // state untouched → next load retries
  }

  synced[configDir] = version;
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(stateFile, JSON.stringify(synced, null, 2) + "\n");
  log("info", "synced better-prompt agents", { configDir, scope, version });
}

/**
 * Seed the example user config into the global config dir once. Never
 * overwrites an existing file. No-op outside an npm install.
 */
export function seedConfigExample(packageRoot: string): void {
  if (existsSync(CONFIG_EXAMPLE_DEST)) return;
  const src = path.join(packageRoot, CONFIG_EXAMPLE_REL);
  if (!existsSync(src)) return;
  try {
    mkdirSync(path.dirname(CONFIG_EXAMPLE_DEST), { recursive: true });
    cpSync(src, CONFIG_EXAMPLE_DEST);
  } catch {
    // best effort — plugin runs fine on defaults without it
  }
}

/** "project" if packageName is in any project config's `plugin` array, else "global". */
function detectInstallScope(
  directory: string | undefined,
  packageName: string,
): SyncScope {
  if (!directory) return "global";
  for (const rel of PROJECT_CONFIGS) {
    const file = path.join(directory, rel);
    if (!existsSync(file)) continue;
    try {
      const cfg = JSON.parse(stripJsonc(readFileSync(file, "utf8"))) as {
        plugin?: unknown[];
      };
      if (
        Array.isArray(cfg.plugin) &&
        cfg.plugin.some((e) => matchesPlugin(e, packageName))
      ) {
        return "project";
      }
    } catch {
      // Unreadable config — keep checking the rest.
    }
  }
  return "global";
}

function matchesPlugin(entry: unknown, packageName: string): boolean {
  const spec = Array.isArray(entry) ? entry[0] : entry;
  return typeof spec === "string" && spec.startsWith(packageName);
}

function stripJsonc(text: string): string {
  return text
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/(^|[^:\\])\/\/.*$/gm, "$1");
}

function readState(stateFile: string): Record<string, string> {
  try {
    if (existsSync(stateFile)) {
      return JSON.parse(readFileSync(stateFile, "utf8")) as Record<
        string,
        string
      >;
    }
  } catch {
    // Corrupt state — empty so a re-sync repairs it.
  }
  return {};
}

function syncDir(src: string, dest: string): void {
  if (!existsSync(src)) return;
  mkdirSync(dest, { recursive: true });
  for (const entry of readdirSync(src)) {
    const srcPath = path.join(src, entry);
    const destPath = path.join(dest, entry);
    const stat = lstatSync(srcPath);

    if (stat.isSymbolicLink()) {
      // Dereference — defensive; shipped files are real.
      const target = path.resolve(
        path.dirname(srcPath),
        readlinkSync(srcPath),
      );
      syncDir(target, destPath);
    } else if (stat.isDirectory()) {
      syncDir(srcPath, destPath);
    } else {
      cpSync(srcPath, destPath);
    }
  }
}
