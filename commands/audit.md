---
name: better-prompt:audit
description: Display recent audit trail entries from the better-prompt plugin
argument-hint: "[count|--clear]"
allowed-tools:
  - Read
  - Bash
---

# Better Prompt Audit Trail

Display recent audit trail entries from the better-prompt plugin.

## Audit Location

The audit trail is located at `<project-root>/.claude/better-prompt/audit.json`

## Arguments

The command accepts a single optional argument:

| Argument     | Description                |
| ------------ | -------------------------- |
| `N` (number) | Display the last N entries |
| `--clear`    | Delete the audit file      |
| _(none)_     | Display the last entry     |

## Clearing

When the user passes `--clear`:

```bash
rm -f .claude/better-prompt/audit.json
```

Confirm the action:

```
Audit trail cleared.
```

If the file does not exist, inform the user:

```
No audit file found -- nothing to clear.
```

**Never delete the file automatically.** Entries persist across sessions and are only removed on explicit `--clear`.

## Reading

The audit file uses **JSON Lines (NDJSON)** format -- each line is a separate JSON object.

Read the audit file and display recent entries:

```bash
# Read the last entry
tail -n 1 .claude/better-prompt/audit.json

# Read the last entry formatted
tail -n 1 .claude/better-prompt/audit.json | jq '.'

# Read last N entries
tail -n 5 .claude/better-prompt/audit.json | jq '.'
```

## Display Format

Display each entry in a readable format:

```
### Entry #N
**Date:** 2026-03-12T10:30:00Z
**Original Prompt:** "the user original prompt text"
**Mistake Nature:** grammar, spelling
**Mistakes Found:**
  - [grammar] "incorrect phrase" -> "corrected phrase"
  - [spelling] "misspeling" -> "misspelling"
**Models Used:** correction=haiku, translation=haiku, enhancement=sonnet
```

## Handling Empty/Missing File

If the file doesn't exist or is empty:

- Inform the user that no audit data is available yet
- Check if audit is enabled in settings
- Suggest enabling it if disabled

## Additional Information

Show summary statistics if available:

- Total entries
- Most common mistake types
- Date range

## Tips

- Use `jq` for powerful filtering and analysis of the JSON data
- Punctuation corrections are NOT classified as mistakes (by design)
- Original prompts are recorded BEFORE any correction or enhancement
- This command is handled natively by the `UserPromptExpansion` hook (instant execution, no LLM processing). The instructions above serve as a fallback.

## Flags

| Flag     | Description                 |
| -------- | --------------------------- |
| `--help` | Show usage and help message |
