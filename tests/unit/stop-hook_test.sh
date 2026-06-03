#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function set_up_before_script() {
  # See .claude/rules/testing.md — "Sourcing Scripts Under Test"
  local _opts
  _opts=$(shopt -po errexit nounset pipefail 2>/dev/null || true)
  CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT"
  source "$PROJECT_ROOT/hooks/scripts/stop-hook.sh"
  eval "$_opts"
}

function set_up() {
  unset CLAUDE_SESSION_ID 2>/dev/null || true
}

###
### stop::resolve_session_id
###

function test_should_read_session_id_from_stdin_json() {
  local result
  result=$(printf '%s' '{"session_id":"abc-123"}' | stop::resolve_session_id)
  assert_equals "abc-123" "$result"
}

function test_should_fallback_to_env_when_stdin_empty() {
  CLAUDE_SESSION_ID="env-session-456"
  local result
  result=$(stop::resolve_session_id </dev/null)
  assert_equals "env-session-456" "$result"
}

function test_should_return_empty_when_both_absent() {
  CLAUDE_SESSION_ID=""
  local result
  result=$(stop::resolve_session_id </dev/null)
  assert_equals "" "$result"
}

###
### stop::is_process_running
###

function test_should_detect_current_process_as_alive() {
  stop::is_process_running $$
  assert_successful_code
}

function test_should_detect_nonexistent_pid_as_dead() {
  stop::is_process_running 99999999
  assert_general_error
}
