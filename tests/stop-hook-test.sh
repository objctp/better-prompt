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
  local _OUT
  _OUT=$(bashunit::temp_file)
  _bootstrap_debug >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "true" "$result"
}

function test_bootstrap_debug_returns_false() {
  printf '%s\n' '---' 'debug_mode: false' >"$CONFIG"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _bootstrap_debug >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "false" "$result"
}

function test_bootstrap_debug_returns_empty_for_missing_key() {
  printf '%s\n' '---' 'other_key: value' >"$CONFIG"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _bootstrap_debug >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

function test_bootstrap_debug_missing_file() {
  local orig_config="$CONFIG"
  CONFIG="/nonexistent/path/config.md"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _bootstrap_debug >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "false" "$result"
  CONFIG="$orig_config"
}

function test_bootstrap_debug_strips_comments() {
  printf '%s\n' '---' 'debug_mode: true # enable debug' >"$CONFIG"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _bootstrap_debug >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "true" "$result"
}

function test_bootstrap_debug_strips_whitespace() {
  printf '%s\n' '---' 'debug_mode:   true  ' >"$CONFIG"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _bootstrap_debug >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "true" "$result"
}

function test_bootstrap_debug_ignores_body() {
  printf '%s\n' '---' 'debug_mode: false' '---' 'debug_mode: true' >"$CONFIG"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _bootstrap_debug >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "false" "$result"
}

function test_bootstrap_debug_empty_file() {
  : >"$CONFIG"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _bootstrap_debug >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

function test_bootstrap_debug_with_other_keys() {
  printf '%s\n' '---' 'enabled: true' 'debug_mode: true' 'correction: false' >"$CONFIG"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _bootstrap_debug >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "true" "$result"
}

###
### _debug
###

function test_debug_outputs_when_true() {
  local _ERR
  _ERR=$(bashunit::temp_file)
  _debug "true" "test message" 2>"$_ERR" 1>/dev/null
  local result
  result=$(cat "$_ERR")
  assert_contains "test message" "$result"
  assert_contains "[better-prompt-stop]" "$result"
}

function test_debug_silent_when_false() {
  local _ERR
  _ERR=$(bashunit::temp_file)
  _debug "false" "test message" 2>"$_ERR" 1>/dev/null
  local result
  result=$(cat "$_ERR")
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
  local _ERR
  _ERR=$(bashunit::temp_file)
  _debug "true" "part1" "part2" "part3" 2>"$_ERR" 1>/dev/null
  local result
  result=$(cat "$_ERR")
  assert_contains "part1" "$result"
  assert_contains "part2" "$result"
  assert_contains "part3" "$result"
}

function test_debug_empty_message() {
  local _ERR
  _ERR=$(bashunit::temp_file)
  _debug "true" "" 2>"$_ERR" 1>/dev/null
  local result
  result=$(cat "$_ERR")
  assert_contains "DEBUG" "$result"
}

function test_debug_prefix_format() {
  local _ERR
  _ERR=$(bashunit::temp_file)
  _debug "true" "detail" 2>"$_ERR" 1>/dev/null
  local result
  result=$(cat "$_ERR")
  assert_string_starts_with "[better-prompt-stop]" "$result"
  assert_contains "DEBUG" "$result"
}

###
### stop_resolve_session_id
###

function test_resolve_session_id_from_stdin_json() {
  local _IN
  _IN=$(bashunit::temp_file)
  local _OUT
  _OUT=$(bashunit::temp_file)
  printf '%s' '{"session_id":"test-sid-456"}' >"$_IN"
  stop_resolve_session_id <"$_IN" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "test-sid-456" "$result"
}

function test_resolve_session_id_from_env_on_tty() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  local _OLD_SID="${CLAUDE_SESSION_ID:-}"
  CLAUDE_SESSION_ID="env-sid-789"
  stop_resolve_session_id </dev/null >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "env-sid-789" "$result"
  CLAUDE_SESSION_ID="$_OLD_SID"
}

function test_resolve_session_id_empty_input() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  local _OLD_SID="${CLAUDE_SESSION_ID:-}"
  CLAUDE_SESSION_ID=""
  stop_resolve_session_id </dev/null >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
  CLAUDE_SESSION_ID="$_OLD_SID"
}

function test_resolve_session_id_empty_json_session() {
  local _IN
  _IN=$(bashunit::temp_file)
  local _OUT
  _OUT=$(bashunit::temp_file)
  printf '%s' '{"session_id":""}' >"$_IN"
  local _OLD_SID="${CLAUDE_SESSION_ID:-}"
  CLAUDE_SESSION_ID=""
  stop_resolve_session_id <"$_IN" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
  CLAUDE_SESSION_ID="$_OLD_SID"
}

###
### stop_find_session_pid_file
###

function test_find_session_pid_file_match() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"abc-123","pid":12345}' >"$tmpdir/session1.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_find_session_pid_file "abc-123" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "$tmpdir/session1.json" "$result"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_find_session_pid_file_no_match() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"other-session","pid":99999}' >"$tmpdir/session1.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_find_session_pid_file "abc-123" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_find_session_pid_file_empty_dir() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_find_session_pid_file "abc-123" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_find_session_pid_file_multiple() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"first","pid":1111}' >"$tmpdir/a.json"
  printf '%s' '{"sessionId":"target-sid","pid":2222}' >"$tmpdir/b.json"
  printf '%s' '{"sessionId":"third","pid":3333}' >"$tmpdir/c.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_find_session_pid_file "target-sid" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "$tmpdir/b.json" "$result"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

###
### stop_extract_pid
###

function test_extract_pid_valid() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"test","pid":12345}' >"$tmpdir/ses.json"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_extract_pid "$tmpdir/ses.json" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "12345" "$result"
  rm -rf "$tmpdir"
}

function test_extract_pid_null() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"test","pid":null}' >"$tmpdir/ses.json"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_extract_pid "$tmpdir/ses.json" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
  rm -rf "$tmpdir"
}

function test_extract_pid_missing_key() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"test"}' >"$tmpdir/ses.json"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_extract_pid "$tmpdir/ses.json" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
  rm -rf "$tmpdir"
}

function test_extract_pid_empty_path() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_extract_pid "" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

function test_extract_pid_nonexistent_file() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_extract_pid "/nonexistent/file.json" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

function test_extract_pid_string_pid() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"test","pid":"not-a-number"}' >"$tmpdir/ses.json"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_extract_pid "$tmpdir/ses.json" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "not-a-number" "$result"
  rm -rf "$tmpdir"
}

###
### stop_is_process_running
###

function test_is_process_running_current_shell() {
  stop_is_process_running $$
  assert_successful_code
}

function test_is_process_running_nonexistent() {
  stop_is_process_running 99999999
  assert_general_error
}

###
### stop_read_clipboard (mocked)
###

function test_read_clipboard_macos_mock() {
  if [[ "$_IS_MACOS" != true ]]; then
    return 0
  fi
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/pbpaste" <<'MOCK'
#!/usr/bin/env bash
echo "mocked clipboard content"
MOCK
  chmod +x "$mock_dir/pbpaste"
  PATH="$mock_dir:$PATH"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_read_clipboard >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "mocked clipboard content" "$result"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_read_clipboard_macos_pbpaste_fails() {
  if [[ "$_IS_MACOS" != true ]]; then
    return 0
  fi
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/pbpaste" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock_dir/pbpaste"
  PATH="$mock_dir:$PATH"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_read_clipboard >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_read_clipboard_linux_xclip_mock() {
  if [[ "$_IS_MACOS" == true ]]; then
    local _OUT
    _OUT=$(bashunit::temp_file)
    stop_read_clipboard >"$_OUT"
    assert_successful_code
    return 0
  fi
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/xclip" <<'MOCK'
#!/usr/bin/env bash
echo "mocked xclip content"
MOCK
  chmod +x "$mock_dir/xclip"
  PATH="$mock_dir:$PATH"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_read_clipboard >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "mocked xclip content" "$result"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_read_clipboard_linux_xsel_mock() {
  if [[ "$_IS_MACOS" == true ]]; then
    assert_successful_code
    return 0
  fi
  local _OUT
  _OUT=$(bashunit::temp_file)
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/xsel" <<'MOCK'
#!/usr/bin/env bash
echo "mocked xsel content"
MOCK
  chmod +x "$mock_dir/xsel"
  PATH="$mock_dir"
  stop_read_clipboard >"$_OUT"
  PATH="$orig_path"
  export PATH
  local result
  result=$(<"$_OUT")
  assert_contains "mocked xsel content" "$result"
  rm -rf "$mock_dir"
}

function test_read_clipboard_linux_no_utility() {
  if [[ "$_IS_MACOS" == true ]]; then
    assert_successful_code
    return 0
  fi
  local _OUT
  _OUT=$(bashunit::temp_file)
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  PATH="$mock_dir"
  stop_read_clipboard >"$_OUT"
  PATH="$orig_path"
  export PATH
  local result
  result=$(<"$_OUT")
  assert_empty "$result"
  rm -rf "$mock_dir"
}

###
### stop_send_rewind_sequence
###

function test_send_rewind_sequence_is_function() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  type -t stop_send_rewind_sequence >"$_OUT" 2>/dev/null || true
  local result
  result=$(cat "$_OUT")
  assert_equals "function" "$result"
}

function test_send_rewind_sequence_macos_branch() {
  if [[ "$_IS_MACOS" == true ]]; then
    stop_send_rewind_sequence "false" || true
    assert_successful_code
  else
    stop_send_rewind_sequence "false" || true
    assert_successful_code
  fi
}

function test_send_rewind_sequence_tool_not_found() {
  local _ERR
  _ERR=$(bashunit::temp_file)
  function sleep() { :; }
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  PATH="$mock_dir"
  stop_send_rewind_sequence "true" 2>"$_ERR" || true
  PATH="$orig_path"
  export PATH
  local result
  result=$(<"$_ERR")
  if [[ "$_IS_MACOS" == true ]]; then
    assert_contains "osascript not found" "$result"
  else
    assert_contains "ydotool not found" "$result"
  fi
  unset -f sleep
  rm -rf "$mock_dir"
}

function test_send_rewind_sequence_success_mocked() {
  function sleep() { :; }
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  if [[ "$_IS_MACOS" == true ]]; then
    cat >"$mock_dir/osascript" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$mock_dir/osascript"
  else
    cat >"$mock_dir/ydotool" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$mock_dir/ydotool"
  fi
  PATH="$mock_dir:$PATH"
  local _ERR
  _ERR=$(bashunit::temp_file)
  stop_send_rewind_sequence "true" 2>"$_ERR" || true
  assert_successful_code
  unset -f sleep
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
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
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'debug_mode: true' >"$tmpcfg"
  local result
  result=$(CLAUDE_SESSION_ID="" BETTER_PROMPT_CONFIG="$tmpcfg" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" </dev/null 2>&1 || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir" "$tmpcfg"
}

function test_main_sourced_env_session_empty_dir() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local result
  result=$(CLAUDE_SESSION_ID="test-sid-env" ACTIVE_SESSIONS_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/stop-hook.sh" </dev/null 2>&1 || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}

###
### stop_check_prerequisites
###

function test_check_prerequisites_no_session() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_check_prerequisites "false" "" >"$_OUT"
  local reason
  reason=$(cat "$_OUT")
  assert_equals "no_session" "$reason"
}

function test_check_prerequisites_no_pid_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_check_prerequisites "false" "missing-session-999" >"$_OUT"
  local reason
  reason=$(cat "$_OUT")
  assert_equals "no_pid_file" "$reason"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_check_prerequisites_null_pid() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"abc-null-pid","pid":null}' >"$tmpdir/session-null.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_check_prerequisites "false" "abc-null-pid" >"$_OUT"
  local reason
  reason=$(cat "$_OUT")
  assert_equals "no_pid" "$reason"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_check_prerequisites_no_pid_key() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"abc-no-pid"}' >"$tmpdir/session-nopid.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_check_prerequisites "false" "abc-no-pid" >"$_OUT"
  local reason
  reason=$(cat "$_OUT")
  assert_equals "no_pid" "$reason"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_check_prerequisites_dead_process() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"abc-dead","pid":99999999}' >"$tmpdir/session-dead.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_check_prerequisites "false" "abc-dead" >"$_OUT"
  local reason
  reason=$(cat "$_OUT")
  assert_equals "process_dead" "$reason"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_check_prerequisites_process_alive() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' "{\"sessionId\":\"abc-alive\",\"pid\":$$}" >"$tmpdir/session-alive.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_check_prerequisites "false" "abc-alive" >"$_OUT"
  local reason
  reason=$(cat "$_OUT")
  assert_empty "$reason"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_check_prerequisites_debug_output() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' "{\"sessionId\":\"dbg-sid\",\"pid\":$$}" >"$tmpdir/session-dbg.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _ERR
  _ERR=$(bashunit::temp_file)
  stop_check_prerequisites "true" "dbg-sid" >/dev/null 2>"$_ERR"
  local result
  result=$(cat "$_ERR")
  assert_contains "Stop hook fired" "$result"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_check_prerequisites_debug_no_session() {
  local _ERR
  _ERR=$(bashunit::temp_file)
  stop_check_prerequisites "true" "" >/dev/null 2>"$_ERR"
  local result
  result=$(cat "$_ERR")
  assert_contains "No session ID found" "$result"
}

function test_check_prerequisites_debug_no_pid_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  local _ERR
  _ERR=$(bashunit::temp_file)
  stop_check_prerequisites "true" "nonexistent-sid" >"$_OUT" 2>"$_ERR"
  local reason
  reason=$(cat "$_OUT")
  local dbg
  dbg=$(cat "$_ERR")
  assert_equals "no_pid_file" "$reason"
  assert_contains "Session PID file not found" "$dbg"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_check_prerequisites_debug_null_pid() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"dbg-null-pid","pid":null}' >"$tmpdir/session-null.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  local _ERR
  _ERR=$(bashunit::temp_file)
  stop_check_prerequisites "true" "dbg-null-pid" >"$_OUT" 2>"$_ERR"
  local reason
  reason=$(cat "$_OUT")
  local dbg
  dbg=$(cat "$_ERR")
  assert_equals "no_pid" "$reason"
  assert_contains "Failed to extract PID" "$dbg"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_check_prerequisites_debug_dead_process() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' '{"sessionId":"dbg-dead","pid":99999999}' >"$tmpdir/session-dead.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  local _ERR
  _ERR=$(bashunit::temp_file)
  stop_check_prerequisites "true" "dbg-dead" >"$_OUT" 2>"$_ERR"
  local reason
  reason=$(cat "$_OUT")
  local dbg
  dbg=$(cat "$_ERR")
  assert_equals "process_dead" "$reason"
  assert_contains "not running" "$dbg"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_check_prerequisites_debug_found_pid() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' "{\"sessionId\":\"dbg-alive\",\"pid\":$$}" >"$tmpdir/session-dbg-alive.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  local _ERR
  _ERR=$(bashunit::temp_file)
  stop_check_prerequisites "true" "dbg-alive" >"$_OUT" 2>"$_ERR"
  local reason
  reason=$(cat "$_OUT")
  local dbg
  dbg=$(cat "$_ERR")
  assert_empty "$reason"
  assert_contains "Found session PID" "$dbg"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

###
### stop_attempt_rewind
###

function test_attempt_rewind_empty_clipboard() {
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  if [[ "$_IS_MACOS" == true ]]; then
    cat >"$mock_dir/pbpaste" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$mock_dir/pbpaste"
  else
    cat >"$mock_dir/xclip" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$mock_dir/xclip"
  fi
  PATH="$mock_dir:$PATH"
  REWIND_RESULT=""
  stop_attempt_rewind "false"
  assert_equals "clipboard_empty" "$REWIND_RESULT"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_attempt_rewind_rewind_failed() {
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  if [[ "$_IS_MACOS" == true ]]; then
    cat >"$mock_dir/pbpaste" <<'MOCK'
#!/usr/bin/env bash
echo "mocked clipboard content"
MOCK
    chmod +x "$mock_dir/pbpaste"
  else
    cat >"$mock_dir/xclip" <<'MOCK'
#!/usr/bin/env bash
echo "mocked clipboard content"
MOCK
    chmod +x "$mock_dir/xclip"
  fi
  PATH="$mock_dir:$PATH"
  _orig_send_rewind=$(declare -f stop_send_rewind_sequence)
  function stop_send_rewind_sequence() { return 1; }
  REWIND_RESULT=""
  stop_attempt_rewind "false"
  assert_equals "rewind_failed" "$REWIND_RESULT"
  eval "$_orig_send_rewind"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_attempt_rewind_success() {
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  if [[ "$_IS_MACOS" == true ]]; then
    cat >"$mock_dir/pbpaste" <<'MOCK'
#!/usr/bin/env bash
echo "mocked clipboard content"
MOCK
    chmod +x "$mock_dir/pbpaste"
  else
    cat >"$mock_dir/xclip" <<'MOCK'
#!/usr/bin/env bash
echo "mocked clipboard content"
MOCK
    chmod +x "$mock_dir/xclip"
  fi
  PATH="$mock_dir:$PATH"
  _orig_send_rewind=$(declare -f stop_send_rewind_sequence)
  function stop_send_rewind_sequence() { return 0; }
  REWIND_RESULT=""
  stop_attempt_rewind "false"
  assert_empty "$REWIND_RESULT"
  eval "$_orig_send_rewind"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_attempt_rewind_debug_empty_clipboard() {
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  if [[ "$_IS_MACOS" == true ]]; then
    cat >"$mock_dir/pbpaste" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$mock_dir/pbpaste"
  else
    cat >"$mock_dir/xclip" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$mock_dir/xclip"
  fi
  PATH="$mock_dir:$PATH"
  local _ERR
  _ERR=$(bashunit::temp_file)
  REWIND_RESULT=""
  stop_attempt_rewind "true" 2>"$_ERR"
  assert_equals "clipboard_empty" "$REWIND_RESULT"
  local dbg
  dbg=$(cat "$_ERR")
  assert_contains "Clipboard empty" "$dbg"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_attempt_rewind_debug_rewind_failed() {
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  if [[ "$_IS_MACOS" == true ]]; then
    cat >"$mock_dir/pbpaste" <<'MOCK'
#!/usr/bin/env bash
echo "mocked clipboard content"
MOCK
    chmod +x "$mock_dir/pbpaste"
  else
    cat >"$mock_dir/xclip" <<'MOCK'
#!/usr/bin/env bash
echo "mocked clipboard content"
MOCK
    chmod +x "$mock_dir/xclip"
  fi
  PATH="$mock_dir:$PATH"
  _orig_send_rewind=$(declare -f stop_send_rewind_sequence)
  function stop_send_rewind_sequence() { return 1; }
  REWIND_RESULT=""
  stop_attempt_rewind "true"
  assert_equals "rewind_failed" "$REWIND_RESULT"
  eval "$_orig_send_rewind"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_debug_direct_call_stderr_file_redirect() {
  local _ERR
  _ERR=$(bashunit::temp_file)
  _debug "true" "direct stderr check" 2>"$_ERR"
  local result
  result=$(cat "$_ERR")
  assert_contains "[better-prompt-stop] DEBUG: direct stderr check" "$result"
}

function test_debug_direct_call_false_produces_no_stderr() {
  local _ERR
  _ERR=$(bashunit::temp_file)
  _debug "false" "should not appear" 2>"$_ERR"
  local result
  result=$(cat "$_ERR")
  assert_empty "$result"
}

function test_send_rewind_sequence_macos_osascript_not_found() {
  local orig_macos="$_IS_MACOS"
  _IS_MACOS=true
  function sleep() { :; }
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  PATH="$mock_dir"
  local _ERR
  _ERR=$(bashunit::temp_file)
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_send_rewind_sequence "true" >"$_OUT" 2>"$_ERR" || true
  PATH="$orig_path"
  export PATH
  local result
  result=$(cat "$_ERR")
  assert_contains "osascript not found" "$result"
  _IS_MACOS="$orig_macos"
  unset -f sleep
  rm -rf "$mock_dir"
}

function test_send_rewind_sequence_macos_osascript_success() {
  local orig_macos="$_IS_MACOS"
  _IS_MACOS=true
  function sleep() { :; }
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/osascript" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$mock_dir/osascript"
  PATH="$mock_dir:$PATH"
  local _ERR
  _ERR=$(bashunit::temp_file)
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_send_rewind_sequence "true" >"$_OUT" 2>"$_ERR"
  local result
  result=$(cat "$_ERR")
  assert_contains "Sending rewind sequence via osascript" "$result"
  assert_contains "Rewind sequence sent" "$result"
  _IS_MACOS="$orig_macos"
  unset -f sleep
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_send_rewind_sequence_macos_osascript_fails() {
  local orig_macos="$_IS_MACOS"
  _IS_MACOS=true
  function sleep() { :; }
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/osascript" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock_dir/osascript"
  PATH="$mock_dir:$PATH"
  local _ERR
  _ERR=$(bashunit::temp_file)
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_send_rewind_sequence "true" >"$_OUT" 2>"$_ERR" || true
  local result
  result=$(cat "$_ERR")
  assert_contains "osascript failed" "$result"
  _IS_MACOS="$orig_macos"
  unset -f sleep
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_send_rewind_sequence_linux_ydotool_success() {
  local orig_macos="$_IS_MACOS"
  _IS_MACOS=false
  function sleep() { :; }
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/ydotool" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$mock_dir/ydotool"
  PATH="$mock_dir:$PATH"
  local _ERR
  _ERR=$(bashunit::temp_file)
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_send_rewind_sequence "true" >"$_OUT" 2>"$_ERR"
  local result
  result=$(cat "$_ERR")
  assert_contains "Sending rewind sequence via ydotool" "$result"
  assert_contains "Rewind sequence sent" "$result"
  _IS_MACOS="$orig_macos"
  unset -f sleep
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_send_rewind_sequence_linux_ydotool_ctrl_v_fails() {
  local orig_macos="$_IS_MACOS"
  _IS_MACOS=false
  function sleep() { :; }
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/ydotool" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock_dir/ydotool"
  PATH="$mock_dir:$PATH"
  local _ERR
  _ERR=$(bashunit::temp_file)
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_send_rewind_sequence "true" >"$_OUT" 2>"$_ERR" || true
  local result
  result=$(cat "$_ERR")
  assert_contains "ydotool Ctrl+V failed" "$result"
  _IS_MACOS="$orig_macos"
  unset -f sleep
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_send_rewind_sequence_linux_ydotool_enter_fails() {
  local orig_macos="$_IS_MACOS"
  _IS_MACOS=false
  function sleep() { :; }
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/ydotool" <<'MOCK'
#!/usr/bin/env bash
if [[ "$2" == "28:1" ]]; then
  exit 1
fi
exit 0
MOCK
  chmod +x "$mock_dir/ydotool"
  PATH="$mock_dir:$PATH"
  local _ERR
  _ERR=$(bashunit::temp_file)
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_send_rewind_sequence "true" >"$_OUT" 2>"$_ERR" || true
  local result
  result=$(cat "$_ERR")
  assert_contains "ydotool Enter failed" "$result"
  _IS_MACOS="$orig_macos"
  unset -f sleep
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_send_rewind_sequence_linux_no_ydotool() {
  local orig_macos="$_IS_MACOS"
  _IS_MACOS=false
  function sleep() { :; }
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  local _ERR
  _ERR=$(bashunit::temp_file)
  local _OUT
  _OUT=$(bashunit::temp_file)
  PATH="$mock_dir:$PATH"
  stop_send_rewind_sequence "true" >"$_OUT" 2>"$_ERR" || true
  local result
  result=$(cat "$_ERR")
  _IS_MACOS="$orig_macos"
  unset -f sleep
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
  assert_contains "ydotool not found" "$result"
}

function test_send_rewind_sequence_debug_messages_linux_ydotool_not_found() {
  local orig_macos="$_IS_MACOS"
  _IS_MACOS=false
  function sleep() { :; }
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  local _ERR
  _ERR=$(bashunit::temp_file)
  local _OUT
  _OUT=$(bashunit::temp_file)
  PATH="$mock_dir:$PATH"
  stop_send_rewind_sequence "true" >"$_OUT" 2>"$_ERR" || true
  local result
  result=$(cat "$_ERR")
  _IS_MACOS="$orig_macos"
  unset -f sleep
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
  assert_contains "[better-prompt-stop]" "$result"
  assert_contains "ydotool not found" "$result"
}

function test_read_clipboard_linux_xclip_forced() {
  local orig_macos="$_IS_MACOS"
  _IS_MACOS=false
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/xclip" <<'MOCK'
#!/usr/bin/env bash
echo "forced xclip content"
MOCK
  chmod +x "$mock_dir/xclip"
  PATH="$mock_dir:$PATH"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_read_clipboard >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "forced xclip content" "$result"
  _IS_MACOS="$orig_macos"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_read_clipboard_linux_xsel_forced() {
  if [[ "$_IS_MACOS" == true ]]; then
    assert_successful_code
    return 0
  fi
  local orig_macos="$_IS_MACOS"
  _IS_MACOS=false
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/xsel" <<'MOCK'
#!/usr/bin/env bash
echo "forced xsel content"
MOCK
  chmod +x "$mock_dir/xsel"
  PATH="$mock_dir:$PATH"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_read_clipboard >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "forced xsel content" "$result"
  _IS_MACOS="$orig_macos"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

function test_read_clipboard_linux_no_utility_forced() {
  local orig_macos="$_IS_MACOS"
  _IS_MACOS=false
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  local _OUT
  _OUT=$(bashunit::temp_file)
  PATH="$mock_dir"
  stop_read_clipboard >"$_OUT"
  local result
  result=$(<"$_OUT")
  _IS_MACOS="$orig_macos"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
  assert_empty "$result"
}

###
### _debug direct call (coverage for line 44)
###

function test_debug_direct_true_stderr_file() {
  local _ERR
  _ERR=$(bashunit::temp_file)
  _debug "true" "direct debug message" 2>"$_ERR"
  local result
  result=$(cat "$_ERR")
  assert_contains "[better-prompt-stop] DEBUG:" "$result"
  assert_contains "direct debug message" "$result"
}

function test_debug_direct_false_no_stderr_file() {
  local _ERR
  _ERR=$(bashunit::temp_file)
  _debug "false" "should not appear" 2>"$_ERR"
  local result
  result=$(cat "$_ERR")
  assert_empty "$result"
}

###
### stop_check_prerequisites full path (coverage for line 187 fi)
###

function test_check_prerequisites_full_path_dead_process_direct() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' "{\"sessionId\":\"full-sid\",\"pid\":99999999}" >"$tmpdir/session-full.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_check_prerequisites "false" "full-sid" >"$_OUT"
  local reason
  reason=$(cat "$_OUT")
  assert_equals "process_dead" "$reason"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}

function test_check_prerequisites_full_path_alive_direct() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' "{\"sessionId\":\"alive-full-sid\",\"pid\":$$}" >"$tmpdir/session-alive-full.json"
  local orig_dir="$ACTIVE_SESSIONS_DIR"
  ACTIVE_SESSIONS_DIR="$tmpdir"
  local _OUT
  _OUT=$(bashunit::temp_file)
  stop_check_prerequisites "false" "alive-full-sid" >"$_OUT"
  local reason
  reason=$(cat "$_OUT")
  assert_empty "$reason"
  ACTIVE_SESSIONS_DIR="$orig_dir"
  rm -rf "$tmpdir"
}
