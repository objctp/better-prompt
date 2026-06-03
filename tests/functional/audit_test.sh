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
  _AUDIT_FILE=$(bashunit::temp_file)
  cat >"$_AUDIT_FILE" <<'JSONL'
{"date":"2025-01-15T10:00:00","prompt":"first prompt","corrected":"first corrected","enhanced":"first enhanced"}
{"date":"2025-01-15T11:00:00","prompt":"second prompt","corrected":"second corrected"}
{"date":"2025-01-15T12:00:00","prompt":"third prompt"}
JSONL
}

function tear_down() {
  rm -f "$_AUDIT_FILE"
}

###
### audit::format_entries — happy path
###

function test_should_format_single_latest_entry() {
  local result
  result=$(audit::format_entries "$_AUDIT_FILE" 1)
  assert_successful_code
  assert_contains "Entry #3" "$result"
  assert_contains "third prompt" "$result"
  assert_not_contains "first prompt" "$result"
}

function test_should_format_multiple_recent_entries() {
  local result
  result=$(audit::format_entries "$_AUDIT_FILE" 2)
  assert_successful_code
  assert_contains "Entry #2" "$result"
  assert_contains "second prompt" "$result"
  assert_contains "Entry #3" "$result"
  assert_contains "third prompt" "$result"
  assert_not_contains "first prompt" "$result"
}

function test_should_format_all_entries() {
  local result
  result=$(audit::format_entries "$_AUDIT_FILE" 3)
  assert_successful_code
  assert_contains "Entry #1" "$result"
  assert_contains "first prompt" "$result"
  assert_contains "Entry #2" "$result"
  assert_contains "second prompt" "$result"
  assert_contains "Entry #3" "$result"
  assert_contains "third prompt" "$result"
}

function test_should_format_all_when_count_exceeds_total() {
  local result
  result=$(audit::format_entries "$_AUDIT_FILE" 100)
  assert_successful_code
  assert_contains "Entry #1" "$result"
  assert_contains "Entry #3" "$result"
}

###
### audit::format_entries — error conditions
###

function test_should_fail_when_file_not_found() {
  audit::format_entries "/nonexistent/file.json" 1
  assert_general_error
}

function test_should_fail_when_file_is_empty() {
  : >"$_AUDIT_FILE"
  audit::format_entries "$_AUDIT_FILE" 1
  assert_general_error
}

###
### Sequential reads
###

function test_should_produce_same_output_on_repeated_reads() {
  local r1 r2
  r1=$(audit::format_entries "$_AUDIT_FILE" 2)
  r2=$(audit::format_entries "$_AUDIT_FILE" 2)
  assert_equals "$r1" "$r2"
}

###
### Mixed content
###

function test_should_skip_blank_lines_in_audit_file() {
  echo "" >>"$_AUDIT_FILE"
  local result
  result=$(audit::format_entries "$_AUDIT_FILE" 100)
  assert_successful_code
  assert_contains "Entry #1" "$result"
  assert_contains "Entry #3" "$result"
}

function test_should_handle_malformed_line_alongside_valid() {
  echo "bad-json" >>"$_AUDIT_FILE"
  local result
  result=$(audit::format_entries "$_AUDIT_FILE" 100)
  assert_successful_code
  assert_contains "Entry #3" "$result"
  assert_contains "Entry #4" "$result"
  assert_contains "bad-json" "$result"
}
