import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");
const DIST = join(ROOT, "dist");
const OC_AGENTS = join(ROOT, ".opencode", "agents");

// Clean dist
if (existsSync(DIST)) {
  rmSync(DIST, { recursive: true });
}
mkdirSync(DIST, { recursive: true });

// ── Agent generation ──────────────────────────────────────
// Source of truth: agents/ (Claude Code format).
// Generates OpenCode-format files into .opencode/agents/ AND dist/agents/.

// Model IDs are intentionally omitted from agent frontmatter.
// OpenCode subagents inherit the session's current model by default.
// Users can override per-stage models via better-prompt.local.md config,
// resolved at runtime by the plugin's dynamic model discovery.
const TEMP_MAP = {
  haiku: 0.1,
  sonnet: 0.3,
};

function generateAgent(srcPath) {
  const raw = readFileSync(srcPath, "utf8");

  // Parse frontmatter (between first two --- delimiters)
  const fmMatch = raw.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!fmMatch) {
    console.warn(`Skipping ${srcPath}: no frontmatter found`);
    return null;
  }

  const [, fm, body] = fmMatch;

  // Extract Claude Code fields
  const get = (key) => {
    const m = fm.match(new RegExp(`^${key}:\\s*(.+)$`, "m"));
    return m ? m[1].trim() : null;
  };

  const description = get("description");
  const modelShort = get("model"); // haiku | sonnet
  const color = get("color");
  const maxTurns = get("maxTurns");

  if (!description || !modelShort) {
    console.warn(`Skipping ${srcPath}: missing description or model`);
    return null;
  }

  // Map Claude Code color names to valid OpenCode hex values
  const COLOR_MAP = { cyan: "#06B6D4", green: "#22C55E", blue: "#3B82F6", purple: "#A78BFA" };

  // Build OpenCode frontmatter (no model — inherits session model)
  const lines = [
    "---",
    `description: |`,
    ...(description.split(". ").length ? [`  ${description}`] : [`  ${description}`]),
    "mode: subagent",
    `temperature: ${TEMP_MAP[modelShort] ?? 0.1}`,
    `steps: ${maxTurns || 1}`,
    "permission:",
    '  "*": deny',
  ];
  if (color) {
    const hex = COLOR_MAP[color] || (color.startsWith("#") ? color : null);
    if (hex) lines.push(`color: "${hex}"`);
  }
  lines.push("---", "", body.trimEnd(), "");

  return lines.join("\n");
}

// Generate agents from agents/ → .opencode/agents/ and dist/agents/
if (existsSync(OC_AGENTS)) {
  rmSync(OC_AGENTS, { recursive: true });
}
mkdirSync(OC_AGENTS, { recursive: true });
mkdirSync(join(DIST, "agents"), { recursive: true });

const agentsDir = join(ROOT, "agents");
let agentCount = 0;
for (const entry of readdirSync(agentsDir)) {
  if (!entry.endsWith(".md")) continue;
  const content = generateAgent(join(agentsDir, entry));
  if (!content) continue;
  writeFileSync(join(OC_AGENTS, entry), content);
  writeFileSync(join(DIST, "agents", entry), content);
  agentCount++;
}
console.log(`Generated ${agentCount} agents → .opencode/agents/ + dist/agents/`);

// ── File copy helpers ────────────────────────────────────

// Recursive copy that resolves symlinks into real files
function copyDereferenced(src, dest) {
  const stat = lstatSync(src);

  if (stat.isSymbolicLink()) {
    const realPath = resolve(dirname(src), readlinkSync(src));
    copyDereferenced(realPath, dest);
    return;
  }

  if (stat.isDirectory()) {
    mkdirSync(dest, { recursive: true });
    for (const entry of readdirSync(src)) {
      copyDereferenced(join(src, entry), join(dest, entry));
    }
    return;
  }

  cpSync(src, dest);
}

// ── OpenCode npm package ────────────────────────────────
// dist/ is scope-agnostic. OpenCode installs components into
// .opencode/ (project) or ~/.config/opencode/ (global).

// Plugins (TypeScript)
const pluginsDir = join(ROOT, ".opencode", "plugins");
if (existsSync(pluginsDir) && readdirSync(pluginsDir).length > 0) {
  mkdirSync(join(DIST, "plugins"), { recursive: true });
  for (const entry of readdirSync(pluginsDir)) {
    copyDereferenced(join(pluginsDir, entry), join(DIST, "plugins", entry));
  }
}

// ── Command stubs removed ────────────────────────────────
// Commands are now handled by the TUI plugin via api.keymap.registerLayer().
// The TUI plugin provides its own slash command registration (slashName),
// so .opencode/commands/ stubs are no longer needed — they would duplicate
// the TUI plugin's registration and conflict with it.
// Source commands/*.md files are kept for Claude Code compatibility.

const OC_COMMANDS = join(ROOT, ".opencode", "commands");
if (existsSync(OC_COMMANDS)) rmSync(OC_COMMANDS, { recursive: true });

// Config (example config copied to ~/.config/opencode/ at runtime)
mkdirSync(join(DIST, "config"), { recursive: true });
for (const entry of readdirSync(join(ROOT, "config"))) {
  copyDereferenced(join(ROOT, "config", entry), join(DIST, "config", entry));
}

// Copy config and docs.
// dist/ ships to npm (@objctp/opencode-better-prompt), whose users are on
// OpenCode — so the dist README is the OpenCode guide, not the repo overview.
cpSync(join(ROOT, "opencode.json"), join(DIST, "opencode.json"));
cpSync(join(ROOT, "README.opencode.md"), join(DIST, "README.md"));
cpSync(join(ROOT, "LICENSE"), join(DIST, "LICENSE"));

// Generate npm package.json for dist/ (not a copy of root)
const rootPkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
const distPkg = {
  name: rootPkg.name,
  version: rootPkg.version,
  description: rootPkg.description,
  author: rootPkg.author,
  homepage: rootPkg.homepage,
  repository: rootPkg.repository,
  license: rootPkg.license,
  keywords: rootPkg.keywords,
  scripts: {
    postinstall:
      "mkdir -p ~/.config/opencode && [ ! -f ~/.config/opencode/better-prompt.local.md ] && cp config/better-prompt.local.md.example ~/.config/opencode/better-prompt.local.md || true",
  },
  dependencies: rootPkg.dependencies ?? {},
  exports: {
    "./server": { import: "./plugins/better-prompt.ts" },
    "./tui": { import: "./plugins/better-prompt-tui.tsx" },
  },
  files: ["agents/", "plugins/", "config/", "opencode.json", "README.md", "LICENSE"],
};
writeFileSync(join(DIST, "package.json"), JSON.stringify(distPkg, null, 2) + "\n");

console.log("Build complete. Output in dist/");
