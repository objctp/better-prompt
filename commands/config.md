---
name: better-prompt:config
description: Guide users through configuring better-prompt plugin settings
argument-hint: "[setting] [value]"
allowed-tools:
  - Read
  - Write
  - Bash
---

# Better Prompt Configuration

Guide the user through configuring the better-prompt plugin interactively.

## Configuration File Location

The settings file is located at `~/.claude/better-prompt.local.md`

## Current Settings

First, read the current settings file to show the user their current configuration:

```bash
cat ~/.claude/better-prompt.local.md 2>/dev/null || echo "File not found - will use defaults"
```

## Settings Guide

Explain each setting and its purpose:

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `enabled` | boolean | `true` | Global on/off switch for the entire plugin |
| `correction` | boolean | `true` | Enable grammar and spelling correction stage |
| `correction_model` | string | `haiku` | Model to use for correction (haiku, sonnet, opus) |
| `translation` | boolean | `false` | Enable translation of non-English prompts to English |
| `translation_model` | string | `haiku` | Model to use for translation (haiku, sonnet, opus) |
| `enhancement` | boolean | `false` | Enable prompt enhancement stage |
| `enhancement_model` | string | `sonnet` | Model to use for enhancement (haiku, sonnet, opus) |
| `audit` | boolean | `true` | Enable audit logging of original prompts |
| `verbose` | boolean | `false` | Show intermediate steps (correction, enhancement) |

## Interactive Configuration

If the user provides arguments (e.g., `/better-prompt:config verbose true`), update that specific setting.

If no arguments provided, ask the user which setting they want to configure:

1. "Which setting would you like to configure? (enabled, correction, correction_model, translation, translation_model, enhancement, enhancement_model, audit, verbose)"
2. "What value would you like to set it to?"

## Updating Settings

To update settings, create or edit the YAML frontmatter in `~/.claude/better-prompt.local.md`:

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

The file can contain additional content below the frontmatter (user notes, etc.).

## Quick Actions

Suggest quick actions to the user:
- "View current settings" - Read and display the settings file
- "Reset to defaults" - Create default settings file
- "Enable verbose mode" - Set verbose to true
- "Disable audit logging" - Set audit to false
- "Change correction model" - Update correction_model
- "Enable translation" - Set translation to true
- "Change translation model" - Update translation_model

## Tips

- Settings are read each time a prompt is submitted
- Changes take effect immediately (no restart required)
- The settings file can be edited manually with any text editor
- Use the toggle command for quick on/off of specific stages
