---
name: better-prompt:logs
description: Display recent audit log entries from the better-prompt plugin
argument-hint: "[count|--clear]"
allowed-tools:
  - Read
  - Bash
---

# Better Prompt Audit Logs

Display recent audit log entries from the better-prompt plugin.

## Audit Log Location

The audit log is located at `<project-root>/.claude/better-prompt/audit.json`

## Arguments

The command accepts a single optional argument:

| Argument     | Description                |
| ------------ | -------------------------- |
| `N` (number) | Display the last N entries |
| `--clear`    | Delete the audit log file  |
| _(none)_     | Display the last entry     |

## Clearing Logs

When the user passes `--clear`:

```bash
rm -f .claude/better-prompt/audit.json
```

Confirm the action:

```
✓ Audit log cleared.
```

If the file does not exist, inform the user:

```
No audit log file found — nothing to clear.
```

**Never delete the log automatically.** Logs persist across sessions and are only removed on explicit `--clear`.

## Reading the Log

The audit log uses **JSON Lines (NDJSON)** format — each line is a separate JSON object.

Read the audit log file and display recent entries:

```bash
# Read the last entry
tail -n 1 .claude/better-prompt/audit.json

# Read the last entry formatted
tail -n 1 .claude/better-prompt/audit.json | jq '.'

# Read last N entries
tail -n 5 .claude/better-prompt/audit.json | jq '.'
```

## Display Format

Display each log entry in a readable format:

```
### Entry #N
**Date:** 2026-03-12T10:30:00Z
**Original Prompt:** "the user original prompt text"
**Mistake Nature:** grammar, spelling
**Mistakes Found:**
  - [grammar] "incorrect phrase" → "corrected phrase"
  - [spelling] "misspeling" → "misspelling"
**Models Used:** correction=haiku, translation=haiku, enhancement=sonnet
```

## Handling Empty/Missing Logs

If the log file doesn't exist or is empty:

- Inform the user that no audit logs are available yet
- Check if audit logging is enabled in settings
- Suggest enabling audit logging if disabled

## Additional Information

Show summary statistics if available:

- Total entries logged
- Most common mistake types
- Date range of logs

## Tips

- This command is handled natively by the `UserPromptExpansion` hook (instant execution, no LLM processing). The instructions above serve as a fallback.
- Use `jq` for powerful filtering and analysis of the JSON log
- Punctuation corrections are NOT classified as mistakes (by design)
- Original prompts are logged BEFORE any correction or enhancement
