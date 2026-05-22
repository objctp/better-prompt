---
name: better-prompt:logs
description: Display recent audit log entries from the better-prompt plugin
argument-hint: "[count]"
allowed-tools:
  - Read
  - Bash
---

# Better Prompt Audit Logs

Display recent audit log entries from the better-prompt plugin.

## Audit Log Location

The audit log is located at `<project-root>/.claude/prompts.json`

## Reading the Log

The audit log uses **JSON Lines (NDJSON)** format — each line is a separate JSON object.

Read the audit log file and display recent entries:

```bash
# Read the last entry
tail -n 1 .claude/prompts.json

# Read the last entry formatted
tail -n 1 .claude/prompts.json | jq '.'

# Read last N entries
tail -n 5 .claude/prompts.json | jq '.'
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

## Arguments

If the user provides a count (e.g., `/better-prompt:logs 5`), display that many recent entries.

Default: Show the last entry if count is not specified.

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

- Use `jq` for powerful filtering and analysis of the JSON log
- The log grows indefinitely — consider archiving old entries if needed
- Punctuation corrections are NOT classified as mistakes (by design)
- Original prompts are logged BEFORE any correction or enhancement
