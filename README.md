# Better Prompt

Automatically corrects and enhances user prompts before they reach Claude.

## Features

- **Grammar and spelling correction** — fixes errors whilst preserving punctuation
- **Translation** — translates non-English prompts to English before enhancement
- **Prompt enhancement** — refines prompts for clarity and specificity using a configurable agent
- **Transparent operation** — the original prompt is blocked and replaced; Claude sees only the improved version
- **Audit logging** — records original prompts with mistake categorisation in NDJSON format
- **Configurable stages** — enable/disable correction, translation, enhancement, and logging independently
- **Model selection** — use different models for different stages (default: haiku for correction and translation, sonnet for enhancement)

## Prerequisites

- Claude Code
- [`jq`](https://jqlang.github.io/jq/) — required for JSON parsing and audit logging
- Clipboard utility (for TTY rewind method):
  - **macOS**: `pbcopy` is built-in
  - **Linux**: install `xclip` or `xsel`

Install dependencies:

```bash
# macOS
brew install jq

# Debian/Ubuntu
sudo apt install jq xclip

# Fedora
sudo dnf install jq xclip
```

## Installation

1. Clone or copy this plugin to your local machine
2. Add to Claude Code:
   ```bash
   claude --plugin-dir /path/to/better-prompt
   ```

On first run, the plugin copies `examples/better-prompt.local.md.example` to `~/.claude/better-prompt.local.md` if no config file exists.

## Configuration

Edit `~/.claude/better-prompt.local.md`:

```yaml
---
enabled: true
correction: true
correction_model: haiku
translation: false
translation_model: haiku
enhancement: true
enhancement_model: sonnet
audit: true
audit_log_path: ~/.claude/better-prompt-audit.jsonl
debug_mode: false
resume_delay: 1.0
---
```

### Settings

| Setting             | Type    | Default                               | Description                                          |
| ------------------- | ------- | ------------------------------------- | ---------------------------------------------------- |
| `enabled`           | boolean | `true`                                | Global on/off switch                                 |
| `correction`        | boolean | `true`                                | Enable grammar and spelling correction               |
| `correction_model`  | string  | `haiku`                               | Model used for correction                            |
| `translation`       | boolean | `false`                               | Enable translation of non-English prompts            |
| `translation_model` | string  | `haiku`                               | Model used for translation                           |
| `enhancement`       | boolean | `true`                                | Enable prompt enhancement                            |
| `enhancement_model` | string  | `sonnet`                              | Model used for enhancement                           |
| `audit`             | boolean | `true`                                | Enable audit logging                                 |
| `audit_log_path`    | string  | `~/.claude/better-prompt-audit.jsonl` | Path to audit log (NDJSON)                           |
| `debug_mode`        | boolean | `false`                               | Show intermediate steps instead of replacing prompt  |

## Usage

Once enabled, the plugin intercepts every prompt automatically:

1. You type a prompt
2. Plugin corrects grammar and spelling (if enabled)
3. Plugin translates to English if non-English (if enabled)
4. Plugin enhances for clarity and specificity (if enabled)
5. Original prompt is logged to the audit file (if enabled)
6. Enhanced prompt is copied to clipboard
7. Original prompt is submitted to Claude
8. After Claude responds, the **Stop** hook triggers a rewind
9. Session rewinds to before your prompt
10. Enhanced prompt is pasted and submitted

Claude receives only the enhanced prompt. Your original prompt is briefly processed but then replaced via rewind.

### Commands

- `/better-prompt:config` — interactive configuration guide
- `/better-prompt:logs` — display recent audit log entries
- `/better-prompt:toggle` — quick toggle for specific stages

### Debug mode

When `debug_mode` is `true`, the plugin skips the session rewind and instead appends all three versions to Claude's context so you can inspect them:

```
[Better Prompt Debug]
Original:   <your original prompt>
Corrected:  <after grammar/spelling fix>
Translated: <after translation, if enabled>
Enhanced:   <after enhancement>
```

The original prompt is sent to Claude as normal in debug mode — nothing is blocked or replaced.

## How it works

The plugin registers a `UserPromptSubmit` hook (type: `command`) that runs `hooks/scripts/enhance.sh` on every prompt.

### Processing order

**UserPromptSubmit hook:**

1. **Read config** — parse YAML frontmatter from `~/.claude/better-prompt.local.md`
2. **Kill switch** — if `enabled: false`, pass through immediately
3. **Correction** — invoke the `prompt-correction` agent via `claude -p --agent`; parse returned JSON for corrected text and mistake list
4. **Translation** — invoke the `prompt-translation` agent (if enabled); non-English prompts are translated to English
5. **Enhancement** — invoke the `prompt-enhancement` agent via `claude -p --agent --resume`; uses a persistent session so the model sees previously enhanced prompts as context, improving understanding of the user's work progression
6. **Audit** — append one NDJSON line to `audit_log_path`
7. **Copy to clipboard** — use `pbcopy` (macOS) or `xclip`/`xsel` (Linux) to copy the enhanced prompt
8. **Continue** — return `{"continue": true}` to let the original prompt through

**Stop hook (after Claude responds):**

9. **Locate session PID** — find the session JSON file in `~/.claude/sessions/` matching `$CLAUDE_SESSION_ID` and extract the process ID
10. **Resolve TTY** — get the terminal device for the session PID
11. **Send rewind sequence** — write keyboard codes to TTY: `Esc+Esc` → `Arrow Up` → `Enter` → `Enter` → `Cmd+V`

### Fallback behaviour

If the session PID cannot be found (e.g. on the first turn), the plugin falls back to injecting the enhanced prompt via `additionalContext` rather than aborting. The original prompt still reaches Claude in this case, but is accompanied by the enhanced version as additional context.

## Troubleshooting

### TTY Permission Errors

If you see "cannot write to /dev/ttysXXX", ensure:

- The terminal is owned by your user
- You're not running Claude Code with sudo
- On Linux: you have proper permissions for the TTY device

### Clipboard Not Working

- macOS: `pbcopy` is built-in, no action needed
- Linux: install `xclip` or `xsel` via your package manager

### Rewind Sequence Not Triggering

- Verify the session PID is correct:
  ```bash
  # Find your session ID in debug output or env
  # Then find the matching session file
  grep "\"sessionId\":\"<your-session-id>\"" ~/.claude/sessions/*.json
  ```
- Ensure the process is still running: `ps -p <pid>`
- Check debug_mode output to see the detected PID and TTY device

## Audit log format

One JSON object per line (NDJSON):

```json
{
  "date": "2026-03-12T10:30:00Z",
  "prompt": "original prompt text",
  "mistake-nature": ["grammar", "spelling"],
  "mistakes": [
    {
      "type": "grammar",
      "original": "incorrect phrase",
      "correction": "corrected phrase"
    }
  ],
  "models": { "correction": "haiku", "translation": null, "enhancement": "sonnet" }
}
```

**Formatted:**

```json
{
  "date": "2026-03-12T10:30:00Z",
  "prompt": "original prompt text",
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

- `mistake-nature` contains the mistake types as classified by the correction agent (e.g. `grammar`, `spelling`, `punctuation`, `word-choice`, `capitalisation`)
- `models.correction`, `models.translation`, or `models.enhancement` is `null` when that stage is disabled

## License

MIT
