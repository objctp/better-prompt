#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function set_up() {
  _SESSIONS_DIR=$(mktemp -d)
  _CONFIG_FILE=$(bashunit::temp_file)
  printf '%s\n' '---' 'verbose: false' '---' >"$_CONFIG_FILE"
}

function tear_down() {
  rm -rf "$_SESSIONS_DIR"
  rm -f "$_CONFIG_FILE"
}

###
### Early exit: no session
###

function test_main_passes_through_when_no_session_id() {
  local result
  result=$(printf '' |
    CLAUDE_SESSION_ID="" \
      BETTER_PROMPT_CONFIG="$_CONFIG_FILE" \
      BETTER_PROMPT_SESSIONS_DIR="$_SESSIONS_DIR" \
      CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
      bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
}

###
### Early exit: no PID file
###

function test_main_passes_through_when_no_matching_session_file() {
  local result
  result=$(printf '%s' '{"session_id":"ghost-session"}' |
    CLAUDE_SESSION_ID="ghost-session" \
      BETTER_PROMPT_CONFIG="$_CONFIG_FILE" \
      BETTER_PROMPT_SESSIONS_DIR="$_SESSIONS_DIR" \
      CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
      bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
}

###
### Early exit: dead process
###

function test_main_passes_through_when_session_process_dead() {
  printf '{"sessionId":"dead-session","pid":99999999}' >"$_SESSIONS_DIR/dead.json"
  local result
  result=$(printf '%s' '{"session_id":"dead-session"}' |
    CLAUDE_SESSION_ID="dead-session" \
      BETTER_PROMPT_CONFIG="$_CONFIG_FILE" \
      BETTER_PROMPT_SESSIONS_DIR="$_SESSIONS_DIR" \
      CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
      bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
}
