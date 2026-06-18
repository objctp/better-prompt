# Better Prompt

Automatically fixes and improves user prompts before they reach the model.

Supports two CLIs, with the same settings:

- **OpenCode** → [README](README.opencode.md)
- **Claude Code** → [README](README.claude-code.md)

> _See your CLI's README for install steps and the details that matter._

## How it works

Every prompt runs through up to three stages, each of which you can switch on or off:

```
original → [correction] → [translation] → [enhancement] → final
```

- **Correction** — fixes grammar and spelling whilst preserving intent, style, and punctuation
- **Translation** — translates non-English prompts to English; English passes through unchanged
- **Enhancement** — rewrites for clarity, specificity, and structure

Stages are optional — the plugin works with just correction, just enhancement, or any combination.

## Settings

Settings live in a YAML file. The options are the same on both CLIs — only the path differs, so see your CLI's README.

| Setting             | Default  | What it does                      |
| ------------------- | -------- | --------------------------------- |
| `enabled`           | `true`   | Master switch                     |
| `correction`        | `true`   | Fix grammar and spelling          |
| `correction_model`  | `haiku`  | Model for correction              |
| `translation`       | `false`  | Translate non-English to English  |
| `translation_model` | `haiku`  | Model for translation             |
| `enhancement`       | `false`  | Rewrite for clarity               |
| `enhancement_model` | `sonnet` | Model for enhancement             |
| `audit`             | `true`   | Keep a log of prompts and changes |
| `verbose`           | `false`  | Show extra detail                 |

**Models** — `haiku`, `sonnet`, and `opus` work everywhere. OpenCode can also use the providers you've connected (`fast`, `capable`, `powerful`) or an explicit `provider/model` ID. _See the [OpenCode README](README.opencode.md#models)._

## Audit log

With `audit` on, each prompt is logged as one line of JSON — the original text, each stage's output, the mistakes caught, and the models used. OpenCode adds token usage. Paths and exact fields are in the CLI READMEs.

## License

MIT
