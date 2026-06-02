#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

function set_up_before_script() {
  source "$PROJECT_ROOT/hooks/scripts/toggle.sh"
}

function set_up() {
  _CONFIG_FILE=$(bashunit::temp_file)
  _CONFIG_ORIG="$CONFIG"
  CONFIG="$_CONFIG_FILE"
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
  CONFIG="$_CONFIG_ORIG"
}

###
### _config_write_single
###

function test_config_write_single_updates_existing_key() {
  _config_write_single "$_CONFIG_FILE" "verbose" "true"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "verbose" "")
  assert_equals "true" "$result"
}

function test_config_write_single_false_to_true() {
  _config_write_single "$_CONFIG_FILE" "translation" "true"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "translation" "")
  assert_equals "true" "$result"
}

function test_config_write_single_true_to_false() {
  _config_write_single "$_CONFIG_FILE" "correction" "false"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  assert_equals "false" "$result"
}

function test_config_write_single_preserves_other_keys() {
  _config_write_single "$_CONFIG_FILE" "verbose" "true"
  local correction audit
  correction=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  audit=$(_config_read_single "$_CONFIG_FILE" "audit" "")
  assert_equals "true" "$correction"
  assert_equals "true" "$audit"
}

function test_config_write_single_preserves_body() {
  _config_write_single "$_CONFIG_FILE" "verbose" "true"
  local body
  body=$(awk 'NR>1' "$_CONFIG_FILE" | tail -n +2 | grep "Body content below")
  assert_contains "Body content below" "$body"
}

function test_config_write_single_missing_file() {
  local result
  result=$(_config_write_single "/nonexistent/file.md" "verbose" "true") && result="ok" || result="fail"
  assert_equals "fail" "$result"
}

function test_config_write_single_key_not_found_no_side_effect() {
  local before after
  before=$(cat "$_CONFIG_FILE")
  _config_write_single "$_CONFIG_FILE" "nonexistent_key" "true"
  after=$(cat "$_CONFIG_FILE")
  # File content should be identical since key was not found
  assert_equals "$before" "$after"
}

function test_config_write_single_preserves_model_values() {
  _config_write_single "$_CONFIG_FILE" "verbose" "true"
  local model
  model=$(_config_read_single "$_CONFIG_FILE" "correction_model" "")
  assert_equals "haiku" "$model"
}

###
### toggle::validate_stage
###

function test_validate_stage_enabled() {
  toggle::validate_stage "enabled"
  assert_successful_code
}

function test_validate_stage_correction() {
  toggle::validate_stage "correction"
  assert_successful_code
}

function test_validate_stage_translation() {
  toggle::validate_stage "translation"
  assert_successful_code
}

function test_validate_stage_enhancement() {
  toggle::validate_stage "enhancement"
  assert_successful_code
}

function test_validate_stage_audit() {
  toggle::validate_stage "audit"
  assert_successful_code
}

function test_validate_stage_verbose() {
  toggle::validate_stage "verbose"
  assert_successful_code
}

function test_validate_stage_invalid() {
  toggle::validate_stage "typo"
  assert_failing_code
}

function test_validate_stage_model_key_rejected() {
  toggle::validate_stage "correction_model"
  assert_failing_code
}

function test_validate_stage_empty() {
  toggle::validate_stage ""
  assert_failing_code
}

function test_validate_stage_partial_name() {
  toggle::validate_stage "correct"
  assert_failing_code
}

###
### toggle::resolve_new_value
###

function test_resolve_new_value_on() {
  local result
  result=$(toggle::resolve_new_value "false" "on")
  assert_equals "true" "$result"
}

function test_resolve_new_value_off() {
  local result
  result=$(toggle::resolve_new_value "true" "off")
  assert_equals "false" "$result"
}

function test_resolve_new_value_flip_true_to_false() {
  local result
  result=$(toggle::resolve_new_value "true" "")
  assert_equals "false" "$result"
}

function test_resolve_new_value_flip_false_to_true() {
  local result
  result=$(toggle::resolve_new_value "false" "")
  assert_equals "true" "$result"
}

function test_resolve_new_value_invalid_returns_empty() {
  local result
  result=$(toggle::resolve_new_value "true" "maybe")
  assert_empty "$result"
}

function test_resolve_new_value_on_overrides_false() {
  local result
  result=$(toggle::resolve_new_value "false" "on")
  assert_equals "true" "$result"
}

function test_resolve_new_value_off_overrides_true() {
  local result
  result=$(toggle::resolve_new_value "true" "off")
  assert_equals "false" "$result"
}

###
### toggle::format_confirm
###

function test_format_confirm_enabled_on() {
  local result
  result=$(toggle::format_confirm "enabled" "true")
  assert_equals "Plugin is now ENABLED" "$result"
}

function test_format_confirm_enabled_off() {
  local result
  result=$(toggle::format_confirm "enabled" "false")
  assert_equals "Plugin is now DISABLED (all stages inactive)" "$result"
}

function test_format_confirm_stage_on() {
  local result
  result=$(toggle::format_confirm "correction" "true")
  assert_equals "correction is now ON" "$result"
}

function test_format_confirm_stage_off() {
  local result
  result=$(toggle::format_confirm "audit" "false")
  assert_equals "audit is now OFF" "$result"
}

###
### toggle::format_response
###

function test_format_response_valid_json() {
  local result
  result=$(toggle::format_response "test message")
  echo "$result" | jq -e . >/dev/null
  assert_successful_code
}

function test_format_response_has_block_decision() {
  local result
  result=$(toggle::format_response "test")
  local decision
  decision=$(echo "$result" | jq -r '.decision')
  assert_equals "block" "$decision"
}

function test_format_response_has_reason() {
  local result
  result=$(toggle::format_response "correction is now ON")
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "correction is now ON" "$reason"
}

function test_format_response_special_chars() {
  local result
  result=$(toggle::format_response "it's a \"test\"")
  echo "$result" | jq -e . >/dev/null
  assert_successful_code
}

###
### Main integration (subprocess)
###

function test_main_toggle_correction_off() {
  local result
  result=$(printf '%s' '{"command_args":"correction off","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "correction" "$reason"
  assert_contains "OFF" "$reason"
  # Verify file was updated
  local val
  val=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  assert_equals "false" "$val"
}

function test_main_toggle_verbose_on() {
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

function test_main_toggle_flip() {
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

function test_main_toggle_no_change() {
  local result
  result=$(printf '%s' '{"command_args":"correction on","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "already" "$reason"
  # Value should not have changed
  local val
  val=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  assert_equals "true" "$val"
}

function test_main_toggle_invalid_stage() {
  local result
  result=$(printf '%s' '{"command_args":"invalid_stage","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Unknown stage" "$reason"
}

function test_main_toggle_invalid_value() {
  local result
  result=$(printf '%s' '{"command_args":"correction maybe","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Invalid value" "$reason"
}

function test_main_toggle_no_args() {
  local result
  result=$(printf '%s' '{"command_args":"","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local decision reason
  decision=$(echo "$result" | jq -r '.decision')
  reason=$(echo "$result" | jq -r '.reason')
  assert_equals "block" "$decision"
  assert_contains "Usage" "$reason"
}

function test_main_toggle_empty_payload_pass_through() {
  local result
  result=$(echo "" | BETTER_PROMPT_CONFIG="$_CONFIG_FILE" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null || true)
  assert_empty "$result"
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

function test_main_toggle_missing_config() {
  local result
  result=$(printf '%s' '{"command_args":"verbose on","command_name":"better-prompt:toggle"}' |
    BETTER_PROMPT_CONFIG="/nonexistent/file.md" bash "$PROJECT_ROOT/hooks/scripts/toggle.sh" 2>/dev/null)
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "not found" "$reason"
}

function test_main_toggle_enabled_off() {
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

function test_main_toggle_enabled_on() {
  # First disable, then re-enable
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
