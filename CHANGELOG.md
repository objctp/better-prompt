# Changelog

## Unreleased

### Added

- Automate changelog via git-cliff

## [0.8.0] - 2026-06-18

### Added

- **OpenCode support** — first-class build (`@objctp/opencode-better-prompt`) that rewrites prompts in place: no clipboard, no keystroke injection.
- Dynamic model discovery — `fast` / `capable` / `powerful` aliases resolved from your connected providers via the models.dev catalogue.
- Live pipeline sidebar panel, toast notifications, and session cost/token tracking (OpenCode).
- Conversation summarisation stage for enhancement continuity (replaces the prior sliding window).

### Fixed

- **Multi-line prompts** (Claude Code) — correction and context summary no longer truncate at the first newline; fixes audit-write crashes and an infinite rewind loop.
- `@mentions` and `/commands` are auto-wrapped so the rewind paste doesn't trigger the file picker or slash menu.
- Correction consistency guard — discards fixes the model claims but then dropped.

### Changed

- OpenCode plugin modularised into a `better-prompt/` directory; config validated with `zod`.
- README split into per-CLI guides (`README.claude-code.md`, `README.opencode.md`).

## [0.7.1] - 2026-06-06

### Added

- `--help` / `-h` flag on all commands for usage and examples
- `--show` flag on `/better-prompt:config` to display current settings

## [0.7.0] - 2026-06-03

### Changed

- Block notification now shows truncated prompt previews (`[+N lines]`) instead of full text in the `reason` field
- Verbose token display now includes cache creation (w) and cache read (r) breakdowns
- Verbose debug output now shows buffered pipeline stage messages
- Sub-agent invocations use `--no-session-persistence` to avoid writing unused session transcripts
- Renamed `/better-prompt:logs` to `/better-prompt:audit` for consistency with the `audit` config setting

## [0.6.0] - 2026-06-03

### Changed

- Performance: deferred fast-fail gate in `enhance.sh` avoids jq and config parse on disabled/directive paths (~74ms to ~16ms, 79% faster)
- Performance: consolidated multi-pass jq calls into single passes across `enhance.sh`, `logs.sh`, and `lib/common.sh`
- Performance: replaced `printf | jq` pipes with here-strings, `$(cat)` with `read -d ''`, `$(uname)` with `$OSTYPE`
- Renamed `_strip_markdown_fences` to `_strip_agent_wrappers`; now only applied to correction agent JSON output (preserves legitimate ``` in translated/enhanced prompts)
- Removed redundant inline prompt wrappers from correction and translation stages; enhancement stage stripped to dynamic context only
- Agent prompts reviewed and streamlined across all three stages

### Fixed

- `_CFG` vs `cfg` naming mismatch between `_parse_config` and `_get_setting` in `enhance.sh`

## [0.5.0] - 2026-06-02

### Added

- Translation stage frames prompt as text to translate, skips English via correction-stage language detection
- Dedicated plugin directory under `.claude/`
- Token usage and total cost display in verbose mode
- Correction stage skipped when enhancement is enabled

### Changed

- Major refactor: pipeline state to namerefs, shared config lib (`lib/common.sh`), stdin piping, audit log persistence, verbose rename, language detection independence, orphan cleanup, model validation, normal-mode prompt visibility
- Enhancement stage uses filtered context file instead of `session --resume`

### Fixed

- Strip markdown fences from agent output before use
- Agent JSON escape string fix

## [0.4.0] - 2026-05-26

### Changed

- Config file moved to proper location
- Shell best practices applied across scripts

### Added

- Test suite

### Fixed

- Prevent recursive hook invocation
- Performance optimisation

## [0.3.0] - 2026-05-22

### Added

- Migrated skills to agents architecture
- Translation stage for non-English prompts
- Resume enhanced prompt from stored session_id for previous context

### Fixed

- Inconsistencies across enhance.sh, hooks, commands, and README
- README alignment

## [0.2.0] - 2026-03-28

### Added

- Rewind and re-fire prompt capability

## [0.1.0] - 2026-03-12

### Added

- Initial plugin structure with hooks, skills, commands, and examples
- Hooks: prompt enhancement pipeline
- Skills: correction, translation, enhancement agents
- Commands: config, logs, toggle
- Audit log in JSON Lines format for efficient appending
- Logs command defaults to last entry
