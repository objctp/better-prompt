---
name: prompt-correction
description: This skill should be used when correcting grammar and spelling errors in user prompts. Focus on fixing actual mistakes while preserving the user's intent, style, and punctuation choices. Returns structured JSON with corrections.
version: 0.1.0
---

# Prompt Correction

This skill corrects grammar and spelling errors in prompts whilst preserving the user's original intent, style, and voice.

## Scope

**Correct:**

- Grammar errors (subject-verb agreement, tense consistency, sentence structure)
- Spelling mistakes (typos, wrong word choices)
- Clear accidental errors that impede understanding

**Preserve:**

- Punctuation choices (commas, dashes, capitalisation style)
- British vs American spelling variants (colour/color, analyse/analyze)
- Informal or conversational tone if intentional
- Technical jargon or domain-specific terminology
- `@mention` tokens (e.g. `@src/index.ts`, `@README.md`) — file/folder references; preserve exactly as written

## Output Format

Return ONLY a raw JSON object — no markdown, no code blocks, no explanation:

```json
{
  "corrected": "<corrected prompt text>",
  "mistakes": [
    {
      "type": "grammar" | "spelling",
      "original": "<incorrect text>",
      "correction": "<corrected text>"
    }
  ]
}
```

If no mistakes are found, return:

```json
{
  "corrected": "<original prompt>",
  "mistakes": []
}
```

## Correction Guidelines

1. **Minimal intervention** — Change only what is necessary to fix clear errors
2. **Discrete errors only** — Each entry in `mistakes` must be a single isolated error (a word or short phrase), never the entire sentence or clause. If a sentence has two errors, produce two separate entries.
3. **Preserve meaning** — Do not alter the user's intended message
4. **Respect style** — Maintain formal/informal tone, word choice preferences
5. **Context-aware** — Consider technical context before flagging specialised terms as errors
6. **Ignore @mentions** — Tokens beginning with `@` are file/folder references; never flag, alter, or include them in `mistakes`

## Examples

### Grammar Correction

**Input:** "She don't know what to do about the bug in the codebase."
**Output:**

```json
{
  "corrected": "She doesn't know what to do about the bug in the codebase.",
  "mistakes": [
    {
      "type": "grammar",
      "original": "don't",
      "correction": "doesn't"
    }
  ]
}
```

### Spelling Correction

**Input:** "I need to recieve the data before procesing it."
**Output:**

```json
{
  "corrected": "I need to receive the data before processing it.",
  "mistakes": [
    {
      "type": "spelling",
      "original": "recieve",
      "correction": "receive"
    },
    {
      "type": "spelling",
      "original": "procesing",
      "correction": "processing"
    }
  ]
}
```

### No Correction Needed

**Input:** "Create a React component for the user profile page."
**Output:**

```json
{
  "corrected": "Create a React component for the user profile page.",
  "mistakes": []
}
```

### Preserving Punctuation Style

**Input:** "fix the bug—its really annoying"
**Output:**

```json
{
  "corrected": "Fix the bug—it's really annoying",
  "mistakes": [
    {
      "type": "grammar",
      "original": "its",
      "correction": "it's"
    }
  ]
}
```

Note: The em-dash and lowercase style are preserved; only the clear error (its/it's) is fixed.

### Prompt Containing @mentions

**Input:** "can you refactor @src/auth.ts so it dont throw on null inputs"
**Output:**

```json
{
  "corrected": "Can you refactor @src/auth.ts so it doesn't throw on null inputs?",
  "mistakes": [
    {
      "type": "grammar",
      "original": "dont",
      "correction": "doesn't"
    }
  ]
}
```

Note: `@src/auth.ts` is untouched; only the grammar error is corrected.

### Multiple Discrete Errors

**Input:** "tell me a prminent scholar that is well known"
**Output:**

```json
{
  "corrected": "Tell me a prominent scholar who is well known.",
  "mistakes": [
    {
      "type": "spelling",
      "original": "prminent",
      "correction": "prominent"
    },
    {
      "type": "grammar",
      "original": "that",
      "correction": "who"
    }
  ]
}
```

Note: Each mistake entry targets the specific erroneous word only, not the surrounding sentence.
