#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function set_up_before_script() {
  # See .claude/rules/testing.md — "Sourcing Scripts Under Test"
  local _opts
  _opts=$(shopt -po errexit nounset pipefail 2>/dev/null || true)
  CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT"
  source "$PROJECT_ROOT/hooks/scripts/config-hook.sh"
  eval "$_opts"
}

###
### config::validate_setting
###

function test_should_accept_valid_setting_when_enabled() {
  config::validate_setting "enabled"
  assert_successful_code
}

function test_should_accept_valid_setting_when_correction() {
  config::validate_setting "correction"
  assert_successful_code
}

function test_should_accept_valid_setting_when_correction_model() {
  config::validate_setting "correction_model"
  assert_successful_code
}

function test_should_accept_valid_setting_when_translation() {
  config::validate_setting "translation"
  assert_successful_code
}

function test_should_accept_valid_setting_when_translation_model() {
  config::validate_setting "translation_model"
  assert_successful_code
}

function test_should_accept_valid_setting_when_enhancement() {
  config::validate_setting "enhancement"
  assert_successful_code
}

function test_should_accept_valid_setting_when_enhancement_model() {
  config::validate_setting "enhancement_model"
  assert_successful_code
}

function test_should_accept_valid_setting_when_audit() {
  config::validate_setting "audit"
  assert_successful_code
}

function test_should_accept_valid_setting_when_verbose() {
  config::validate_setting "verbose"
  assert_successful_code
}

function test_should_reject_setting_when_unknown() {
  config::validate_setting "unknown"
  assert_general_error
}

function test_should_reject_setting_when_empty() {
  config::validate_setting ""
  assert_general_error
}

function test_should_reject_setting_when_partial_name() {
  config::validate_setting "correct"
  assert_general_error
}

function test_should_reject_setting_when_wrong_case() {
  config::validate_setting "Enabled"
  assert_general_error
}

function test_should_reject_setting_when_leading_space() {
  config::validate_setting " enabled"
  assert_general_error
}

function test_should_reject_setting_when_trailing_space() {
  config::validate_setting "enabled "
  assert_general_error
}

###
### config::setting_type
###

function test_should_return_boolean_type_when_enabled() {
  local result
  result=$(config::setting_type "enabled")
  assert_equals "boolean" "$result"
}

function test_should_return_boolean_type_when_correction() {
  local result
  result=$(config::setting_type "correction")
  assert_equals "boolean" "$result"
}

function test_should_return_boolean_type_when_translation() {
  local result
  result=$(config::setting_type "translation")
  assert_equals "boolean" "$result"
}

function test_should_return_boolean_type_when_enhancement() {
  local result
  result=$(config::setting_type "enhancement")
  assert_equals "boolean" "$result"
}

function test_should_return_boolean_type_when_audit() {
  local result
  result=$(config::setting_type "audit")
  assert_equals "boolean" "$result"
}

function test_should_return_boolean_type_when_verbose() {
  local result
  result=$(config::setting_type "verbose")
  assert_equals "boolean" "$result"
}

function test_should_return_model_type_when_correction_model() {
  local result
  result=$(config::setting_type "correction_model")
  assert_equals "model" "$result"
}

function test_should_return_model_type_when_translation_model() {
  local result
  result=$(config::setting_type "translation_model")
  assert_equals "model" "$result"
}

function test_should_return_model_type_when_enhancement_model() {
  local result
  result=$(config::setting_type "enhancement_model")
  assert_equals "model" "$result"
}

function test_should_return_boolean_type_when_unrecognised_key() {
  local result
  result=$(config::setting_type "anything")
  assert_equals "boolean" "$result"
}

###
### config::validate_value — boolean
###

function test_should_accept_boolean_value_when_true() {
  config::validate_value "enabled" "true"
  assert_successful_code
}

function test_should_accept_boolean_value_when_false() {
  config::validate_value "enabled" "false"
  assert_successful_code
}

function test_should_accept_boolean_value_when_on() {
  config::validate_value "correction" "on"
  assert_successful_code
}

function test_should_accept_boolean_value_when_off() {
  config::validate_value "correction" "off"
  assert_successful_code
}

function test_should_accept_boolean_value_when_yes() {
  config::validate_value "audit" "yes"
  assert_successful_code
}

function test_should_accept_boolean_value_when_no() {
  config::validate_value "audit" "no"
  assert_successful_code
}

function test_should_reject_boolean_value_when_invalid() {
  config::validate_value "enabled" "maybe"
  assert_general_error
}

function test_should_reject_boolean_value_when_numeric() {
  config::validate_value "enabled" "1"
  assert_general_error
}

function test_should_reject_boolean_value_when_empty() {
  config::validate_value "enabled" ""
  assert_general_error
}

function test_should_reject_boolean_value_when_mixed_case() {
  config::validate_value "enabled" "True"
  assert_general_error
}

function test_should_reject_boolean_value_when_uppercase() {
  config::validate_value "enabled" "TRUE"
  assert_general_error
}

###
### config::validate_value — model
###

function test_should_accept_model_value_when_simple_name() {
  config::validate_value "correction_model" "haiku"
  assert_successful_code
}

function test_should_accept_model_value_when_full_id() {
  config::validate_value "correction_model" "claude-sonnet-4-6"
  assert_successful_code
}

function test_should_accept_model_value_when_with_dots() {
  config::validate_value "enhancement_model" "gpt-4.1"
  assert_successful_code
}

function test_should_accept_model_value_when_with_colons() {
  config::validate_value "translation_model" "model:v2"
  assert_successful_code
}

function test_should_accept_model_value_when_alphanumeric() {
  config::validate_value "correction_model" "model123"
  assert_successful_code
}

function test_should_reject_model_value_when_empty() {
  config::validate_value "correction_model" ""
  assert_general_error
}

function test_should_reject_model_value_when_has_spaces() {
  config::validate_value "correction_model" "sonnet 4"
  assert_general_error
}

function test_should_reject_model_value_when_has_special_chars() {
  config::validate_value "correction_model" "model@v2"
  assert_general_error
}

function test_should_reject_model_value_when_has_slash() {
  config::validate_value "correction_model" "org/model"
  assert_general_error
}

###
### config::normalise_value — booleans
###

function test_should_normalise_boolean_when_true_unchanged() {
  local result
  result=$(config::normalise_value "enabled" "true")
  assert_equals "true" "$result"
}

function test_should_normalise_boolean_when_false_unchanged() {
  local result
  result=$(config::normalise_value "enabled" "false")
  assert_equals "false" "$result"
}

function test_should_normalise_boolean_when_on_to_true() {
  local result
  result=$(config::normalise_value "correction" "on")
  assert_equals "true" "$result"
}

function test_should_normalise_boolean_when_off_to_false() {
  local result
  result=$(config::normalise_value "correction" "off")
  assert_equals "false" "$result"
}

function test_should_normalise_boolean_when_yes_to_true() {
  local result
  result=$(config::normalise_value "audit" "yes")
  assert_equals "true" "$result"
}

function test_should_normalise_boolean_when_no_to_false() {
  local result
  result=$(config::normalise_value "audit" "no")
  assert_equals "false" "$result"
}

###
### config::normalise_value — models
###

function test_should_passthrough_model_value_when_simple() {
  local result
  result=$(config::normalise_value "correction_model" "sonnet")
  assert_equals "sonnet" "$result"
}

function test_should_passthrough_model_value_when_full_id() {
  local result
  result=$(config::normalise_value "enhancement_model" "claude-opus-4-8")
  assert_equals "claude-opus-4-8" "$result"
}

function test_should_passthrough_model_value_when_with_dots() {
  local result
  result=$(config::normalise_value "translation_model" "gpt-4.1")
  assert_equals "gpt-4.1" "$result"
}
