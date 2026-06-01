# Better Prompt

Automatically corrects and enhances user prompts before they reach Claude.

## Features

- **Grammar and spelling correction** — fixes errors whilst preserving punctuation
- **Translation** — translates non-English prompts to English before enhancement
- **Prompt enhancement** — refines prompts for clarity and specificity using a configurable agent
- **Transparent operation** — the original prompt is blocked and replaced via session rewind; Claude sees only the improved version
- **Audit logging** — records original prompts with mistake categorisation in NDJSON format
- **Configurable stages** — enable/disable correction, translation, enhancement, and logging independently
- **Model selection** — use different models for different stages (default: haiku for correction and translation, sonnet for enhancement)

## Prerequisites

- Claude Code
- [`jq`](https://jqlang.github.io/jq/) — required for JSON parsing and audit logging
- Clipboard utility (for copying enhanced prompt):
  - **macOS**: `pbcopy` is built-in
  - **Linux**: install `xclip` or `xsel`
- Keyboard simulation (for rewind mechanism):
  - **macOS**: `osascript` is built-in
  - **Linux**: install [`ydotool`](https://github.com/ReimuNotMoe/ydotool) (works on both X11 and Wayland)

Install dependencies:

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt install jq xclip ydotool

# Fedora
sudo dnf install jq xclip ydotool

# Arch Linux
sudo pacman -S jq xclip ydotool
```

## Installation

**Claude Code:**

```bash
/plugin marketplace add objctp/better-prompt
/plugin install better-prompt@objct-plugins

# Local development
git clone https://github.com/objctp/shell-routines && cd shell-routines && claude
```

**OpenCode:**

Add to your config — OpenCode auto-installs npm plugins via Bun at startup.

```jsonc
// Project scope: opencode.json
{ "plugin": ["@objctp/opencode-better-prompt"] }

// Global scope: ~/.config/opencode/opencode.json
{ "plugin": ["@objctp/opencode-better-prompt"] }
```

```bash
# Local development
git clone https://github.com/objctp/better-prompt && cd better-prompt && opencode
```

On first run, the plugin copies `config/better-prompt.local.md.example` to `~/.claude/better-prompt.local.md` if no config file exists.

## Configuration

Edit `~/.claude/better-prompt.local.md`:

```yaml
---
enabled: true
correction: true
correction_model: haiku
translation: false
translation_model: haiku
enhancement: false
enhancement_model: sonnet
audit: true
verbose: false
---
```

### Settings

| Setting             | Type    | Default  | Description                                         |
| ------------------- | ------- | -------- | --------------------------------------------------- |
| `enabled`           | boolean | `true`   | Global on/off switch                                |
| `correction`        | boolean | `true`   | Enable grammar and spelling correction              |
| `correction_model`  | string  | `haiku`  | Model used for correction                           |
| `translation`       | boolean | `false`  | Enable translation of non-English prompts           |
| `translation_model` | string  | `haiku`  | Model used for translation                          |
| `enhancement`       | boolean | `false`  | Enable prompt enhancement                           |
| `enhancement_model` | string  | `sonnet` | Model used for enhancement                          |
| `audit`             | boolean | `true`   | Enable audit logging                                |
| `verbose`           | boolean | `false`  | Show intermediate steps (correction, translation, enhancement) |

## Usage

Once enabled, the plugin intercepts every prompt automatically:

1. You type a prompt
2. Plugin corrects grammar and spelling (if enabled)
3. Plugin translates to English if non-English (if enabled)
4. Plugin enhances for clarity and specificity (if enabled)
5. Original prompt is logged to the audit file (if enabled)
6. Enhanced prompt is copied to clipboard
7. Original prompt is **blocked** — it never reaches Claude
8. After the block, the **Stop hook** fires a rewind — `osascript` on macOS, `ydotool` on Linux — to paste the enhanced prompt and submit
9. Claude receives only the enhanced prompt

### Commands

- `/better-prompt:config` — interactive configuration guide
- `/better-prompt:logs` — display recent audit log entries
- `/better-prompt:toggle` — quick toggle for specific stages

### Debug mode

When `verbose` is `true`, the plugin blocks the original prompt and surfaces all three pipeline stages via the block reason so you can inspect them:

```
[Better Prompt Debug]
Original:   <your original prompt>
Corrected:  <after grammar/spelling fix>
Translated: <after translation, if enabled>
Enhanced:   <after enhancement>
```

## How it works

The plugin registers a `UserPromptSubmit` hook (type: `command`) that runs `hooks/scripts/enhance.sh` on every prompt.

### Processing order

**UserPromptSubmit hook:**

1. **Read config** — parse YAML frontmatter from `~/.claude/better-prompt.local.md`
2. **Kill switch** — if `enabled: false`, pass through immediately
3. **Correction** — invoke the `prompt-correction` agent via `claude -p --agent`; parse returned JSON for corrected text and mistake list
4. **Translation** — invoke the `prompt-translation` agent (if enabled); non-English prompts are translated to English
5. **Enhancement** — invoke the `prompt-enhancement` agent via `claude -p --agent --resume`; uses a persistent session so the model sees previously enhanced prompts as context
6. **Audit** — append one NDJSON line to `.claude/prompts.json` in the project root
7. **Determine final prompt** — use the last enabled stage's output
8. **Write sentinel** — store content hash to prevent re-processing the enhanced prompt on rewind
9. **Block** — return `{"decision": "block", ...}` so the original prompt never reaches Claude
10. **Copy to clipboard** — use `pbcopy` (macOS) or `xclip`/`xsel` (Linux)
11. **Spawn stop hook** — detached background process for the rewind

**Stop hook (after Claude responds):**

12. **Locate session PID** — find the session JSON file in `~/.claude/sessions/` matching the session ID
13. **Paste and submit** — send paste followed by Return: `osascript` on macOS, `ydotool` on Linux

### Sentinel guard

A content-hash sentinel prevents the pipeline from re-processing its own enhanced prompt when the rewind causes a second `UserPromptSubmit` event. The sentinel stores the md5 hash of the final prompt and expires after 60 seconds.

### Rewind limitations

The block-clipboard-paste mechanism is a workaround for the absence of a native prompt-replacement API. Be aware of the following constraints:

- **Clipboard clobbering** — any process writing to the clipboard between block and paste causes the wrong content to be submitted. The block reason includes the enhanced prompt text as a fallback.
- **Terminal compatibility** — keystroke injection via `osascript` or `ydotool` may not work inside `tmux`, `screen`, or embedded terminal emulators (VS Code, JetBrains).
- **Permissions** — macOS requires accessibility permissions for `osascript`; Linux requires `uinput` access for `ydotool`.
- **Timing** — the stop-hook waits 1 second before pasting. Very slow or very fast systems may need adjustment.

## Troubleshooting

### Clipboard Not Working

- macOS: `pbcopy` is built-in, no action needed
- Linux: install `xclip` or `xsel` via your package manager

### Rewind Not Triggering (Linux)

- Ensure `ydotool` is installed and the `uinput` kernel module is loaded: `lsmod | grep uinput`
- On some distros you may need to add your user to the `input` group: `sudo usermod -aG input $USER`
- Check `/tmp/better-prompt-stop.log` for stop-hook output

### Rewind Not Triggering (macOS)

- Verify the session PID is correct:
  ```bash
  grep "\"sessionId\":\"<your-session-id>\"" ~/.claude/sessions/*.json
  ```
- Ensure the process is still running: `ps -p <pid>`
- Check `/tmp/better-prompt-stop.log` for stop-hook output
- Enable `verbose` to see pipeline details

## Audit log format

The audit log is written to `<project-root>/.claude/prompts.json` in NDJSON format (one JSON object per line):

```json
{
  "date": "2026-03-12T10:30:00Z",
  "prompt": "original prompt text",
  "corrected": "prompt after correction stage",
  "enhanced": "final enhanced prompt text",
  "mistake-nature": ["grammar", "spelling"],
  "mistakes": [
    {
      "type": "grammar",
      "original": "incorrect phrase",
      "correction": "corrected phrase"
    }
  ],
  "models": {
    "correction": "haiku",
    "translation": null,
    "enhancement": null
  }
}
```

- `mistake-nature` contains unique mistake types as classified by the correction agent (e.g. `grammar`, `spelling`, `word-choice`, `capitalisation`)
- `corrected` is the prompt after the correction stage (before enhancement)
- `enhanced` is the final prompt after all stages
- `models.correction`, `models.translation`, or `models.enhancement` is `null` when that stage is disabled

## License

MIT
