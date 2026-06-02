---
name: better-prompt:toggle
description: Quick toggle for specific better-prompt plugin stages (enabled, correction, translation, enhancement, audit, verbose)
argument-hint: "<stage> [on|off]"
allowed-tools:
  - Read
  - Write
  - Bash
---

# Better Prompt Toggle

Quick toggle for specific better-prompt plugin stages.

## Usage

`/better-prompt:toggle <stage> [on|off]`

If no [on|off] argument is provided, toggle the current state (flip it).

## Available Stages

| Stage         | Description                                       |
| ------------- | ------------------------------------------------- |
| `enabled`     | Global on/off switch for the entire plugin        |
| `correction`  | Grammar and spelling correction stage             |
| `translation` | Translation of non-English prompts to English     |
| `enhancement` | Prompt enhancement stage                          |
| `audit`       | Audit logging of original prompts                 |
| `verbose`     | Show intermediate steps (correction, enhancement) |

## Examples

- `/better-prompt:toggle correction off` - Disable correction
- `/better-prompt:toggle translation on` - Enable translation
- `/better-prompt:toggle audit` - Toggle audit logging (flip current state)
- `/better-prompt:toggle verbose on` - Enable verbose mode
- `/better-prompt:toggle enabled` - Toggle entire plugin on/off

## Implementation

1. Read current settings from `~/.claude/better-prompt.local.md`
2. Parse the YAML frontmatter to get current values
3. Determine new value:
   - If [on|off] provided: use that value
   - If not provided: flip current boolean value
4. Update the settings file with new value
5. Confirm the change to the user

## Creating/Updating Settings File

If the settings file doesn't exist, create it with default values and apply the toggle.

If the file exists, update only the specified setting while preserving other values.

## Confirmation

Always display the result:

```
✓ correction is now OFF
✓ verbose is now ON
✓ Plugin is now DISABLED (all stages inactive)
```

## Notes

- This command is handled natively by the `UserPromptExpansion` hook when available (instant execution, no LLM processing). The instructions above serve as a fallback.
- Changes take effect immediately (no restart required)
- When `enabled` is OFF, all other stages are inactive regardless of their settings
- Use the config command for more detailed configuration
