#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function set_up_before_script() {
  # Source common.sh only — needed for _config_read_single to verify file mutations.
  # CLAUDE_PLUGIN_ROOT not needed — common.sh doesn't resolve PLUGIN_ROOT itself.
  # See .claude/rules/testing.md — "Sourcing Scripts Under Test"
  local _opts
  _opts=$(shopt -po errexit nounset pipefail 2>/dev/null || true)
  source "$PROJECT_ROOT/hooks/scripts/lib/common.sh"
  eval "$_opts"
}

function set_up() {
  _CONFIG_FILE=$(bashunit::temp_file)
  cat >"$_CONFIG_FILE" <<'CFG'
---
enabled: true
correction: true
correction_model: haiku
translation: false
translation_model: haiku
enhancement: false
enhancement_model: sonnet
audit: true
verbose: false
---
# Body content below
CFG
}

function tear_down() {
  rm -f "$_CONFIG_FILE"
}

###
### Happy path
###

function test_main_config_updates_boolean_setting() {
  local result
  result=$(printf '%s' '{"command_args":"verbose on","command_name":"better-prompt:config"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/config-hook.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "verbose is now true" "$reason"
  local val
  val=$(_config_read_single "$_CONFIG_FILE" "verbose" "")
  assert_equals "true" "$val"
}

function test_main_config_updates_model_setting() {
  local result
  result=$(printf '%s' '{"command_args":"correction_model sonnet","command_name":"better-prompt:config"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/config-hook.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "correction_model is now sonnet" "$reason"
  local val
  val=$(_config_read_single "$_CONFIG_FILE" "correction_model" "")
  assert_equals "sonnet" "$val"
}

function test_main_config_normalises_value() {
  local result
  result=$(printf '%s' '{"command_args":"audit yes","command_name":"better-prompt:config"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/config-hook.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "audit is now true" "$reason"
  local val
  val=$(_config_read_single "$_CONFIG_FILE" "audit" "")
  assert_equals "true" "$val"
}

function test_main_config_preserves_other_settings() {
  printf '%s' '{"command_args":"verbose on","command_name":"better-prompt:config"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/config-hook.sh" >/dev/null 2>&1
  local correction audit model
  correction=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  audit=$(_config_read_single "$_CONFIG_FILE" "audit" "")
  model=$(_config_read_single "$_CONFIG_FILE" "correction_model" "")
  assert_equals "true" "$correction"
  assert_equals "true" "$audit"
  assert_equals "haiku" "$model"
}

###
### Validation errors
###

function test_main_config_missing_value_shows_usage() {
  local result
  result=$(printf '%s' '{"command_args":"verbose","command_name":"better-prompt:config"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/config-hook.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Usage" "$reason"
  assert_contains "Settings" "$reason"
}

function test_main_config_unknown_setting_shows_error() {
  local result
  result=$(printf '%s' '{"command_args":"unknown true","command_name":"better-prompt:config"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/config-hook.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Unknown setting" "$reason"
}

function test_main_config_invalid_boolean_value_shows_hint() {
  local result
  result=$(printf '%s' '{"command_args":"enabled maybe","command_name":"better-prompt:config"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/config-hook.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Invalid value" "$reason"
  assert_contains "true/false" "$reason"
}

function test_main_config_invalid_model_value_shows_hint() {
  local result
  result=$(printf '%s' '{"command_args":"correction_model bad@model","command_name":"better-prompt:config"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/config-hook.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Invalid value" "$reason"
  assert_contains "alphanumeric" "$reason"
}

function test_main_config_missing_config_file() {
  local result
  result=$(printf '%s' '{"command_args":"verbose on","command_name":"better-prompt:config"}' |
    BETTER_PROMPT_CONFIG="/nonexistent/file.md" bash "$PROJECT_ROOT/hooks/scripts/config-hook.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "not found" "$reason"
}

###
### Pass-through (silent exit, no output)
###

function test_main_config_empty_payload_pass_through() {
  local result
  result=$(echo "" | BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/config-hook.sh" 2>/dev/null || true)
  assert_empty "$result"
}

function test_main_config_no_args_pass_through() {
  local result
  result=$(printf '%s' '{"command_args":"","command_name":"better-prompt:config"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/config-hook.sh" 2>/dev/null || true)
  assert_empty "$result"
}
