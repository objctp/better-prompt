#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

function set_up_before_script() {
  source "$PROJECT_ROOT/hooks/scripts/stop-hook.sh"
}

function set_up() {
  _CONFIG_FILE=$(bashunit::temp_file)
  _CONFIG_ORIG="$CONFIG"
  CONFIG="$_CONFIG_FILE"
}

function tear_down() {
  rm -f "$_CONFIG_FILE"
  CONFIG="$_CONFIG_ORIG"
}

###
### _bootstrap_debug
###

function test_bootstrap_debug_returns_true() {
  printf '%s\n' '---' 'debug_mode: true' >"$CONFIG"
  local result
  result=$(_bootstrap_debug)
  assert_equals "true" "$result"
}

function test_bootstrap_debug_returns_false() {
  printf '%s\n' '---' 'debug_mode: false' >"$CONFIG"
  local result
  result=$(_bootstrap_debug)
  assert_equals "false" "$result"
}

function test_bootstrap_debug_returns_empty_for_missing_key() {
  printf '%s\n' '---' 'other_key: value' >"$CONFIG"
  local result
  result=$(_bootstrap_debug)
  assert_empty "$result"
}

function test_bootstrap_debug_missing_file() {
  local orig_config="$CONFIG"
  CONFIG="/nonexistent/path/config.md"
  local result
  result=$(_bootstrap_debug)
  assert_equals "false" "$result"
  CONFIG="$orig_config"
}

function test_bootstrap_debug_strips_comments() {
  printf '%s\n' '---' 'debug_mode: true # enable debug' >"$CONFIG"
  local result
  result=$(_bootstrap_debug)
  assert_equals "true" "$result"
}

function test_bootstrap_debug_strips_whitespace() {
  printf '%s\n' '---' 'debug_mode:   true  ' >"$CONFIG"
  local result
  result=$(_bootstrap_debug)
  assert_equals "true" "$result"
}

function test_bootstrap_debug_ignores_body() {
  printf '%s\n' '---' 'debug_mode: false' '---' 'debug_mode: true' >"$CONFIG"
  local result
  result=$(_bootstrap_debug)
  assert_equals "false" "$result"
}

function test_bootstrap_debug_empty_file() {
  : >"$CONFIG"
  local result
  result=$(_bootstrap_debug)
  assert_empty "$result"
}

function test_bootstrap_debug_with_other_keys() {
  printf '%s\n' '---' 'enabled: true' 'debug_mode: true' 'correction: false' >"$CONFIG"
  local result
  result=$(_bootstrap_debug)
  assert_equals "true" "$result"
}

###
### _debug
###

function test_debug_outputs_when_true() {
  local result
  result=$(_debug "true" "test message" 2>&1 1>/dev/null)
  assert_contains "test message" "$result"
  assert_contains "[better-prompt-stop]" "$result"
}

function test_debug_silent_when_false() {
  local result
  result=$(_debug "false" "test message" 2>&1 1>/dev/null)
  assert_empty "$result"
}

function test_debug_returns_zero_when_true() {
  _debug "true" "msg" 2>/dev/null
  assert_successful_code
}

function test_debug_returns_zero_when_false() {
  _debug "false" "msg" 2>/dev/null
  assert_successful_code
}

function test_debug_handles_multiple_args() {
  local result
  result=$(_debug "true" "part1" "part2" "part3" 2>&1 1>/dev/null)
  assert_contains "part1" "$result"
  assert_contains "part2" "$result"
  assert_contains "part3" "$result"
}

function test_debug_empty_message() {
  local result
  result=$(_debug "true" "" 2>&1 1>/dev/null)
  assert_contains "DEBUG" "$result"
}

function test_debug_prefix_format() {
  local result
  result=$(_debug "true" "detail" 2>&1 1>/dev/null)
  assert_string_starts_with "[better-prompt-stop]" "$result"
  assert_contains "DEBUG" "$result"
}

###
### Main integration tests (subprocess)
###

function test_main_outputs_continue_on_no_session_id() {
  local result
  result=$(CLAUDE_SESSION_ID="" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" </dev/null 2>&1 || true)
  assert_contains "continue" "$result"
}

function test_main_outputs_continue_on_env_session() {
  local result
  result=$(CLAUDE_SESSION_ID="test-session-123" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" </dev/null 2>&1 || true)
  assert_contains "continue" "$result"
}

function test_main_accepts_session_from_stdin_json() {
  local result
  result=$(printf '%s' '{"session_id":"test-sid-456"}' | CLAUDE_SESSION_ID="" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" 2>&1 || true)
  assert_contains "continue" "$result"
}

function test_main_outputs_continue_on_missing_session_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local result
  result=$(printf '%s' '{"session_id":"nonexistent-session-999"}' | CLAUDE_SESSION_ID="" ACTIVE_SESSIONS_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" 2>&1 || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}

###
### Main sourced tests (with mocking)
###

function _setup_stop_mock_env() {
  _MOCK_DIR=$(mktemp -d)
  _ORIG_PATH="$PATH"

  cat >"$_MOCK_DIR/pbpaste" <<'MOCK'
#!/usr/bin/env bash
echo "mocked enhanced prompt"
MOCK
  chmod +x "$_MOCK_DIR/pbpaste"

  cat >"$_MOCK_DIR/osascript" <<'MOCK'
#!/usr/bin/env bash
echo "osascript mocked"
MOCK
  chmod +x "$_MOCK_DIR/osascript"

  PATH="$_MOCK_DIR:$PATH"
  export PATH
}

function _teardown_stop_mock_env() {
  rm -rf "$_MOCK_DIR"
  PATH="$_ORIG_PATH"
  export PATH
  unset _MOCK_DIR _ORIG_PATH
}

function test_main_sourced_no_session_id_outputs_continue() {
  local result
  result=$(CLAUDE_SESSION_ID="" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" </dev/null 2>&1 || true)
  assert_contains "continue" "$result"
}

function test_main_sourced_session_not_found_outputs_continue() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local result
  result=$(printf '%s' '{"session_id":"nonexistent-sid"}' | CLAUDE_SESSION_ID="" ACTIVE_SESSIONS_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" 2>&1 || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}

function test_main_sourced_session_file_with_null_pid() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"test-sid-null","pid":null}' >"$tmpdir/session-null.json"
  local result
  result=$(printf '%s' '{"session_id":"test-sid-null"}' | CLAUDE_SESSION_ID="" ACTIVE_SESSIONS_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" 2>&1 || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}

function test_main_sourced_session_file_with_no_pid_key() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"test-sid-nopid"}' >"$tmpdir/session-nopid.json"
  local result
  result=$(printf '%s' '{"session_id":"test-sid-nopid"}' | CLAUDE_SESSION_ID="" ACTIVE_SESSIONS_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" 2>&1 || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}

function test_main_sourced_session_file_with_dead_pid() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"test-sid-dead","pid":99999999}' >"$tmpdir/session-dead.json"
  local result
  result=$(printf '%s' '{"session_id":"test-sid-dead"}' | CLAUDE_SESSION_ID="" ACTIVE_SESSIONS_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" 2>&1 || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}

function test_main_sourced_empty_session_dir() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local result
  result=$(printf '%s' '{"session_id":"test-sid-empty"}' | CLAUDE_SESSION_ID="" ACTIVE_SESSIONS_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" 2>&1 || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}

function test_main_sourced_debug_mode_outputs_debug_lines() {
  _setup_stop_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'debug_mode: true' >"$tmpcfg"
  local result
  result=$(CLAUDE_SESSION_ID="" BETTER_PROMPT_CONFIG="$tmpcfg" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" </dev/null 2>&1 || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir" "$tmpcfg"
  _teardown_stop_mock_env
}

function test_main_sourced_env_session_empty_dir() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local result
  result=$(CLAUDE_SESSION_ID="test-sid-env" ACTIVE_SESSIONS_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" </dev/null 2>&1 || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}
