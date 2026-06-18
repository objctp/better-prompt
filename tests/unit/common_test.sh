#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function set_up_before_script() {
  # See .claude/rules/testing.md — "Sourcing Scripts Under Test"
  local _opts
  _opts=$(shopt -po errexit nounset pipefail 2>/dev/null || true)
  source "$PROJECT_ROOT/hooks/scripts/lib/common.sh"
  eval "$_opts"
}

function set_up() {
  VERBOSE="false"
  _DEBUG_LOG=""
}

###
### _warn
###

function test_should_format_stderr_with_prefix() {
  local result
  result=$(_warn "something went wrong" 2>&1 1>/dev/null)
  assert_contains "[better-prompt] WARNING:" "$result"
  assert_contains "something went wrong" "$result"
}

###
### _debug
###

function test_should_output_when_verbose_true() {
  VERBOSE="true"
  local result
  result=$(_debug "verbose msg" 2>&1 1>/dev/null)
  assert_contains "[better-prompt] DEBUG: verbose msg" "$result"
}

function test_should_be_silent_when_verbose_false() {
  VERBOSE="false"
  local result
  result=$(_debug "verbose msg" 2>&1 1>/dev/null)
  assert_empty "$result"
}

###
### _json_escape
###

function test_should_escape_plain_string() {
  local result
  result=$(_json_escape "hello world")
  assert_equals '"hello world"' "$result"
}

function test_should_escape_quotes() {
  local result
  result=$(_json_escape 'say "hi"')
  # Must be parseable JSON
  echo "$result" | jq -e . >/dev/null
  assert_successful_code
}

function test_should_escape_empty_string() {
  local result
  result=$(_json_escape "")
  assert_equals '""' "$result"
}

function test_should_escape_multiline() {
  local result
  result=$(_json_escape $'line1\nline2')
  echo "$result" | jq -e . >/dev/null
  assert_successful_code
  assert_contains "line1" "$result"
}

###
### _truncate_for_display
###

function test_should_return_single_line_unchanged() {
  local result
  result=$(_truncate_for_display "fix the auth bug")
  assert_equals "fix the auth bug" "$result"
}

function test_should_show_count_suffix_for_multiline() {
  local result
  result=$(_truncate_for_display $'fix the auth bug\nline two\nline three')
  assert_contains "fix the auth bug" "$result"
  assert_contains "[+2 lines]" "$result"
}

function test_should_trim_long_line_to_max_chars() {
  local long_line
  long_line=$(printf '%0.sx' {1..200})
  local result
  result=$(_truncate_for_display "$long_line")
  assert_equals "80" "${#result}"
}

function test_should_return_empty_for_empty_input() {
  local result
  result=$(_truncate_for_display "")
  assert_empty "$result"
}

###
### _atomic_write
###

function test_should_create_and_overwrite_file() {
  local target
  target=$(bashunit::temp_file)
  rm -f "$target"
  _atomic_write "$target" "first"
  assert_equals "first" "$(cat "$target")"
  _atomic_write "$target" "second"
  assert_equals "second" "$(cat "$target")"
}

function test_should_fail_on_invalid_path() {
  _atomic_write "/nonexistent/dir/file.txt" "content" 2>/dev/null
  assert_general_error
}

###
### _md5
###

function test_should_return_hex_hash() {
  local result
  result=$(_md5 "test input")
  assert_matches "^[a-f0-9]+$" "$result"
}

function test_should_return_consistent_hash() {
  local h1 h2
  h1=$(_md5 "consistent")
  h2=$(_md5 "consistent")
  assert_equals "$h1" "$h2"
}

function test_should_differ_for_different_input() {
  local h1 h2
  h1=$(_md5 "input_a")
  h2=$(_md5 "input_b")
  assert_not_equals "$h1" "$h2"
}

###
### _read_payload
###

function test_should_read_from_pipe() {
  local result
  result=$(printf '%s' '{"prompt":"hello"}' | _read_payload)
  assert_equals '{"prompt":"hello"}' "$result"
}

function test_should_return_empty_from_dev_null() {
  local result
  result=$(_read_payload </dev/null)
  assert_empty "$result"
}

###
### _extract_command_args
###

function test_should_extract_command_args_from_payload() {
  local result
  result=$(_extract_command_args '{"command_args":"verbose on","command_name":"test"}')
  assert_equals "verbose on" "$result"
}

function test_should_return_empty_when_field_missing() {
  local result
  result=$(_extract_command_args '{"command_name":"test"}')
  assert_empty "$result"
}

###
### _format_block_response
###

function test_should_produce_valid_block_json() {
  local result
  result=$(_format_block_response "test message")
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "test message" "$reason"
}

function test_should_escape_quotes_in_message() {
  local result
  result=$(_format_block_response 'it'\''s a "test"')
  echo "$result" | jq -e . >/dev/null
  assert_successful_code
}

###
### _parse_config
###

function test_should_read_frontmatter_and_strip_comments() {
  local _config_file
  _config_file=$(bashunit::temp_file)
  printf '%s\n' '---' 'enabled: true # comment' 'verbose: false' '---' >"$_config_file"
  CONFIG="$_config_file"
  declare -gA _CFG=()
  _parse_config _CFG
  assert_equals "true" "${_CFG[enabled]}"
  assert_equals "false" "${_CFG[verbose]}"
}

function test_should_strip_whitespace_around_values() {
  local _config_file
  _config_file=$(bashunit::temp_file)
  printf '%s\n' '---' 'model:   sonnet  ' >"$_config_file"
  CONFIG="$_config_file"
  declare -gA _CFG=()
  _parse_config _CFG
  assert_equals "sonnet" "${_CFG[model]}"
}

function test_should_ignore_body_content() {
  local _config_file
  _config_file=$(bashunit::temp_file)
  printf '%s\n' '---' 'enabled: true' '---' 'body_key: ignored' >"$_config_file"
  CONFIG="$_config_file"
  declare -gA _CFG=()
  _parse_config _CFG
  assert_equals "true" "${_CFG[enabled]}"
  assert_empty "${_CFG[body_key]}"
}

function test_should_not_fail_on_missing_file() {
  CONFIG="/nonexistent/path/config.md"
  declare -gA _CFG=()
  _parse_config _CFG
  assert_successful_code
}

###
### _get_setting
###

function test_should_return_value_when_key_exists() {
  declare -gA _CFG=()
  _CFG["theme"]="dark"
  local result
  result=$(_get_setting "theme" "light")
  assert_equals "dark" "$result"
}

function test_should_return_default_when_key_missing() {
  declare -gA _CFG=()
  local result
  result=$(_get_setting "missing_key" "default_val")
  assert_equals "default_val" "$result"
}

function test_should_treat_empty_value_as_valid_not_fallback() {
  # Uses ${var-default} (no colon) — empty string is a valid value, not missing
  declare -gA _CFG=()
  _CFG["empty_key"]=""
  local result
  result=$(_get_setting "empty_key" "fallback")
  assert_equals "" "$result"
}

###
### _b64decode
###

function test_should_decode_plain_text() {
  local encoded result
  encoded=$(printf '%s' "hello" | base64)
  result=$(printf '%s' "$encoded" | _b64decode)
  assert_equals "hello" "$result"
}

function test_should_decode_multiline_text() {
  local original=$'line1\nline2\nline3'
  local encoded result
  encoded=$(printf '%s' "$original" | base64)
  result=$(printf '%s' "$encoded" | _b64decode)
  assert_equals "$original" "$result"
}

function test_should_decode_special_characters() {
  local original=$'tab\there\nquote: "\nprefix/@src'
  local encoded result
  encoded=$(printf '%s' "$original" | base64)
  result=$(printf '%s' "$encoded" | _b64decode)
  assert_equals "$original" "$result"
}

function test_should_be_idempotent_on_empty_input() {
  local result
  result=$(printf '' | _b64decode)
  assert_empty "$result"
}
