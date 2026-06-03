#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function set_up_before_script() {
  # See .claude/rules/testing.md — "Sourcing Scripts Under Test"
  local _opts
  _opts=$(shopt -po errexit nounset pipefail 2>/dev/null || true)
  CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT"
  source "$PROJECT_ROOT/hooks/scripts/toggle.sh"
  eval "$_opts"
}

###
### toggle::validate_stage
###

function test_should_accept_valid_stage_when_enabled() {
  toggle::validate_stage "enabled"
  assert_successful_code
}

function test_should_accept_valid_stage_when_correction() {
  toggle::validate_stage "correction"
  assert_successful_code
}

function test_should_accept_valid_stage_when_translation() {
  toggle::validate_stage "translation"
  assert_successful_code
}

function test_should_accept_valid_stage_when_enhancement() {
  toggle::validate_stage "enhancement"
  assert_successful_code
}

function test_should_accept_valid_stage_when_audit() {
  toggle::validate_stage "audit"
  assert_successful_code
}

function test_should_accept_valid_stage_when_verbose() {
  toggle::validate_stage "verbose"
  assert_successful_code
}

function test_should_reject_stage_when_unknown() {
  toggle::validate_stage "typo"
  assert_general_error
}

function test_should_reject_stage_when_model_key() {
  toggle::validate_stage "correction_model"
  assert_general_error
}

function test_should_reject_stage_when_empty() {
  toggle::validate_stage ""
  assert_general_error
}

function test_should_reject_stage_when_partial_name() {
  toggle::validate_stage "correct"
  assert_general_error
}

function test_should_reject_stage_when_wrong_case() {
  toggle::validate_stage "Enabled"
  assert_general_error
}

function test_should_reject_stage_when_leading_space() {
  toggle::validate_stage " enabled"
  assert_general_error
}

function test_should_reject_stage_when_trailing_space() {
  toggle::validate_stage "enabled "
  assert_general_error
}

###
### toggle::resolve_new_value
###

function test_should_resolve_on_to_true() {
  local result
  result=$(toggle::resolve_new_value "false" "on")
  assert_equals "true" "$result"
}

function test_should_resolve_off_to_false() {
  local result
  result=$(toggle::resolve_new_value "true" "off")
  assert_equals "false" "$result"
}

function test_should_flip_true_to_false_when_no_arg() {
  local result
  result=$(toggle::resolve_new_value "true" "")
  assert_equals "false" "$result"
}

function test_should_flip_false_to_true_when_no_arg() {
  local result
  result=$(toggle::resolve_new_value "false" "")
  assert_equals "true" "$result"
}

function test_should_return_empty_when_invalid_arg() {
  local result
  result=$(toggle::resolve_new_value "true" "maybe")
  assert_empty "$result"
}

function test_should_override_current_true_with_on() {
  local result
  result=$(toggle::resolve_new_value "true" "on")
  assert_equals "true" "$result"
}

function test_should_override_current_false_with_off() {
  local result
  result=$(toggle::resolve_new_value "false" "off")
  assert_equals "false" "$result"
}

###
### toggle::format_confirm
###

function test_should_format_enabled_on() {
  local result
  result=$(toggle::format_confirm "enabled" "true")
  assert_equals "Plugin is now ENABLED" "$result"
}

function test_should_format_enabled_off() {
  local result
  result=$(toggle::format_confirm "enabled" "false")
  assert_equals "Plugin is now DISABLED (all stages inactive)" "$result"
}

function test_should_format_stage_on() {
  local result
  result=$(toggle::format_confirm "correction" "true")
  assert_equals "correction is now ON" "$result"
}

function test_should_format_stage_off() {
  local result
  result=$(toggle::format_confirm "audit" "false")
  assert_equals "audit is now OFF" "$result"
}
