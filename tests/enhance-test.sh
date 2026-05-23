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
  local result
  result=$(_warn "something went wrong" 2>&1 1>/dev/null)
  assert_contains "WARNING" "$result"
  assert_contains "something went wrong" "$result"
}

function test_warn_includes_prefix() {
  local result
  result=$(_warn "test" 2>&1 1>/dev/null)
  assert_string_starts_with "[better-prompt]" "$result"
}

function test_warn_returns_zero() {
  _warn "msg" 2>/dev/null
  assert_successful_code
}

function test_warn_empty_message() {
  local result
  result=$(_warn "" 2>&1 1>/dev/null)
  assert_contains "WARNING" "$result"
}

###
### _debug
###

function test_debug_outputs_when_debug_true() {
  DEBUG=true
  local result
  result=$(_debug "verbose msg" 2>&1 1>/dev/null)
  assert_contains "verbose msg" "$result"
  assert_contains "[better-prompt] DEBUG:" "$result"
}

function test_debug_silent_when_debug_false() {
  DEBUG=false
  local result
  result=$(_debug "verbose msg" 2>&1 1>/dev/null)
  assert_empty "$result"
}

function test_debug_silent_when_debug_unset() {
  unset DEBUG
  local result
  result=$(_debug "verbose msg" 2>&1 1>/dev/null)
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
  local result
  result=$(_json_escape "hello world")
  assert_equals '"hello world"' "$result"
}

function test_json_escape_string_with_quotes() {
  local result
  result=$(_json_escape 'say "hi"')
  assert_contains "say" "$result"
  assert_contains "hi" "$result"
}

function test_json_escape_string_with_backslash() {
  local result
  result=$(_json_escape 'path\to\file')
  assert_not_empty "$result"
}

function test_json_escape_empty_string() {
  local result
  result=$(_json_escape "")
  assert_equals '""' "$result"
}

function test_json_escape_multiline() {
  local result
  result=$(_json_escape $'line1\nline2')
  assert_contains "line1" "$result"
  assert_contains "line2" "$result"
}

function test_json_escape_special_chars() {
  local result
  result=$(_json_escape $'tab\there')
  assert_not_empty "$result"
}

function test_json_escape_without_jq() {
  local orig_path="$PATH"
  PATH=$(echo "$PATH" | tr ':' '\n' | grep -v -E '/jq$|/jq/' | tr '\n' ':')
  local result
  result=$(_json_escape 'hello "world"')
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
  local result
  result=$(_md5 "test input")
  assert_not_empty "$result"
  assert_matches "^[a-f0-9]+$" "$result"
}

function test_md5_consistent() {
  local h1 h2
  h1=$(_md5 "consistent")
  h2=$(_md5 "consistent")
  assert_equals "$h1" "$h2"
}

function test_md5_different_inputs() {
  local h1 h2
  h1=$(_md5 "input_a")
  h2=$(_md5 "input_b")
  assert_not_same "$h1" "$h2"
}

function test_md5_empty_string() {
  local result
  result=$(_md5 "")
  assert_not_empty "$result"
}

function test_md5_long_string() {
  local result
  result=$(_md5 "$(seq 1 1000)")
  assert_not_empty "$result"
  assert_matches "^[a-f0-9]+$" "$result"
}

###
### _get_setting
###

function test_get_setting_returns_value() {
  _CFG["theme"]="dark"
  local result
  result=$(_get_setting "theme" "light")
  assert_equals "dark" "$result"
}

function test_get_setting_returns_default() {
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  local result
  result=$(_get_setting "missing_key" "default_val")
  assert_equals "default_val" "$result"
}

function test_get_setting_empty_value_returns_default() {
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _CFG["empty_key"]=""
  local result
  result=$(_get_setting "empty_key" "fallback")
  assert_equals "fallback" "$result"
}

function test_get_setting_empty_default() {
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  local result
  result=$(_get_setting "absent_key" "")
  assert_equals "" "$result"
}

###
### _parse_config
###

function test_parse_config_reads_front_matter() {
  printf '%s\n' '---' 'enabled: true' 'debug_mode: false' '---' >"$CONFIG"
  unset _CFG 2>/dev/null || true
  declare -gA _CFG=()
  _parse_config
  assert_equals "true" "${_CFG[enabled]}"
  assert_equals "false" "${_CFG[debug_mode]}"
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
  local result
  result=$(printf '%s' '{"prompt":"hello"}' | _read_stdin_payload)
  assert_equals '{"prompt":"hello"}' "$result"
}

function test_read_stdin_payload_empty_pipe() {
  local result
  result=$(_read_stdin_payload </dev/null)
  assert_empty "$result"
}

function test_read_stdin_payload_multiline() {
  local payload=$'line1\nline2\nline3'
  local result
  result=$(printf '%s' "$payload" | _read_stdin_payload)
  assert_contains "line1" "$result"
  assert_contains "line3" "$result"
}

function test_read_stdin_payload_preserves_json() {
  local json='{"prompt":"test","session_id":"abc-123"}'
  local result
  result=$(printf '%s' "$json" | _read_stdin_payload)
  assert_equals "$json" "$result"
}

###
### Main integration tests (subprocess)
###

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

###
### Main sourced tests (with mocking)
###

function _setup_mock_env() {
  _MOCK_DIR=$(mktemp -d)
  _ORIG_PATH="$PATH"

  cat >"$_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"mocked enhanced prompt","session_id":"mock-session-123"}'
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

function _teardown_mock_env() {
  rm -rf "$_MOCK_DIR"
  PATH="$_ORIG_PATH"
  export PATH
  unset _MOCK_DIR _ORIG_PATH
}

function test_main_sourced_outputs_continue_when_disabled() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: false' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"hello","session_id":"ses1"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="ses1" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
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
  result=$(printf '%s' '{"prompt":"/help","session_id":"ses2"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="ses2" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
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
  assert_contains "block" "$result"
  rm -rf "$tmpdir"
  _teardown_mock_env
}

function test_main_sourced_debug_mode_output() {
  _setup_mock_env
  local tmpdir tmpcfg
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' 'debug_mode: true' 'correction: false' 'enhancement: false' 'translation: false' 'audit: false' >"$tmpcfg"
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
  local sentinel="$tmpdir/.claude/.better-prompt-sentinel"
  local hash
  hash=$(_md5 "hello world")
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
  tmpcfg=$(mktemp "$tmpdir/cfg.XXXXXX")
  printf '%s\n' '---' 'enabled: true' 'correction: false' 'enhancement: false' 'translation: false' 'audit: true' >"$tmpcfg"
  local result
  result=$(printf '%s' '{"prompt":"hello world","session_id":"ses9"}' | BETTER_PROMPT_CONFIG="$tmpcfg" CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="ses9" bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "block" "$result"
  assert_file_exists "$tmpdir/.claude/prompts.json"
  local log_content
  log_content=$(cat "$tmpdir/.claude/prompts.json")
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
