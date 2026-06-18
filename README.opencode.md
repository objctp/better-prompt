# Better Prompt for OpenCode

Automatically fixes and improves user prompts before the model sees them. This is the OpenCode build (`@objctp/opencode-better-prompt`). For the Claude Code version or a project overview, see the [GitHub repo](https://github.com/objctp/better-prompt).

## Install

Add the package to your OpenCode config. OpenCode installs npm plugins automatically at startup (via Bun), so just save the file and restart.

```jsonc
// Project scope: opencode.json (in your project root)
{ "plugin": ["@objctp/opencode-better-prompt"] }

// Global scope: ~/.config/opencode/opencode.json
{ "plugin": ["@objctp/opencode-better-prompt"] }
```

On first run, the plugin copies a default config to `~/.config/opencode/better-prompt.local.md` if none exists.

## Requirements

Just OpenCode with at least one provider connected and a model available. Because OpenCode lets a plugin rewrite a message in place, there's no clipboard or keystroke hack — no `jq`, `pbcopy`, or `ydotool` needed.

## Settings

Edit `~/.config/opencode/better-prompt.local.md`. The options are [the same as the project overview](https://github.com/objctp/better-prompt#settings); the frontmatter looks like this:

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

You can also edit it live with `/better-prompt:config` — changes take effect on the next prompt.

## Models

There are three ways to set a stage's model:

- **Built-in aliases** — `haiku`, `sonnet`, `opus`. Work everywhere.
- **Dynamic aliases** — `fast`, `capable`, `powerful`. OpenCode resolves these from the providers you've connected, picking the cheapest model with tool support in each tier.
- **Explicit IDs** — a full `provider/model` string, e.g. `opencode-go/deepseek-v4-pro`. OpenCode only.

When a stage's model matches its default, Better Prompt sends no override and the agent just inherits the model your session is already using.

### Picking models in the TUI

Inside `/better-prompt:config`:

- **Enter** on a model field — cycle the tier: `fast` → `capable` → `powerful`
- **Space** on a model field — cycle individual models within the tier (sorted by cost)
- **Enter** on a boolean field — toggle it on or off
- **Esc** — close

## What you see while it runs

Two things appear automatically:

**Toasts** — a short notice for each prompt: `Processing prompt...` while it works, then `Prompt modified` or `No changes` when it's done (or an error message if a stage failed).

**Sidebar panel** — a live view of the pipeline, refreshed a few times a second:

```
Better Prompt
 │ ◆ correction   correcting
 │ ◇ translation  done · 120ms · (en)
 │ ◇ context      summarising
 │ ◇ enhancement  done · 340ms
   $0.0123 · 1.2k→450t  (sess: 5.2k→2.1kt)
```

Each stage shows a status symbol — `◆` running, `◇` done, `○` skipped, `▲` failed — with how long it took and, for correction, how many mistakes it caught. The footer adds the cost and token use for the current prompt, plus a running total for the session.

Turn `verbose` on and the correction stage also lists up to five of the mistakes it fixed, inline.

## Commands

All three are available as slash commands and from the command palette:

- `/better-prompt:toggle` — flip stages on or off (palette: *BP: Toggle Stage*)
- `/better-prompt:config` — edit settings live (palette: *BP: Show Config*)
- `/better-prompt:audit` — show the audit trail (palette: *BP: Audit Trail*)

## How it works

The plugin hooks OpenCode's `chat.message` event. When you send a message, OpenCode hands the parts to the plugin **before** the model sees them. The plugin runs the pipeline and writes the improved text straight back into the message — the model only ever receives the result. No clipboard, no keystroke injection, nothing to rewind.

The pipeline itself:

```
your prompt → correction → translation → context → enhancement → result
```

- **Correction** — grammar and spelling.
- **Translation** — non-English to English; skipped if the prompt is already English.
- **Context** — a running summary of the conversation, fed to enhancement for continuity. Refreshed in full every 10 prompts and updated incrementally in between.
- **Enhancement** — rewrites for clarity and structure, using that summary as context.

To shield code, commands, or literal text from every stage, wrap it in a code fence (```). The plugin is also instructed to leave content inside block delimiters (`:::`) and similar structural wrappers alone, though code fences are the most reliable.

A couple of shortcuts keep it cheap: when enhancement is on without translation, correction is folded into enhancement; when translation is on without correction, the correction agent runs only to detect language.

The plugin ignores its own sub-agent calls (correction, translation, enhancement, summarisation), so it never tries to enhance its own work. While it runs it writes a state file to `~/.local/state/opencode/better-prompt/state.json`, which the sidebar reads.

## Audit log

With `audit` on, each prompt is appended to `<project>/.opencode/better-prompt/audit.json` as one JSON object per line:

```json
{
  "date": "2026-03-12T10:30:00Z",
  "prompt": "original prompt text",
  "language": "en",
  "corrected": "prompt after correction (null if correction is off)",
  "enhanced": "final prompt (null if enhancement is off)",
  "mistake-nature": ["grammar", "spelling"],
  "mistakes": [
    { "type": "grammar", "original": "incorrect phrase", "correction": "corrected phrase" }
  ],
  "models": {
    "correction": "haiku",
    "translation": null,
    "enhancement": null,
    "context": null
  },
  "usage": {
    "cost": 0.0032,
    "inputTokens": 1234,
    "outputTokens": 567,
    "cacheWriteTokens": 120,
    "cacheReadTokens": 0
  }
}
```

- `language` is what the correction stage detected.
- `corrected` is the text after correction, before enhancement.
- `enhanced` is the final prompt after every stage.
- A model field is `null` when its stage was off; `models.context` is the model used for summarisation.
- `usage` is the token cost across all stages for that one prompt.

The file grows without bound, so rotate or clear it with `/better-prompt:audit` if it gets large.

## Troubleshooting

**Plugin isn't loading**
- Confirm the package is in your `opencode.json` and you've restarted OpenCode.
- OpenCode installs npm plugins via Bun at startup — check the OpenCode log if install failed.

**Dynamic models (`fast` / `capable` / `powerful`) don't resolve**
- These come from your connected providers. Connect at least one provider with a model in OpenCode's settings, or set an explicit `provider/model` ID instead.

**Settings changes aren't picked up**
- Check you're editing `~/.config/opencode/better-prompt.local.md`. Changes via `/better-prompt:config` apply immediately; manual edits apply on the next prompt.
