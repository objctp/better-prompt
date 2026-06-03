#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function set_up_before_script() {
  # See .claude/rules/testing.md — "Sourcing Scripts Under Test"
  _SESSIONS_DIR=$(mktemp -d)
  _CONFIG_FILE=$(mktemp)
  local _opts
  _opts=$(shopt -po errexit nounset pipefail 2>/dev/null || true)
  CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT"
  BETTER_PROMPT_CONFIG="$_CONFIG_FILE"
  BETTER_PROMPT_SESSIONS_DIR="$_SESSIONS_DIR"
  CLAUDE_PROJECT_DIR="$_SESSIONS_DIR"
  source "$PROJECT_ROOT/hooks/scripts/stop-hook.sh"
  eval "$_opts"
}

function tear_down_after_script() {
  rm -rf "$_SESSIONS_DIR" "$_CONFIG_FILE"
}

function tear_down() {
  rm -f "$_SESSIONS_DIR"/*.json
}

###
### stop::extract_pid
###

function test_should_extract_pid_from_valid_file() {
  local session_file="$_SESSIONS_DIR/extract-test.json"
  printf '{"sessionId":"s1","pid":%s}' "$$" >"$session_file"
  local result
  result=$(stop::extract_pid "$session_file")
  assert_equals "$$" "$result"
}

function test_should_return_empty_for_null_pid() {
  local session_file="$_SESSIONS_DIR/null-pid.json"
  printf '{"sessionId":"s2","pid":null}' >"$session_file"
  local result
  result=$(stop::extract_pid "$session_file")
  assert_equals "" "$result"
}

function test_should_return_empty_for_missing_file() {
  local result
  result=$(stop::extract_pid "")
  assert_equals "" "$result"
}

###
### stop::find_session_pid_file
###

function test_should_find_file_matching_session_id() {
  printf '{"sessionId":"match-1","pid":1234}' >"$_SESSIONS_DIR/s1.json"
  printf '{"sessionId":"other","pid":5678}' >"$_SESSIONS_DIR/s2.json"
  local result
  result=$(stop::find_session_pid_file "match-1")
  assert_contains "s1.json" "$result"
}

function test_should_return_empty_when_no_match() {
  printf '{"sessionId":"other","pid":1234}' >"$_SESSIONS_DIR/s1.json"
  local result
  result=$(stop::find_session_pid_file "no-such-session")
  assert_equals "" "$result"
}

function test_should_return_empty_when_directory_empty() {
  local result
  result=$(stop::find_session_pid_file "any-session")
  assert_equals "" "$result"
}

###
### stop::find_active_cli_session
###

function test_should_find_cli_session_with_matching_cwd_and_alive_pid() {
  printf '{"entrypoint":"cli","cwd":"%s","pid":%s}' "$CLAUDE_PROJECT_DIR" "$$" \
    >"$_SESSIONS_DIR/cli-live.json"
  local result
  result=$(stop::find_active_cli_session)
  assert_contains "cli-live.json" "$result"
}

function test_should_skip_session_with_wrong_cwd() {
  printf '{"entrypoint":"cli","cwd":"/wrong/path","pid":%s}' "$$" \
    >"$_SESSIONS_DIR/cli-wrong.json"
  local result
  result=$(stop::find_active_cli_session)
  assert_equals "" "$result"
}

function test_should_skip_non_cli_entrypoint() {
  printf '{"entrypoint":"api","cwd":"%s","pid":%s}' "$CLAUDE_PROJECT_DIR" "$$" \
    >"$_SESSIONS_DIR/api-session.json"
  local result
  result=$(stop::find_active_cli_session)
  assert_equals "" "$result"
}

function test_should_skip_dead_pid() {
  printf '{"entrypoint":"cli","cwd":"%s","pid":99999999}' "$CLAUDE_PROJECT_DIR" \
    >"$_SESSIONS_DIR/cli-dead.json"
  local result
  result=$(stop::find_active_cli_session)
  assert_equals "" "$result"
}

###
### stop::check_prerequisites
###

function test_should_return_no_session_when_id_empty() {
  local result
  result=$(stop::check_prerequisites "")
  assert_equals "no_session" "$result"
}

function test_should_return_pid_when_session_found_and_alive() {
  printf '{"sessionId":"live-1","pid":%s}' "$$" >"$_SESSIONS_DIR/live.json"
  local result
  result=$(stop::check_prerequisites "live-1")
  assert_equals "$$" "$result"
}

function test_should_return_no_pid_file_when_session_not_found() {
  local result
  result=$(stop::check_prerequisites "ghost-session")
  assert_equals "no_pid_file" "$result"
}

function test_should_return_process_dead_when_pid_not_running() {
  printf '{"sessionId":"dead-1","pid":99999999}' >"$_SESSIONS_DIR/dead.json"
  local result
  result=$(stop::check_prerequisites "dead-1")
  assert_equals "process_dead" "$result"
}
