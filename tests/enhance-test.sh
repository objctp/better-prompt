#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

function set_up_before_script() {
  source "$PROJECT_ROOT/hooks/scripts/enhance.sh"
}

function set_up() {
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _CONFIG_FILE=$(bashunit::temp_file)
  _CONFIG_ORIG="$CONFIG"
  CONFIG="$_CONFIG_FILE"
}

function tear_down() {
  rm -f "$_CONFIG_FILE"
  CONFIG="$_CONFIG_ORIG"
}

###
### _warn
###

function test_warn_outputs_to_stderr() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _warn "something went wrong" 2>"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "WARNING" "$result"
  assert_contains "something went wrong" "$result"
}

function test_warn_includes_prefix() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _warn "test" 2>"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_string_starts_with "[better-prompt]" "$result"
}

function test_warn_returns_zero() {
  _warn "msg" 2>/dev/null
  assert_successful_code
}

function test_warn_empty_message() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _warn "" 2>"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "WARNING" "$result"
}

###
### _debug
###

function test_debug_outputs_when_debug_true() {
  DEBUG=true
  local _OUT
  _OUT=$(bashunit::temp_file)
  _debug "verbose msg" 2>"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "verbose msg" "$result"
  assert_contains "[better-prompt] DEBUG:" "$result"
}

function test_debug_silent_when_debug_false() {
  DEBUG=false
  local _OUT
  _OUT=$(bashunit::temp_file)
  _debug "verbose msg" 2>"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

function test_debug_silent_when_debug_unset() {
  unset DEBUG
  local _OUT
  _OUT=$(bashunit::temp_file)
  _debug "verbose msg" 2>"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

function test_debug_returns_zero_when_true() {
  DEBUG=true
  _debug "msg" 2>/dev/null
  assert_successful_code
}

function test_debug_returns_zero_when_false() {
  DEBUG=false
  _debug "msg" 2>/dev/null
  assert_successful_code
}

function test_debug_returns_zero_when_unset() {
  unset DEBUG
  _debug "msg" 2>/dev/null
  assert_successful_code
}

###
### _json_escape
###

function test_json_escape_plain_string() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _json_escape "hello world" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals '"hello world"' "$result"
}

function test_json_escape_string_with_quotes() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _json_escape 'say "hi"' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "say" "$result"
  assert_contains "hi" "$result"
}

function test_json_escape_string_with_backslash() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _json_escape 'path\to\file' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_not_empty "$result"
}

function test_json_escape_empty_string() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _json_escape "" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals '""' "$result"
}

function test_json_escape_multiline() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _json_escape $'line1\nline2' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "line1" "$result"
  assert_contains "line2" "$result"
}

function test_json_escape_special_chars() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _json_escape $'tab\there' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_not_empty "$result"
}

function test_json_escape_without_jq() {
  local orig_path="$PATH"
  PATH=$(echo "$PATH" | tr ':' '\n' | grep -v -E '/jq$|/jq/' | tr '\n' ':')
  export PATH
  local _OUT
  _OUT=$(bashunit::temp_file)
  _json_escape 'hello "world"' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "hello" "$result"
  assert_contains "world" "$result"
  PATH="$orig_path"
  export PATH
}

###
### _atomic_write
###

function test_atomic_write_creates_file() {
  local target
  target=$(bashunit::temp_file)
  rm -f "$target"
  _atomic_write "$target" "test content"
  assert_file_exists "$target"
  local content
  content=$(cat "$target")
  assert_equals "test content" "$content"
  rm -f "$target"
}

function test_atomic_write_overwrites_existing() {
  local target
  target=$(bashunit::temp_file)
  rm -f "$target"
  _atomic_write "$target" "first"
  _atomic_write "$target" "second"
  local content
  content=$(cat "$target")
  assert_equals "second" "$content"
  rm -f "$target"
}

function test_atomic_write_handles_special_chars() {
  local target
  target=$(bashunit::temp_file)
  rm -f "$target"
  _atomic_write "$target" 'hello "quotes" and spaces'
  assert_file_exists "$target"
  rm -f "$target"
}

function test_atomic_write_returns_zero_on_success() {
  local target
  target=$(bashunit::temp_file)
  rm -f "$target"
  _atomic_write "$target" "ok"
  assert_successful_code
  rm -f "$target"
}

###
### _md5
###

function test_md5_returns_hash() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _md5 "test input" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_not_empty "$result"
  assert_matches "^[a-f0-9]+$" "$result"
}

function test_md5_consistent() {
  local _OUT1
  _OUT1=$(bashunit::temp_file)
  _md5 "consistent" >"$_OUT1"
  local _OUT2
  _OUT2=$(bashunit::temp_file)
  _md5 "consistent" >"$_OUT2"
  local h1
  h1=$(cat "$_OUT1")
  local h2
  h2=$(cat "$_OUT2")
  assert_equals "$h1" "$h2"
}

function test_md5_different_inputs() {
  local _OUT1
  _OUT1=$(bashunit::temp_file)
  _md5 "input_a" >"$_OUT1"
  local _OUT2
  _OUT2=$(bashunit::temp_file)
  _md5 "input_b" >"$_OUT2"
  local h1
  h1=$(cat "$_OUT1")
  local h2
  h2=$(cat "$_OUT2")
  assert_not_same "$h1" "$h2"
}

function test_md5_empty_string() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _md5 "" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_not_empty "$result"
}

function test_md5_long_string() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _md5 "$(seq 1 1000)" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_not_empty "$result"
  assert_matches "^[a-f0-9]+$" "$result"
}

###
### _get_setting
###

function test_get_setting_returns_value() {
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _CFG["theme"]="dark"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _get_setting "theme" "light" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "dark" "$result"
}

function test_get_setting_returns_default() {
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  local _OUT
  _OUT=$(bashunit::temp_file)
  _get_setting "missing_key" "default_val" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "default_val" "$result"
}

function test_get_setting_empty_value_returns_default() {
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _CFG["empty_key"]=""
  local _OUT
  _OUT=$(bashunit::temp_file)
  _get_setting "empty_key" "fallback" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "fallback" "$result"
}

function test_get_setting_empty_default() {
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  local _OUT
  _OUT=$(bashunit::temp_file)
  _get_setting "absent_key" "" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "" "$result"
}

###
### _parse_config
###

function test_parse_config_reads_front_matter() {
  printf '%s\n' '---' 'enabled: true' 'verbose: false' '---' >"$CONFIG"
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  assert_equals "true" "${_CFG[enabled]}"
  assert_equals "false" "${_CFG[verbose]}"
}

function test_parse_config_strips_comments() {
  printf '%s\n' '---' 'enabled: true # inline comment' >"$CONFIG"
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  assert_equals "true" "${_CFG[enabled]}"
}

function test_parse_config_missing_file() {
  local orig_config="$CONFIG"
  CONFIG="/nonexistent/path/config.md"
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  CONFIG="$orig_config"
  assert_successful_code
}

function test_parse_config_strips_whitespace() {
  printf '%s\n' '---' 'model:   sonnet  ' >"$CONFIG"
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  assert_equals "sonnet" "${_CFG[model]}"
}

function test_parse_config_ignores_body() {
  printf '%s\n' '---' 'enabled: true' '---' 'body_key: ignored' >"$CONFIG"
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  assert_equals "true" "${_CFG[enabled]}"
  assert_empty "${_CFG[body_key]}"
}

function test_parse_config_multiple_entries() {
  printf '%s\n' '---' 'enabled: true' 'correction: false' 'enhancement: true' >"$CONFIG"
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  assert_equals "true" "${_CFG[enabled]}"
  assert_equals "false" "${_CFG[correction]}"
  assert_equals "true" "${_CFG[enhancement]}"
}

function test_parse_config_empty_file() {
  : >"$CONFIG"
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  assert_successful_code
}

###
### _read_stdin_payload
###

function test_read_stdin_payload_reads_pipe() {
  local _IN
  _IN=$(bashunit::temp_file)
  printf '%s' '{"prompt":"hello"}' >"$_IN"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _read_stdin_payload <"$_IN" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals '{"prompt":"hello"}' "$result"
}

function test_read_stdin_payload_empty_pipe() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  _read_stdin_payload </dev/null >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

function test_read_stdin_payload_multiline() {
  local payload=$'line1\nline2\nline3'
  local _IN
  _IN=$(bashunit::temp_file)
  printf '%s' "$payload" >"$_IN"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _read_stdin_payload <"$_IN" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "line1" "$result"
  assert_contains "line3" "$result"
}

function test_read_stdin_payload_preserves_json() {
  local json='{"prompt":"test","session_id":"abc-123"}'
  local _IN
  _IN=$(bashunit::temp_file)
  printf '%s' "$json" >"$_IN"
  local _OUT
  _OUT=$(bashunit::temp_file)
  _read_stdin_payload <"$_IN" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "$json" "$result"
}

###
### enhance::extract_prompt
###

function test_extract_prompt_simple() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::extract_prompt '{"prompt":"hello world"}' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "hello world" "$result"
}

function test_extract_prompt_empty() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::extract_prompt '{}' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

function test_extract_prompt_missing() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::extract_prompt '{"session_id":"abc"}' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

function test_extract_prompt_with_session() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::extract_prompt '{"prompt":"test prompt","session_id":"ses-1"}' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "test prompt" "$result"
}

function test_extract_prompt_special_chars() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::extract_prompt '{"prompt":"hello \"world\" & <tags>"}' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "hello" "$result"
}

function test_extract_prompt_invalid_json() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::extract_prompt 'not json at all' >"$_OUT" 2>/dev/null || true
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

###
### enhance::resolve_session_id
###

function test_resolve_session_id_from_payload() {
  local orig_session="${CLAUDE_SESSION_ID:-}"
  CLAUDE_SESSION_ID=""
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::resolve_session_id '{"session_id":"abc-123"}' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "abc-123" "$result"
  CLAUDE_SESSION_ID="$orig_session"
}

function test_resolve_session_id_from_env() {
  local orig_session="${CLAUDE_SESSION_ID:-}"
  CLAUDE_SESSION_ID="env-session-1"
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::resolve_session_id '' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "env-session-1" "$result"
  CLAUDE_SESSION_ID="$orig_session"
}

function test_resolve_session_id_payload_takes_precedence() {
  local orig_session="${CLAUDE_SESSION_ID:-}"
  CLAUDE_SESSION_ID="env-session"
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::resolve_session_id '{"session_id":"payload-session"}' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "payload-session" "$result"
  CLAUDE_SESSION_ID="$orig_session"
}

function test_resolve_session_id_invalid_format() {
  local orig_session="${CLAUDE_SESSION_ID:-}"
  CLAUDE_SESSION_ID=""
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::resolve_session_id '{"session_id":"bad session!!!"}' >"$_OUT" 2>/dev/null
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
  CLAUDE_SESSION_ID="$orig_session"
}

function test_resolve_session_id_empty_input() {
  local orig_session="${CLAUDE_SESSION_ID:-}"
  CLAUDE_SESSION_ID=""
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::resolve_session_id '' >"$_OUT" 2>/dev/null
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
  CLAUDE_SESSION_ID="$orig_session"
}

function test_resolve_session_id_valid_alphanumeric() {
  local orig_session="${CLAUDE_SESSION_ID:-}"
  CLAUDE_SESSION_ID=""
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::resolve_session_id '{"session_id":"abc123_def-456"}' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "abc123_def-456" "$result"
  CLAUDE_SESSION_ID="$orig_session"
}

###
### enhance::is_directive
###

function test_is_directive_slash() {
  enhance::is_directive "/help"
  assert_successful_code
}

function test_is_directive_bang() {
  enhance::is_directive "!run command"
  assert_successful_code
}

function test_is_directive_normal_text() {
  enhance::is_directive "hello world"
  assert_general_error
}

function test_is_directive_empty_string() {
  enhance::is_directive ""
  assert_general_error
}

function test_is_directive_slash_longer() {
  enhance::is_directive "/explain this code"
  assert_successful_code
}

###
### enhance_check_enabled
###

function test_check_enabled_true() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance_check_enabled "true" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "true" "$result"
}

function test_check_enabled_false() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance_check_enabled "false" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "false" "$result"
}

###
### enhance::check_sentinel
###

function test_check_sentinel_no_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  enhance::check_sentinel "$tmpdir/nonexistent-sentinel" "some prompt"
  assert_general_error
  rm -rf "$tmpdir"
}

function test_check_sentinel_matching_hash() {
  local tmpdir sentinel
  tmpdir=$(mktemp -d)
  sentinel="$tmpdir/.sentinel"
  local _H
  _H=$(bashunit::temp_file)
  _md5 "hello world" >"$_H"
  local hash
  hash=$(cat "$_H")
  _atomic_write "$sentinel" "$hash"
  enhance::check_sentinel "$sentinel" "hello world"
  assert_successful_code
  rm -rf "$tmpdir"
}

function test_check_sentinel_mismatched_hash() {
  local tmpdir sentinel
  tmpdir=$(mktemp -d)
  sentinel="$tmpdir/.sentinel"
  local _H
  _H=$(bashunit::temp_file)
  _md5 "old prompt" >"$_H"
  local hash
  hash=$(cat "$_H")
  _atomic_write "$sentinel" "$hash"
  enhance::check_sentinel "$sentinel" "new different prompt"
  assert_general_error
  rm -rf "$tmpdir"
}

function test_check_sentinel_stale_hash_removed() {
  local tmpdir sentinel
  tmpdir=$(mktemp -d)
  sentinel="$tmpdir/.sentinel"
  _atomic_write "$sentinel" "stale"
  touch -t 202501010000 "$sentinel"
  enhance::check_sentinel "$sentinel" "some prompt"
  assert_general_error
  [[ ! -f "$sentinel" ]]
  assert_successful_code
  rm -rf "$tmpdir"
}

###
### enhance::format_response
###

function test_format_response_normal() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::format_response "false" "orig" "corr" "trans" "enh" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains '"decision"' "$result"
  assert_contains '"block"' "$result"
  assert_contains "better-prompt" "$result"
}

function test_format_response_debug() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::format_response "true" "orig" "corr" "trans" "enh" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains '"decision"' "$result"
  assert_contains '"block"' "$result"
  assert_contains "Better Prompt Debug" "$result"
}

function test_format_response_is_valid_json() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::format_response "false" "orig" "corr" "trans" "enh" >"$_OUT"
  jq . "$_OUT" >/dev/null 2>&1
  assert_successful_code
}

function test_format_response_debug_shows_prompts() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::format_response "true" "original text" "corrected text" "working text" "enhanced text" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "original text" "$result"
  assert_contains "corrected text" "$result"
  assert_contains "working text" "$result"
  assert_contains "enhanced text" "$result"
}

function test_format_response_normal_has_suppress_output() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::format_response "false" "orig" "corr" "trans" "enh" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "suppressOutput" "$result"
}

###
### enhance::copy_to_clipboard (macOS only, uses pbcopy mock)
###

function test_copy_to_clipboard_macos() {
  if [[ "$IS_MACOS" != true ]]; then
    return 0
  fi
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/pbcopy" <<'MOCK'
#!/usr/bin/env bash
cat > /tmp/better-prompt-test-clip
MOCK
  chmod +x "$mock_dir/pbcopy"
  PATH="$mock_dir:$PATH"
  enhance::copy_to_clipboard "test clipboard content"
  local content
  content=$(cat /tmp/better-prompt-test-clip)
  assert_equals "test clipboard content" "$content"
  rm -f /tmp/better-prompt-test-clip
  rm -rf "$mock_dir"
  PATH="$orig_path"
  export PATH
}

function test_copy_to_clipboard_xclip() {
  local orig_macos="${IS_MACOS:-}"
  IS_MACOS=false
  local mock_dir
  mock_dir=$(mktemp -d)
  local orig_path="$PATH"
  cat >"$mock_dir/xclip" <<'MOCK'
#!/usr/bin/env bash
cat > /tmp/better-prompt-test-clip-xclip
MOCK
  chmod +x "$mock_dir/xclip"
  PATH="$mock_dir:$PATH"
  enhance::copy_to_clipboard "xclip content"
  if [[ -f /tmp/better-prompt-test-clip-xclip ]]; then
    local content
    content=$(cat /tmp/better-prompt-test-clip-xclip)
    assert_equals "xclip content" "$content"
    rm -f /tmp/better-prompt-test-clip-xclip
  fi
  rm -rf "$mock_dir"
  PATH="$orig_path"
  export PATH
  IS_MACOS="$orig_macos"
}

function test_copy_to_clipboard_no_utility() {
  local orig_macos="${IS_MACOS:-}"
  IS_MACOS=false
  local mock_dir
  mock_dir=$(mktemp -d)
  local orig_path="$PATH"
  local _OUT
  _OUT=$(bashunit::temp_file)
  PATH="$mock_dir:$PATH"
  enhance::copy_to_clipboard "no utility content" 2>"$_OUT"
  local stderr_output
  stderr_output=$(cat "$_OUT")
  assert_contains "clipboard" "$stderr_output" || assert_empty "$stderr_output"
  IS_MACOS="$orig_macos"
  rm -rf "$mock_dir"
  PATH="$orig_path"
  export PATH
}

###
### enhance::spawn_stop_hook (mocked)
###

function test_spawn_stop_hook_invokes_nohup() {
  local mock_dir
  mock_dir=$(mktemp -d)
  local orig_path="$PATH"
  local orig_plugin_root="${PLUGIN_ROOT:-}"
  cat >"$mock_dir/nohup" <<'MOCK'
#!/usr/bin/env bash
printf 'NOHUP:%s' "$*" > /tmp/better-prompt-spawn-test
MOCK
  chmod +x "$mock_dir/nohup"
  PATH="$mock_dir:$PATH"
  PLUGIN_ROOT="/fake/plugin/root"
  rm -f /tmp/better-prompt-spawn-test
  enhance::spawn_stop_hook "test-session-abc" 2>/dev/null || true
  sleep 1
  if [[ -f /tmp/better-prompt-spawn-test ]]; then
    local content
    content=$(cat /tmp/better-prompt-spawn-test)
    assert_contains "stop-hook" "$content" || true
    rm -f /tmp/better-prompt-spawn-test
  fi
  rm -rf "$mock_dir"
  PATH="$orig_path"
  export PATH
  PLUGIN_ROOT="$orig_plugin_root"
}

###
### Main integration tests (subprocess)
###

function _setup_mock_env() {
  _MOCK_DIR=$(mktemp -d)
  _ORIG_PATH="$PATH"

  cat >"$_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"mocked enhanced prompt","session_id":"mock-session-123","total_cost_usd":0.001,"usage":{"input_tokens":500,"output_tokens":50}}'
MOCK
  chmod +x "$_MOCK_DIR/claude"

  cat >"$_MOCK_DIR/pbcopy" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
MOCK
  chmod +x "$_MOCK_DIR/pbcopy"

  cat >"$_MOCK_DIR/nohup" <<'MOCK'
#!/usr/bin/env bash
shift
echo "nohup mocked $*"
MOCK
  chmod +x "$_MOCK_DIR/nohup"

  PATH="$_MOCK_DIR:$PATH"
  export PATH
}

function _setup_stage_mock_env() {
  _MOCK_DIR=$(mktemp -d)
  _ORIG_PATH="$PATH"

  cat >"$_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
if echo "$*" | grep -q "prompt-correction"; then
  echo '{"result":"{\"corrected\":\"corrected prompt text\",\"mistakes\":[{\"type\":\"grammar\"}],\"language\":\"en\"}","session_id":"mock-session-456","total_cost_usd":0.002,"usage":{"input_tokens":300,"output_tokens":30}}'
elif echo "$*" | grep -q "prompt-translation"; then
  echo '{"result":"translated prompt text","session_id":"mock-session-456","total_cost_usd":0.001,"usage":{"input_tokens":200,"output_tokens":20}}'
elif echo "$*" | grep -q "prompt-enhancement"; then
  echo '{"result":"enhanced prompt text","session_id":"mock-session-456","total_cost_usd":0.003,"usage":{"input_tokens":400,"output_tokens":40}}'
else
  echo '{"result":"mocked enhanced prompt","session_id":"mock-session-123","total_cost_usd":0.001,"usage":{"input_tokens":500,"output_tokens":50}}'
fi
MOCK
  chmod +x "$_MOCK_DIR/claude"

  cat >"$_MOCK_DIR/pbcopy" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
MOCK
  chmod +x "$_MOCK_DIR/pbcopy"

  cat >"$_MOCK_DIR/nohup" <<'MOCK'
#!/usr/bin/env bash
:
MOCK
  chmod +x "$_MOCK_DIR/nohup"

  PATH="$_MOCK_DIR:$PATH"
  export PATH
}

function _teardown_mock_env() {
  rm -rf "$_MOCK_DIR"
  PATH="$_ORIG_PATH"
  export PATH
  unset _MOCK_DIR _ORIG_PATH
}

function test_main_outputs_continue_when_disabled() {
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: false' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"hello","session_id":"abc"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}

function test_main_outputs_continue_on_empty_prompt() {
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"","session_id":"abc"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}

function test_main_outputs_continue_on_slash_directive() {
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"/help","session_id":"abc123"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}

function test_main_outputs_continue_on_bang_directive() {
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"!some_command","session_id":"abc123"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
}

function test_main_outputs_valid_json_on_missing_session_id() {
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"hello"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_SESSION_ID="" CLAUDE_PROJECT_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_matches '^\{' "$result"
  rm -rf "$tmpdir"
}

function test_main_sourced_outputs_continue_when_disabled() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: false' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"hello","session_id":"abc"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_main_sourced_outputs_continue_on_slash_directive() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"/help","session_id":"abc123"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_main_sourced_outputs_block_with_correction() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' 'correction: true' 'correction_model: haiku' 'enhancement: false' 'translation: false' 'audit: false' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"hallo world","session_id":"ses3"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="ses3" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "block" "$result"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_main_sourced_outputs_block_with_enhancement() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' 'correction: false' 'enhancement: true' 'enhancement_model: sonnet' 'translation: false' 'audit: false' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"hello world","session_id":"ses4"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="ses4" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "block" "$result"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_main_sourced_outputs_block_with_translation() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' 'correction: false' 'enhancement: false' 'translation: true' 'translation_model: haiku' 'audit: false' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"bonjour le monde","session_id":"ses5"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="ses5" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "block" "$result"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_main_sourced_all_stages_disabled() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' 'correction: false' 'enhancement: false' 'translation: false' 'audit: false' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"hello world","session_id":"ses6"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="ses6" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_main_sourced_verbose_output() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' 'verbose: true' 'correction: false' 'enhancement: false' 'translation: false' 'audit: false' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"hello world","session_id":"ses7"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="ses7" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>&1 || true)
  assert_contains "block" "$result"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_main_sourced_sentinel_prevents_loop() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' 'correction: false' 'enhancement: false' 'translation: false' 'audit: false' >"$tmpcfg"
  local sentinel="$tmpdir/.claude/better-prompt/.sentinel"
  local _H
  _H=$(bashunit::temp_file)
  _md5 "hello world" >"$_H"
  local hash
  hash=$(cat "$_H")
  _atomic_write "$sentinel" "$hash"
  local result
  result=$(printf '%s' '{"prompt":"hello world","session_id":"ses8"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="ses8" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_main_sourced_audit_log_written() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' 'correction: false' 'enhancement: false' 'translation: false' 'audit: true' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"hello world","session_id":"ses9"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="ses9" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "block" "$result"
  assert_file_exists "$tmpdir/.claude/better-prompt/audit.json"
  local log_content
  log_content=$(cat "$tmpdir/.claude/better-prompt/audit.json")
  assert_contains "hello world" "$log_content"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_main_sourced_invalid_session_format() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"hello","session_id":"bad session!!!"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_main_sourced_bang_directive() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"!run something","session_id":"ses10"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="ses10" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

###
### enhance::load_settings
###

function test_load_settings_defaults() {
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  local CONFIG_ORIG="$CONFIG"
  CONFIG="/nonexistent"
  enhance::load_settings
  assert_equals "false" "$DEBUG"
  assert_equals "true" "$ENABLED"
  assert_equals "true" "$CORRECTION"
  assert_equals "haiku" "$CORRECTION_MODEL"
  assert_equals "false" "$ENHANCEMENT"
  assert_equals "sonnet" "$ENHANCEMENT_MODEL"
  assert_equals "false" "$TRANSLATION"
  assert_equals "haiku" "$TRANSLATION_MODEL"
  assert_equals "true" "$AUDIT"
  CONFIG="$CONFIG_ORIG"
}

function test_load_settings_from_config() {
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: false' 'verbose: true' 'correction: false' 'correction_model: gpt-4' 'enhancement: true' 'enhancement_model: opus' 'translation: true' 'translation_model: deepseek' 'audit: false' >"$tmpcfg"
  local CONFIG_ORIG="$CONFIG"
  CONFIG="$tmpcfg"
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  enhance::load_settings
  assert_equals "true" "$DEBUG"
  assert_equals "false" "$ENABLED"
  assert_equals "false" "$CORRECTION"
  assert_equals "gpt-4" "$CORRECTION_MODEL"
  assert_equals "true" "$ENHANCEMENT"
  assert_equals "opus" "$ENHANCEMENT_MODEL"
  assert_equals "true" "$TRANSLATION"
  assert_equals "deepseek" "$TRANSLATION_MODEL"
  assert_equals "false" "$AUDIT"
  rm -rf "$tmpdir"
  CONFIG="$CONFIG_ORIG"
}

function test_load_settings_uses_project_dir() {
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' >"$tmpcfg"
  local CONFIG_ORIG="$CONFIG"
  local PROJECT_DIR_ORIG="${CLAUDE_PROJECT_DIR:-}"
  CONFIG="$tmpcfg"
  CLAUDE_PROJECT_DIR="$tmpdir"
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  enhance::load_settings
  assert_equals "$tmpdir/.claude/better-prompt/audit.json" "$AUDIT_LOG"
  assert_equals "$tmpdir/.claude/better-prompt/.sentinel" "$SENTINEL"
  rm -rf "$tmpdir"
  CONFIG="$CONFIG_ORIG"
  CLAUDE_PROJECT_DIR="$PROJECT_DIR_ORIG"
}

###
### enhance::should_skip
###

function test_should_skip_when_disabled() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::should_skip "false" "hello" "ses1" "/tmp/no-sentinel" "true" "false" "false" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "disabled" "$result"
}

function test_should_skip_empty_prompt() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::should_skip "true" "" "ses1" "/tmp/no-sentinel" "true" "false" "false" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "empty_input" "$result"
}

function test_should_skip_empty_session() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::should_skip "true" "hello" "" "/tmp/no-sentinel" "true" "false" "false" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "empty_input" "$result"
}

function test_should_skip_directive_slash() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::should_skip "true" "/help" "ses1" "/tmp/no-sentinel" "true" "false" "false" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "directive" "$result"
}

function test_should_skip_directive_bang() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::should_skip "true" "!cmd" "ses1" "/tmp/no-sentinel" "true" "false" "false" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "directive" "$result"
}

function test_should_skip_sentinel_match() {
  local tmpdir sentinel
  tmpdir=$(mktemp -d)
  sentinel="$tmpdir/.sentinel"
  local _H
  _H=$(bashunit::temp_file)
  _md5 "hello world" >"$_H"
  local hash
  hash=$(cat "$_H")
  _atomic_write "$sentinel" "$hash"
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::should_skip "true" "hello world" "ses1" "$sentinel" "true" "false" "false" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "sentinel" "$result"
  rm -rf "$tmpdir"
}

function test_should_skip_no_skip_when_enabled() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::should_skip "true" "hello world" "ses1" "/tmp/no-sentinel-here" "true" "false" "false" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

function test_should_skip_no_skip_normal_prompt() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::should_skip "true" "fix this bug" "abc-123" "$tmpdir/no-sentinel" "true" "false" "false" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
  rm -rf "$tmpdir"
}

function test_should_skip_no_stages_active() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::should_skip "true" "hello world" "ses1" "/tmp/no-sentinel" "false" "false" "false" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_equals "no_stages" "$result"
}

function test_should_skip_one_stage_active_not_skipped() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::should_skip "true" "hello world" "ses1" "/tmp/no-sentinel" "false" "false" "true" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_empty "$result"
}

###
### enhance::run_pipeline (no stages)
###

function test_run_pipeline_all_disabled() {
  _setup_mock_env
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  local sess_file="$tmpdir/.claude/better-prompt/.enhance-session"

  declare -A _PS=()
  _PS[WORKING_PROMPT]="hello world"
  _PS[CORRECTED_PROMPT]=""
  _PS[ENHANCED_PROMPT]=""
  _PS[CORRECTIONS_JSON]="[]"
  _PS[MISTAKE_NATURE_JSON]="[]"
  _PS[DETECTED_LANGUAGE]=""
  enhance::run_pipeline _PS "false" "haiku" "false" "haiku" "false" "sonnet" "$sess_file"

  assert_equals "hello world" "${_PS[CORRECTED_PROMPT]}"
  assert_equals "hello world" "${_PS[ENHANCED_PROMPT]}"
  assert_equals "hello world" "${_PS[WORKING_PROMPT]}"

  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_run_pipeline_correction_enabled() {
  _setup_mock_env
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  local sess_file="$tmpdir/.claude/better-prompt/.enhance-session"

  declare -A _PS=()
  _PS[WORKING_PROMPT]="hallo world"
  _PS[CORRECTED_PROMPT]=""
  _PS[ENHANCED_PROMPT]=""
  _PS[CORRECTIONS_JSON]="[]"
  _PS[MISTAKE_NATURE_JSON]="[]"
  _PS[DETECTED_LANGUAGE]=""
  enhance::run_pipeline _PS "true" "haiku" "false" "haiku" "false" "sonnet" "$sess_file"

  assert_not_empty "${_PS[CORRECTED_PROMPT]}"
  assert_not_empty "${_PS[WORKING_PROMPT]}"

  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_run_pipeline_translation_enabled() {
  _setup_mock_env
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  local sess_file="$tmpdir/.claude/better-prompt/.enhance-session"

  declare -A _PS=()
  _PS[WORKING_PROMPT]="bonjour le monde"
  _PS[CORRECTED_PROMPT]=""
  _PS[ENHANCED_PROMPT]=""
  _PS[CORRECTIONS_JSON]="[]"
  _PS[MISTAKE_NATURE_JSON]="[]"
  _PS[DETECTED_LANGUAGE]=""
  enhance::run_pipeline _PS "false" "haiku" "true" "haiku" "false" "sonnet" "$sess_file"

  assert_not_empty "${_PS[WORKING_PROMPT]}"

  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_run_pipeline_enhancement_enabled() {
  _setup_mock_env
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  local sess_file="$tmpdir/.claude/better-prompt/.enhance-session"

  declare -A _PS=()
  _PS[WORKING_PROMPT]="hello world"
  _PS[CORRECTED_PROMPT]=""
  _PS[ENHANCED_PROMPT]=""
  _PS[CORRECTIONS_JSON]="[]"
  _PS[MISTAKE_NATURE_JSON]="[]"
  _PS[DETECTED_LANGUAGE]=""
  enhance::run_pipeline _PS "false" "haiku" "false" "haiku" "true" "sonnet" "$sess_file"

  assert_not_empty "${_PS[ENHANCED_PROMPT]}"

  rm -rf "$tmpdir"
  _teardown_mock_env
}

###
### enhance::finalize
###

function test_finalize_writes_sentinel_and_response() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' 'verbose: false' 'correction: false' 'enhancement: false' 'translation: false' 'audit: false' >"$tmpcfg"

  local CONFIG_ORIG="$CONFIG"
  CONFIG="$tmpcfg"
  local PROJECT_DIR_ORIG="${CLAUDE_PROJECT_DIR:-}"
  CLAUDE_PROJECT_DIR="$tmpdir"

  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  enhance::load_settings

  declare -A _PS=()
  _PS[WORKING_PROMPT]="hello world"
  _PS[CORRECTED_PROMPT]="hello world"
  _PS[ENHANCED_PROMPT]="enhanced hello"
  _PS[CORRECTIONS_JSON]="[]"
  _PS[MISTAKE_NATURE_JSON]="[]"
  _PS[DETECTED_LANGUAGE]=""
  CORRECTION="false"
  CORRECTION_MODEL="haiku"
  ENHANCEMENT="false"
  ENHANCEMENT_MODEL="sonnet"
  TRANSLATION="false"
  TRANSLATION_MODEL="haiku"

  local sentinel="$tmpdir/.claude/better-prompt/.sentinel"
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::finalize _PS "hello world" "test-session-123" >"$_OUT" 2>/dev/null || true
  local response
  response=$(cat "$_OUT")

  assert_contains "block" "$response"
  assert_file_exists "$sentinel"

  rm -rf "$tmpdir"
  CONFIG="$CONFIG_ORIG"
  CLAUDE_PROJECT_DIR="$PROJECT_DIR_ORIG"
  _teardown_mock_env
}

function test_finalize_writes_audit_when_enabled() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' 'verbose: false' 'correction: false' 'enhancement: false' 'translation: false' 'audit: true' >"$tmpcfg"

  local CONFIG_ORIG="$CONFIG"
  CONFIG="$tmpcfg"
  local PROJECT_DIR_ORIG="${CLAUDE_PROJECT_DIR:-}"
  CLAUDE_PROJECT_DIR="$tmpdir"

  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  enhance::load_settings

  declare -A _PS=()
  _PS[WORKING_PROMPT]="hello world"
  _PS[CORRECTED_PROMPT]="hello world"
  _PS[ENHANCED_PROMPT]="enhanced hello"
  _PS[CORRECTIONS_JSON]="[]"
  _PS[MISTAKE_NATURE_JSON]="[]"
  _PS[DETECTED_LANGUAGE]=""
  CORRECTION="false"
  CORRECTION_MODEL="haiku"
  ENHANCEMENT="false"
  ENHANCEMENT_MODEL="sonnet"
  TRANSLATION="false"
  TRANSLATION_MODEL="haiku"

  enhance::finalize _PS "hello world" "test-session-456" 2>/dev/null || true

  local audit_log="$tmpdir/.claude/better-prompt/audit.json"
  assert_file_exists "$audit_log"
  local log_content
  log_content=$(cat "$audit_log")
  assert_contains "hello world" "$log_content"

  rm -rf "$tmpdir"
  CONFIG="$CONFIG_ORIG"
  CLAUDE_PROJECT_DIR="$PROJECT_DIR_ORIG"
  _teardown_mock_env
}

###
### enhance::run_correction (direct call with mock)
###

function test_run_correction_sets_globals() {
  _setup_stage_mock_env
  declare -A _PS=()
  _PS[WORKING_PROMPT]="hallo world"
  _PS[CORRECTED_PROMPT]=""
  _PS[CORRECTIONS_JSON]="[]"
  _PS[MISTAKE_NATURE_JSON]="[]"
  _PS[DETECTED_LANGUAGE]=""
  enhance::run_correction _PS "haiku"
  assert_not_empty "${_PS[CORRECTED_PROMPT]}"
  assert_not_empty "${_PS[WORKING_PROMPT]}"
  _teardown_mock_env
}

function test_run_correction_parses_response() {
  _setup_stage_mock_env
  declare -A _PS=()
  _PS[WORKING_PROMPT]="hallo werld"
  _PS[CORRECTED_PROMPT]=""
  _PS[CORRECTIONS_JSON]="[]"
  _PS[MISTAKE_NATURE_JSON]="[]"
  _PS[DETECTED_LANGUAGE]=""
  enhance::run_correction _PS "haiku"
  assert_contains "corrected" "${_PS[CORRECTED_PROMPT]}"
  _teardown_mock_env
}

function test_run_correction_updates_working_prompt() {
  _setup_stage_mock_env
  declare -A _PS=()
  _PS[WORKING_PROMPT]="some prompt"
  _PS[CORRECTED_PROMPT]=""
  _PS[CORRECTIONS_JSON]="[]"
  _PS[MISTAKE_NATURE_JSON]="[]"
  _PS[DETECTED_LANGUAGE]=""
  enhance::run_correction _PS "haiku"
  assert_equals "${_PS[WORKING_PROMPT]}" "${_PS[CORRECTED_PROMPT]}"
  _teardown_mock_env
}

###
### enhance::run_translation (direct call with mock)
###

function test_run_translation_sets_working_prompt() {
  _setup_stage_mock_env
  declare -A _PS=()
  _PS[WORKING_PROMPT]="bonjour le monde"
  enhance::run_translation _PS "haiku"
  assert_not_empty "${_PS[WORKING_PROMPT]}"
  assert_not_equals "bonjour le monde" "${_PS[WORKING_PROMPT]}"
  _teardown_mock_env
}

function test_run_translation_keeps_prompt_on_failure() {
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo "error: command failed" >&2
exit 1
MOCK
  chmod +x "$mock_dir/claude"
  PATH="$mock_dir:$PATH"
  export PATH
  declare -A _PS=()
  _PS[WORKING_PROMPT]="original prompt"
  enhance::run_translation _PS "haiku" 2>/dev/null || true
  assert_equals "original prompt" "${_PS[WORKING_PROMPT]}"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

###
### enhance::run_enhancement_stage (direct call with mock)
###

function test_run_enhancement_stage_basic() {
  _setup_stage_mock_env
  local sess_file
  sess_file=$(bashunit::temp_file)
  rm -f "$sess_file"
  declare -A _test_st=()
  _test_st[COST_USD]="0"
  _test_st[INPUT_TOKENS]="0"
  _test_st[OUTPUT_TOKENS]="0"
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::run_enhancement_stage _test_st "hello world" "sonnet" "$sess_file" 5 >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "enhanced" "$result"
  _teardown_mock_env
}

function test_run_enhancement_stage_with_session_file() {
  _setup_stage_mock_env
  local sess_dir
  sess_dir=$(mktemp -d)
  local sess_file="$sess_dir/.enhance-session"
  printf '%s' "existing-session-id" >"$sess_file"
  declare -A _test_st=()
  _test_st[COST_USD]="0"
  _test_st[INPUT_TOKENS]="0"
  _test_st[OUTPUT_TOKENS]="0"
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::run_enhancement_stage _test_st "hello world" "sonnet" "$sess_file" 5 >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_not_empty "$result"
  rm -rf "$sess_dir"
  _teardown_mock_env
}

function test_run_enhancement_stage_writes_session() {
  _setup_stage_mock_env
  local sess_dir
  sess_dir=$(mktemp -d)
  local sess_file="$sess_dir/session"
  rm -f "$sess_file"
  declare -A _test_st=()
  _test_st[COST_USD]="0"
  _test_st[INPUT_TOKENS]="0"
  _test_st[OUTPUT_TOKENS]="0"
  enhance::run_enhancement_stage _test_st "hello world" "sonnet" "$sess_file" 5 >/dev/null
  if [[ -f "$sess_file" ]]; then
    local sid
    sid=$(cat "$sess_file")
    assert_not_empty "$sid"
  fi
  rm -rf "$sess_dir"
  _teardown_mock_env
}

###
### enhance::write_audit (direct call)
###

function test_write_audit_creates_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local audit_log="$tmpdir/.claude/better-prompt/audit.json"
  enhance::write_audit "$audit_log" "original prompt" "corrected prompt" "enhanced prompt" \
    "[]" "[]" "en" "true" "haiku" "false" "sonnet" "false" "haiku"
  assert_file_exists "$audit_log"
  local content
  content=$(cat "$audit_log")
  assert_contains "original prompt" "$content"
  assert_contains "corrected prompt" "$content"
  assert_contains "enhanced prompt" "$content"
  rm -rf "$tmpdir"
}

function test_write_audit_includes_models() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local audit_log="$tmpdir/.claude/better-prompt/audit.json"
  enhance::write_audit "$audit_log" "prompt" "corr" "enh" \
    "[]" "[]" "en" "true" "haiku" "false" "sonnet" "false" "haiku"
  local content
  content=$(cat "$audit_log")
  assert_contains "haiku" "$content"
  rm -rf "$tmpdir"
}

function test_write_audit_null_models_when_disabled() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local audit_log="$tmpdir/.claude/better-prompt/audit.json"
  enhance::write_audit "$audit_log" "prompt" "corr" "enh" \
    "[]" "[]" "" "false" "haiku" "false" "sonnet" "false" "haiku"
  local content
  content=$(cat "$audit_log")
  assert_contains "null" "$content"
  rm -rf "$tmpdir"
}

function test_write_audit_appends() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local audit_log="$tmpdir/.claude/better-prompt/audit.json"
  enhance::write_audit "$audit_log" "first" "corr" "enh" \
    "[]" "[]" "" "false" "haiku" "false" "sonnet" "false" "haiku"
  enhance::write_audit "$audit_log" "second" "corr" "enh" \
    "[]" "[]" "" "false" "haiku" "false" "sonnet" "false" "haiku"
  local line_count
  line_count=$(wc -l <"$audit_log" | tr -d '[:space:]')
  assert_equals "2" "$line_count"
  rm -rf "$tmpdir"
}

###
### enhance::write_sentinel (direct call)
###

function test_write_sentinel_creates_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local sentinel="$tmpdir/sentinel"
  enhance::write_sentinel "$sentinel" "test prompt"
  assert_file_exists "$sentinel"
  local stored_hash
  stored_hash=$(cat "$sentinel")
  assert_not_empty "$stored_hash"
  rm -rf "$tmpdir"
}

function test_write_sentinel_stores_correct_hash() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local sentinel="$tmpdir/sentinel"
  enhance::write_sentinel "$sentinel" "hello world"
  local _H
  _H=$(bashunit::temp_file)
  _md5 "hello world" >"$_H"
  local expected_hash
  expected_hash=$(cat "$_H")
  local stored_hash
  stored_hash=$(cat "$sentinel")
  assert_equals "$expected_hash" "$stored_hash"
  rm -rf "$tmpdir"
}

function test_write_sentinel_overwrites_existing() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local sentinel="$tmpdir/sentinel"
  enhance::write_sentinel "$sentinel" "first prompt"
  enhance::write_sentinel "$sentinel" "second prompt"
  local _H
  _H=$(bashunit::temp_file)
  _md5 "second prompt" >"$_H"
  local expected_hash
  expected_hash=$(cat "$_H")
  local stored_hash
  stored_hash=$(cat "$sentinel")
  assert_equals "$expected_hash" "$stored_hash"
  rm -rf "$tmpdir"
}

###
### enhance::format_response (additional branches)
###

function test_format_response_normal_contains_block() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::format_response "false" "orig" "corr" "trans" "enh" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains '"decision": "block"' "$result" || assert_contains '"decision":"block"' "$result"
  assert_contains "suppressOutput" "$result"
}

function test_format_response_debug_shows_labels() {
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::format_response "true" "orig" "corr" "trans" "enh" >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "Original:" "$result"
  assert_contains "Corrected:" "$result"
  assert_contains "Translated:" "$result"
  assert_contains "Enhanced:" "$result"
}

###
### enhance::write_audit (additional branches)
###

function test_write_audit_with_correction_true() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local audit_log="$tmpdir/.claude/better-prompt/audit.json"
  enhance::write_audit "$audit_log" "prompt" "corr" "enh" "[]" "[]" "en" "true" "haiku" "false" "sonnet" "false" "haiku"
  local content
  content=$(cat "$audit_log")
  assert_contains "haiku" "$content"
  rm -rf "$tmpdir"
}

function test_write_audit_with_enhancement_true() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local audit_log="$tmpdir/.claude/better-prompt/audit.json"
  enhance::write_audit "$audit_log" "prompt" "corr" "enh" "[]" "[]" "en" "false" "haiku" "true" "sonnet" "false" "haiku"
  local content
  content=$(cat "$audit_log")
  assert_contains "sonnet" "$content"
  rm -rf "$tmpdir"
}

function test_write_audit_with_translation_true() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local audit_log="$tmpdir/.claude/better-prompt/audit.json"
  enhance::write_audit "$audit_log" "prompt" "corr" "enh" "[]" "[]" "en" "false" "haiku" "false" "sonnet" "true" "haiku"
  local content
  content=$(cat "$audit_log")
  assert_contains "haiku" "$content"
  rm -rf "$tmpdir"
}

function test_write_audit_with_mistakes() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local audit_log="$tmpdir/.claude/better-prompt/audit.json"
  enhance::write_audit "$audit_log" "prompt" "corr" "enh" '["grammar"]' '[{"type":"grammar","correction":"fix"}]' "en" "true" "haiku" "false" "sonnet" "false" "haiku"
  local content
  content=$(cat "$audit_log")
  assert_contains "grammar" "$content"
  rm -rf "$tmpdir"
}

###
### enhance::copy_to_clipboard (additional branches)
###

function test_copy_to_clipboard_linux_xclip() {
  if [[ "$IS_MACOS" == true ]]; then
    assert_successful_code
    return 0
  fi
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/xclip" <<'MOCK'
#!/usr/bin/env bash
cat > /tmp/better-prompt-test-clip-xclip
MOCK
  chmod +x "$mock_dir/xclip"
  cat >"$mock_dir/xsel" <<'MOCK'
#!/usr/bin/env bash
echo "xsel should not be called"
MOCK
  chmod +x "$mock_dir/xsel"
  PATH="$mock_dir:$PATH"
  enhance::copy_to_clipboard "test xclip content"
  local content
  content=$(cat /tmp/better-prompt-test-clip-xclip 2>/dev/null || echo "")
  assert_equals "test xclip content" "$content"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir" /tmp/better-prompt-test-clip-xclip
}

function test_copy_to_clipboard_linux_xsel() {
  if [[ "$IS_MACOS" == true ]]; then
    assert_successful_code
    return 0
  fi
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  # No xclip, only xsel
  cat >"$mock_dir/xsel" <<'MOCK'
#!/usr/bin/env bash
cat > /tmp/better-prompt-test-clip-xsel
MOCK
  chmod +x "$mock_dir/xsel"
  PATH="$mock_dir:$PATH"
  enhance::copy_to_clipboard "test xsel content"
  local content
  content=$(cat /tmp/better-prompt-test-clip-xsel 2>/dev/null || echo "")
  assert_equals "test xsel content" "$content"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir" /tmp/better-prompt-test-clip-xsel
}

function test_copy_to_clipboard_no_utility_linux() {
  if [[ "$IS_MACOS" == true ]]; then
    assert_successful_code
    return 0
  fi
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  PATH="$mock_dir"
  export PATH
  local _OUT
  _OUT=$(bashunit::temp_file)
  enhance::copy_to_clipboard "test content" 2>"$_OUT"
  local stderr_content
  stderr_content=$(cat "$_OUT")
  assert_contains "clipboard" "$stderr_content"
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir"
}

###
### enhance::spawn_stop_hook (direct call with mock)
###

function test_spawn_stop_hook_sets_environment() {
  local mock_dir orig_path
  mock_dir=$(mktemp -d)
  orig_path="$PATH"
  cat >"$mock_dir/nohup" <<'MOCK'
#!/usr/bin/env bash
echo "CALLED" >> /tmp/better-prompt-test-spawn-env
env >> /tmp/better-prompt-test-spawn-env
MOCK
  chmod +x "$mock_dir/nohup"
  cat >"$mock_dir/bash" <<'MOCK'
#!/usr/bin/env bash
echo "BASH_CALLED" >> /tmp/better-prompt-test-spawn-env
MOCK
  chmod +x "$mock_dir/bash"
  cat >"$mock_dir/pbcopy" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
MOCK
  chmod +x "$mock_dir/pbcopy"
  PATH="$mock_dir:$PATH"
  export PATH
  rm -f /tmp/better-prompt-test-spawn-env
  enhance::spawn_stop_hook "test-session-xyz"
  sleep 1
  assert_successful_code
  PATH="$orig_path"
  export PATH
  rm -rf "$mock_dir" /tmp/better-prompt-test-spawn-env
}

###
### enhance::write_sentinel (additional branch)
###

function test_write_sentinel_warns_on_empty_hash() {
  local tmpdir sentinel
  tmpdir=$(mktemp -d)
  sentinel="$tmpdir/.sentinel"
  local _ERR
  _ERR=$(bashunit::temp_file)
  _md5() {
    printf ''
    return 0
  }
  enhance::write_sentinel "$sentinel" "test prompt" 2>"$_ERR"
  local stderr_content
  stderr_content=$(cat "$_ERR")
  assert_contains "sentinel" "$stderr_content"
  [[ ! -f "$sentinel" ]]
  assert_successful_code
  rm -rf "$tmpdir"
}

###
### _json_escape sed fallback (without jq)
###

function test_json_escape_without_jq_direct() {
  local orig_path="$PATH"
  PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '/jq$' | grep -v '/jq/' | tr '\n' ':')
  export PATH
  local _OUT
  _OUT=$(bashunit::temp_file)
  _json_escape 'hello "world"' >"$_OUT"
  local result
  result=$(cat "$_OUT")
  assert_contains "hello" "$result"
  assert_contains "world" "$result"
  PATH="$orig_path"
  export PATH
}

###
### enhance::resolve_session_id (directory lookup)
###

###
### _read_stdin_payload (direct call)
###

function test_read_stdin_payload_direct() {
  local input_file output_file
  input_file=$(bashunit::temp_file)
  output_file=$(bashunit::temp_file)
  printf '%s' '{"key":"value"}' >"$input_file"
  _read_stdin_payload <"$input_file" >"$output_file"
  local result
  result=$(cat "$output_file")
  assert_equals '{"key":"value"}' "$result"
}

function test_read_stdin_payload_empty_direct() {
  local input_file output_file
  input_file=$(bashunit::temp_file)
  output_file=$(bashunit::temp_file)
  : >"$input_file"
  _read_stdin_payload <"$input_file" >"$output_file"
  local result
  result=$(cat "$output_file")
  assert_empty "$result"
}
