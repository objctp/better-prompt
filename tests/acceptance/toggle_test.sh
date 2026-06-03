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

function test_main_toggle_turns_correction_off() {
  local result
  result=$(printf '%s' '{"command_args":"correction off","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "correction" "$reason"
  assert_contains "OFF" "$reason"
  local val
  val=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  assert_equals "false" "$val"
}

function test_main_toggle_turns_verbose_on() {
  local result
  result=$(printf '%s' '{"command_args":"verbose on","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local decision
  decision=$(echo "$result" | jq -r '.decision')
  assert_equals "block" "$decision"
  local val
  val=$(_config_read_single "$_CONFIG_FILE" "verbose" "")
  assert_equals "true" "$val"
}

function test_main_toggle_flips_audit() {
  local result
  result=$(printf '%s' '{"command_args":"audit","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local decision
  decision=$(echo "$result" | jq -r '.decision')
  assert_equals "block" "$decision"
  local val
  val=$(_config_read_single "$_CONFIG_FILE" "audit" "")
  assert_equals "false" "$val"
}

function test_main_toggle_disables_plugin() {
  local result
  result=$(printf '%s' '{"command_args":"enabled off","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "DISABLED" "$reason"
  local val
  val=$(_config_read_single "$_CONFIG_FILE" "enabled" "")
  assert_equals "false" "$val"
}

function test_main_toggle_enables_plugin() {
  _config_write_single "$_CONFIG_FILE" "enabled" "false"
  local result
  result=$(printf '%s' '{"command_args":"enabled on","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "ENABLED" "$reason"
  local val
  val=$(_config_read_single "$_CONFIG_FILE" "enabled" "")
  assert_equals "true" "$val"
}

function test_main_toggle_preserves_other_settings() {
  printf '%s' '{"command_args":"verbose on","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" >/dev/null 2>&1
  local correction audit model
  correction=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  audit=$(_config_read_single "$_CONFIG_FILE" "audit" "")
  model=$(_config_read_single "$_CONFIG_FILE" "correction_model" "")
  assert_equals "true" "$correction"
  assert_equals "true" "$audit"
  assert_equals "haiku" "$model"
}

###
### No change
###

function test_main_toggle_reports_no_change_when_already_at_target() {
  local result
  result=$(printf '%s' '{"command_args":"correction on","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "already" "$reason"
  local val
  val=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  assert_equals "true" "$val"
}

###
### Validation errors
###

function test_main_toggle_rejects_unknown_stage() {
  local result
  result=$(printf '%s' '{"command_args":"invalid_stage","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Unknown stage" "$reason"
}

function test_main_toggle_rejects_invalid_value() {
  local result
  result=$(printf '%s' '{"command_args":"correction maybe","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Invalid value" "$reason"
}

function test_main_toggle_shows_usage_when_no_args() {
  local result
  result=$(printf '%s' '{"command_args":"","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Usage" "$reason"
}

###
### Edge cases
###

function test_main_toggle_passes_through_on_empty_payload() {
  local result
  result=$(echo "" | BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null || true)
  assert_empty "$result"
}

function test_main_toggle_reports_missing_config() {
  local result
  result=$(printf '%s' '{"command_args":"verbose on","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="/nonexistent/file.md" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "not found" "$reason"
}
