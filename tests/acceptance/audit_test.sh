#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function set_up_before_script() {
  # Source common.sh only — needed for _config_read_single / file assertions.
  # See .claude/rules/testing.md — "Sourcing Scripts Under Test"
  local _opts
  _opts=$(shopt -po errexit nounset pipefail 2>/dev/null || true)
  source "$PROJECT_ROOT/hooks/scripts/lib/common.sh"
  eval "$_opts"
}

function set_up() {
  _PROJECT_DIR=$(mktemp -d)
  mkdir -p "$_PROJECT_DIR/.claude/better-prompt"
  _AUDIT_FILE="$_PROJECT_DIR/.claude/better-prompt/audit.json"
  cat >"$_AUDIT_FILE" <<'JSONL'
{"date":"2025-01-15T10:00:00","prompt":"first prompt","corrected":"first corrected","enhanced":"first enhanced"}
{"date":"2025-01-15T11:00:00","prompt":"second prompt","corrected":"second corrected"}
{"date":"2025-01-15T12:00:00","prompt":"third prompt"}
JSONL
}

function tear_down() {
  rm -rf "$_PROJECT_DIR"
}

###
### Happy path
###

function test_main_audit_shows_latest_entry_by_default() {
  local result
  result=$(printf '%s' '{"command_args":"","command_name":"better-prompt:audit"}' |
    CLAUDE_PROJECT_DIR="$_PROJECT_DIR" bash "$PROJECT_ROOT/hooks/scripts/audit.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Entry #3" "$reason"
  assert_contains "third prompt" "$reason"
}

function test_main_audit_shows_n_entries() {
  local result
  result=$(printf '%s' '{"command_args":"2","command_name":"better-prompt:audit"}' |
    CLAUDE_PROJECT_DIR="$_PROJECT_DIR" bash "$PROJECT_ROOT/hooks/scripts/audit.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "Entry #2" "$reason"
  assert_contains "second prompt" "$reason"
  assert_contains "Entry #3" "$reason"
  assert_contains "third prompt" "$reason"
}

function test_main_audit_clears_log() {
  assert_file_exists "$_AUDIT_FILE"
  local result
  result=$(printf '%s' '{"command_args":"--clear","command_name":"better-prompt:audit"}' |
    CLAUDE_PROJECT_DIR="$_PROJECT_DIR" bash "$PROJECT_ROOT/hooks/scripts/audit.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "cleared" "$reason"
  assert_file_not_exists "$_AUDIT_FILE"
}

###
### Validation errors
###

function test_main_audit_shows_usage_for_invalid_args() {
  local result
  result=$(printf '%s' '{"command_args":"abc","command_name":"better-prompt:audit"}' |
    CLAUDE_PROJECT_DIR="$_PROJECT_DIR" bash "$PROJECT_ROOT/hooks/scripts/audit.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Usage" "$reason"
}

###
### Edge cases
###

function test_main_audit_passes_through_on_empty_payload() {
  local result
  result=$(echo "" | CLAUDE_PROJECT_DIR="$_PROJECT_DIR" bash "$PROJECT_ROOT/hooks/scripts/audit.sh" 2>/dev/null || true)
  assert_empty "$result"
}

function test_main_audit_reports_no_log_file() {
  local result
  result=$(printf '%s' '{"command_args":"","command_name":"better-prompt:audit"}' |
    CLAUDE_PROJECT_DIR="/nonexistent/path" bash "$PROJECT_ROOT/hooks/scripts/audit.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "No audit log found" "$reason"
}

function test_main_audit_reports_empty_log() {
  : >"$_AUDIT_FILE"
  local result
  result=$(printf '%s' '{"command_args":"","command_name":"better-prompt:audit"}' |
    CLAUDE_PROJECT_DIR="$_PROJECT_DIR" bash "$PROJECT_ROOT/hooks/scripts/audit.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "empty" "$reason"
}

function test_main_audit_clear_reports_nothing_to_clear() {
  rm -f "$_AUDIT_FILE"
  local result
  result=$(printf '%s' '{"command_args":"--clear","command_name":"better-prompt:audit"}' |
    CLAUDE_PROJECT_DIR="$_PROJECT_DIR" bash "$PROJECT_ROOT/hooks/scripts/audit.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "nothing to clear" "$reason"
}
