# Changelog

## Unreleased

### Changed

- Removed redundant inline prompt wrappers from correction and translation stages; enhancement stage stripped to dynamic context only
- Agent prompts reviewed and streamlined across all three stages

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
