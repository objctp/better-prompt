#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function set_up_before_script() {
  # See .claude/rules/testing.md — "Sourcing Scripts Under Test"
  local _opts
  _opts=$(shopt -po errexit nounset pipefail 2>/dev/null || true)
  CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT"
  source "$PROJECT_ROOT/hooks/scripts/audit.sh"
  eval "$_opts"
}

function set_up() {
  unset CLAUDE_PROJECT_DIR
}

###
### audit::path
###

function test_should_use_default_dir_when_project_dir_unset() {
  local result
  result=$(audit::path)
  assert_equals "./.claude/better-prompt/audit.json" "$result"
}

function test_should_use_project_dir_when_set() {
  CLAUDE_PROJECT_DIR="/tmp/test-project"
  local result
  result=$(audit::path)
  assert_equals "/tmp/test-project/.claude/better-prompt/audit.json" "$result"
}

function test_should_not_strip_trailing_slash() {
  CLAUDE_PROJECT_DIR="/tmp/test-project/"
  local result
  result=$(audit::path)
  assert_equals "/tmp/test-project//.claude/better-prompt/audit.json" "$result"
}

###
### audit::format_entry — minimal entry
###

function test_should_format_minimal_entry_with_date_and_prompt() {
  local entry='{"date":"2025-01-15T10:30:00","prompt":"hello world"}'
  local result
  result=$(audit::format_entry "$entry" 1)
  assert_contains "Entry #1" "$result"
  assert_contains "Date:" "$result"
  assert_contains "2025-01-15T10:30:00" "$result"
  assert_contains "Prompt:" "$result"
  assert_contains "hello world" "$result"
}

function test_should_show_unknown_date_when_missing() {
  local entry='{"prompt":"hello"}'
  local result
  result=$(audit::format_entry "$entry" 2)
  assert_contains "unknown" "$result"
}

###
### audit::format_entry — full entry
###

function test_should_format_full_entry_with_all_fields() {
  local entry
  entry='{"date":"2025-01-15T10:30:00","prompt":"hello","corrected":"helo world","enhanced":"Hello World","mistake-nature":["spelling"],"models":{"correction":"haiku","enhancement":"sonnet"},"mistakes":[{"type":"spelling","original":"helo","correction":"hello"}]}'
  local result
  result=$(audit::format_entry "$entry" 3)
  assert_contains "Entry #3" "$result"
  assert_contains "Date:" "$result"
  assert_contains "Prompt:" "$result"
  assert_contains "Corrected:" "$result"
  assert_contains "helo world" "$result"
  assert_contains "Enhanced:" "$result"
  assert_contains "Hello World" "$result"
  assert_contains "Mistakes:" "$result"
  assert_contains "spelling" "$result"
  assert_contains "Models:" "$result"
  assert_contains "correction=haiku" "$result"
  assert_contains "enhancement=sonnet" "$result"
}

###
### audit::format_entry — conditional field display
###

function test_should_omit_corrected_when_same_as_prompt() {
  local entry='{"date":"2025-01-15","prompt":"hello","corrected":"hello"}'
  local result
  result=$(audit::format_entry "$entry" 1)
  assert_contains "Prompt:" "$result"
  assert_not_contains "Corrected:" "$result"
}

function test_should_omit_enhanced_when_same_as_corrected() {
  local entry='{"date":"2025-01-15","prompt":"hi","corrected":"hello","enhanced":"hello"}'
  local result
  result=$(audit::format_entry "$entry" 1)
  assert_contains "Corrected:" "$result"
  assert_not_contains "Enhanced:" "$result"
}

function test_should_omit_mistakes_when_empty_array() {
  local entry='{"date":"2025-01-15","prompt":"hello","mistakes":[]}'
  local result
  result=$(audit::format_entry "$entry" 1)
  assert_not_contains "Mistakes:" "$result"
}

function test_should_omit_models_when_empty_object() {
  local entry='{"date":"2025-01-15","prompt":"hello","models":{}}'
  local result
  result=$(audit::format_entry "$entry" 1)
  assert_not_contains "Models:" "$result"
}

function test_should_omit_mistakes_and_models_when_missing() {
  local entry='{"date":"2025-01-15","prompt":"hello"}'
  local result
  result=$(audit::format_entry "$entry" 1)
  assert_not_contains "Mistakes:" "$result"
  assert_not_contains "Models:" "$result"
}

###
### audit::format_entry — malformed JSON fallback
###

function test_should_show_raw_entry_on_malformed_json() {
  local result
  result=$(audit::format_entry "not-json-at-all" 5)
  assert_contains "Entry #5" "$result"
  assert_contains "not-json-at-all" "$result"
}
