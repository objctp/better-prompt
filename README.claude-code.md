# Better Prompt for Claude Code

Automatically fixes and improves user prompts before Claude sees them. See the [project overview](README.md) for what's shared across CLIs; this README covers the Claude Code specifics.

## Install

Install from the `objct-plugins` marketplace, then start a fresh session:

```bash
# Inside Claude Code
/plugin marketplace add objctp/objct-plugins
/plugin install better-prompt@objct-plugins

# Start a new session so the plugin loads — run /clear
```

Or from your terminal:

```bash
claude plugin marketplace add objctp/objct-plugins
claude plugin install better-prompt@objct-plugins
```

On first run, the plugin copies a default config to `~/.claude/better-prompt.local.md` if none exists.

## Requirements

Claude Code has no built-in way to swap a prompt in-flight, so Better Prompt blocks the original, copies the improved one to the clipboard, and pastes it back for you after Claude responds. That needs a few system tools:

- **`jq`** — for parsing JSON and writing the audit log
- **Clipboard** — `pbcopy` (built in on macOS), or `xclip` / `xsel` on Linux
- **Keystroke input** — `osascript` (built in on macOS), or [`ydotool`](https://github.com/ReimuNotMoe/ydotool) on Linux (works on both X11 and Wayland)

```bash
# macOS
brew install jq

# Ubuntu / Debian
sudo apt install jq xclip ydotool

# Arch
sudo pacman -S jq xclip ydotool
```

## Settings

Edit `~/.claude/better-prompt.local.md`. The options are [the same as the overview](README.md#settings); the frontmatter looks like this:

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

Model aliases `haiku`, `sonnet`, and `opus` are supported.

## What happens when you send a prompt

1. You type a prompt.
2. Better Prompt runs whichever stages are on (correction → translation → enhancement).
3. It **blocks** the original, so Claude never sees it.
4. It copies the improved prompt to your clipboard.
5. After Claude finishes responding, the stop hook pastes and submits the improved prompt — `osascript` on macOS, `ydotool` on Linux.
6. Claude answers the improved version.

This happens automatically on every prompt. If `enabled: false`, everything passes through untouched.

### Commands

- `/better-prompt:config` — walk through the settings interactively
- `/better-prompt:toggle` — flip stages on or off quickly
- `/better-prompt:audit` — show recent audit entries

Add `--help` to any of them for usage.

### Debug mode

Turn `verbose: true` to see each stage in the block message before the paste:

```
[Better Prompt Debug]
Original:   <what you typed>
Corrected:  <after grammar/spelling>
Language:   en
Enhanced:   <final version>
Cost:       $0.003210
Tokens:     1234 in (120 w) / 567 out
```

## How it works

Two hooks do the work:

- **`UserPromptSubmit`** runs `hooks/scripts/enhance.sh` on every prompt. It reads the config, runs the pipeline, writes the audit line, copies the result to the clipboard, and returns `{"decision": "block", ...}` so Claude never sees the raw input.
- **Stop hook** fires after Claude responds. It finds the session, then pastes and submits via `osascript` or `ydotool`.

A **sentinel** stops the loop. When the pasted prompt lands a second time as a new `UserPromptSubmit`, Better Prompt compares its hash against the one it just wrote; if they match (within 60 seconds), it lets it through instead of re-processing.

### Keeping content untouched

To protect code, commands, or literal text from all stages, wrap it in a code fence (```). The plugin is also instructed to leave content inside block delimiters (`:::`) and similar structural wrappers alone, though code fences are the most reliable.

`@mentions` and `/commands` are wrapped automatically before the paste, so you don't need to handle those yourself.

### Rewind caveats

The block-and-paste trick is a workaround, so a few things can trip it up:

- **Clipboard clobbering** — if anything else writes to the clipboard between the block and the paste, the wrong text gets submitted. The block message always shows the full improved prompt as a fallback.
- **Terminal compatibility** — keystroke injection may not work inside `tmux`, `screen`, or embedded terminals (VS Code, JetBrains).
- **Permissions** — macOS needs Accessibility access for `osascript`; Linux needs `uinput` access for `ydotool`.
- **Timing** — the stop hook waits about 1 second before pasting. Very slow or very fast systems may need this tuned.

## Troubleshooting

**Clipboard not working**

- macOS: `pbcopy` is built in.
- Linux: install `xclip` or `xsel`.

**Rewind not triggering (Linux)**

- Make sure `ydotool` is installed and the `uinput` module is loaded: `lsmod | grep uinput`.
- Some distros need your user in the `input` group: `sudo usermod -aG input $USER`.
- Check `/tmp/better-prompt-stop.log`.

**Rewind not triggering (macOS)**

- Confirm the session PID is right: `grep "\"sessionId\":\"<your-session-id>\"" ~/.claude/sessions/*.json`.
- Make sure the process is still running: `ps -p <pid>`.
- Check `/tmp/better-prompt-stop.log`, and turn on `verbose` for pipeline detail.

## Audit log

With `audit` on, each prompt is appended to `<project>/.claude/better-prompt/audit.json` as one JSON object per line:

```json
{
  "date": "2026-03-12T10:30:00Z",
  "prompt": "original prompt text",
  "language": "en",
  "corrected": "prompt after correction (null if correction is off)",
  "enhanced": "final prompt (null if enhancement is off)",
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

- `mistake-nature` lists the unique mistake types the correction stage found (`grammar`, `spelling`, `word-choice`, `capitalisation`, …).
- `corrected` is the text after correction, before enhancement.
- `enhanced` is the final prompt after every stage.
- A model field is `null` when its stage was off.
