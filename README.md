# Better Prompt

Automatically corrects and enhances user prompts before submission to Claude.

## Features

- **Grammar and spelling correction**: Automatically fixes errors in your prompts
- **Prompt enhancement**: Refines prompts for clarity and specificity using best practices
- **Transparent operation**: Sends improved prompts to Claude without showing intermediate steps
- **Audit logging**: Stores original prompts with mistake categorisation for future review
- **Configurable stages**: Enable/disable correction, enhancement, and logging independently
- **Model selection**: Use different models for different stages (default: haiku for correction, sonnet for enhancement)

## Installation

1. Clone or copy this plugin to your local machine
2. Add to Claude Code:
   ```bash
   claude --plugin-dir /path/to/better-prompt
   ```
3. Or copy to `.claude-plugin/` in your project directory for project-specific use

## Prerequisites

- Claude Code with plugin support
- No external dependencies required

## Configuration

Create or edit `.claude/better-prompt.local.md` in your home directory:

```yaml
---
enabled: true
correction: true
correction_model: haiku
enhancement: true
enhancement_model: sonnet
audit: true
audit_log_path: ~/.claude/better-prompt-audit.json
debug_mode: false
---
```

### Settings

| Setting             | Type    | Default                              | Description                                       |
| ------------------- | ------- | ------------------------------------ | ------------------------------------------------- |
| `enabled`           | boolean | `true`                               | Global on/off switch for the plugin               |
| `correction`        | boolean | `true`                               | Enable grammar and spelling correction            |
| `correction_model`  | string  | `haiku`                              | Model to use for correction                       |
| `enhancement`       | boolean | `true`                               | Enable prompt enhancement                         |
| `enhancement_model` | string  | `sonnet`                             | Model to use for enhancement                      |
| `audit`             | boolean | `true`                               | Enable audit logging                              |
| `audit_log_path`    | string  | `~/.claude/better-prompt-audit.json` | Path to audit log file                            |
| `debug_mode`        | boolean | `false`                              | Show intermediate steps (correction, enhancement) |

## Usage

Once enabled, the plugin automatically intercepts and processes your prompts:

1. You type a prompt (with errors, unclear phrasing, etc.)
2. Plugin corrects grammar and spelling (hidden)
3. Plugin enhances for clarity and specificity (hidden)
4. Improved prompt is sent to Claude
5. Original prompt is logged to audit file

### Commands

- `/better-prompt:config` — Interactive configuration guide
- `/better-prompt:logs` — Display recent audit log entries
- `/better-prompt:toggle` — Quick toggle for specific stages

### Debug Mode

Enable `debug_mode` in settings to see intermediate steps:

- Original prompt
- Corrected prompt (grammar/spelling fixes)
- Enhanced prompt (clarity/specificity improvements)

## Audit Log Format

The audit log uses **JSON Lines (NDJSON)** format — each entry is a separate JSON object on its own line:

```json
{"date":"2026-03-12T10:30:00Z","prompt":"original prompt text","mistake-nature":["grammar","spelling"],"mistakes":[{"type":"grammar","original":"incorrect phrase","correction":"corrected phrase"}],"models":{"correction":"haiku","enhancement":"sonnet"}}
{"date":"2026-03-12T10:31:00Z","prompt":"another prompt text","mistake-nature":["spelling"],"mistakes":[{"type":"spelling","original":"misspeling","correction":"misspelling"}],"models":{"correction":"haiku","enhancement":"sonnet"}}
```

**Formatted for readability:**
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
    "enhancement": "sonnet"
  }
}
```

## How It Works

The plugin uses a `UserPromptSubmit` hook to intercept prompts before they reach Claude:

1. **Correction stage**: Uses the configured model to fix grammar and spelling
2. **Enhancement stage**: Loads the prompt-enhancement skill to refine for clarity and specificity
3. **Submission**: Sends the final improved prompt to Claude
4. **Audit**: Logs the original prompt with mistake analysis

## License

MIT
