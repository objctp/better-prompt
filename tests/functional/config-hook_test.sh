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
### Full validation pipeline: validate_setting → setting_type → validate_value
###

function test_should_deduce_type_and_validate_boolean_pipeline() {
  config::validate_setting "audit"
  assert_successful_code
  local type
  type=$(config::setting_type "audit")
  assert_equals "boolean" "$type"
  config::validate_value "audit" "on"
  assert_successful_code
}

function test_should_deduce_type_and_validate_model_pipeline() {
  config::validate_setting "enhancement_model"
  assert_successful_code
  local type
  type=$(config::setting_type "enhancement_model")
  assert_equals "model" "$type"
  config::validate_value "enhancement_model" "opus"
  assert_successful_code
}

function test_should_reject_pipeline_for_invalid_setting_with_valid_value() {
  config::validate_setting "typo"
  assert_general_error
}

function test_should_reject_pipeline_for_valid_setting_with_wrong_type_value() {
  config::validate_setting "enabled"
  assert_successful_code
  config::validate_value "enabled" "haiku"
  assert_general_error
}

###
### Normalise → write → read round-trip (boolean)
###

function test_should_round_trip_boolean_on_to_true() {
  local normalised
  normalised=$(config::normalise_value "verbose" "on")
  assert_equals "true" "$normalised"
  _config_write_single "$_CONFIG_FILE" "verbose" "$normalised"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "verbose" "")
  assert_equals "true" "$result"
}

function test_should_round_trip_boolean_yes_to_true() {
  local normalised
  normalised=$(config::normalise_value "audit" "yes")
  assert_equals "true" "$normalised"
  _config_write_single "$_CONFIG_FILE" "audit" "$normalised"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "audit" "")
  assert_equals "true" "$result"
}

function test_should_round_trip_boolean_off_to_false() {
  local normalised
  normalised=$(config::normalise_value "correction" "off")
  assert_equals "false" "$normalised"
  _config_write_single "$_CONFIG_FILE" "correction" "$normalised"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  assert_equals "false" "$result"
}

function test_should_round_trip_boolean_no_to_false() {
  local normalised
  normalised=$(config::normalise_value "enabled" "no")
  assert_equals "false" "$normalised"
  _config_write_single "$_CONFIG_FILE" "enabled" "$normalised"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "enabled" "")
  assert_equals "false" "$result"
}

function test_should_round_trip_boolean_true_unchanged() {
  local normalised
  normalised=$(config::normalise_value "translation" "true")
  assert_equals "true" "$normalised"
  _config_write_single "$_CONFIG_FILE" "translation" "$normalised"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "translation" "")
  assert_equals "true" "$result"
}

###
### Normalise → write → read round-trip (model)
###

function test_should_round_trip_model_passthrough() {
  local normalised
  normalised=$(config::normalise_value "correction_model" "opus")
  assert_equals "opus" "$normalised"
  _config_write_single "$_CONFIG_FILE" "correction_model" "$normalised"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "correction_model" "")
  assert_equals "opus" "$result"
}

function test_should_round_trip_model_with_dashes() {
  local normalised
  normalised=$(config::normalise_value "enhancement_model" "claude-sonnet-4-6")
  assert_equals "claude-sonnet-4-6" "$normalised"
  _config_write_single "$_CONFIG_FILE" "enhancement_model" "$normalised"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "enhancement_model" "")
  assert_equals "claude-sonnet-4-6" "$result"
}

###
### Write isolation: other settings preserved
###

function test_should_preserve_other_keys_when_writing_boolean() {
  local correction_before model_before
  correction_before=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  model_before=$(_config_read_single "$_CONFIG_FILE" "correction_model" "")
  local normalised
  normalised=$(config::normalise_value "verbose" "on")
  _config_write_single "$_CONFIG_FILE" "verbose" "$normalised"
  local correction_after model_after
  correction_after=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  model_after=$(_config_read_single "$_CONFIG_FILE" "correction_model" "")
  assert_equals "$correction_before" "$correction_after"
  assert_equals "$model_before" "$model_after"
}

function test_should_preserve_other_keys_when_writing_model() {
  local audit_before verbose_before
  audit_before=$(_config_read_single "$_CONFIG_FILE" "audit" "")
  verbose_before=$(_config_read_single "$_CONFIG_FILE" "verbose" "")
  local normalised
  normalised=$(config::normalise_value "translation_model" "sonnet")
  _config_write_single "$_CONFIG_FILE" "translation_model" "$normalised"
  local audit_after verbose_after
  audit_after=$(_config_read_single "$_CONFIG_FILE" "audit" "")
  verbose_after=$(_config_read_single "$_CONFIG_FILE" "verbose" "")
  assert_equals "$audit_before" "$audit_after"
  assert_equals "$verbose_before" "$verbose_after"
}

###
### Sequential writes
###

function test_should_apply_sequential_boolean_writes() {
  local n1 n2
  n1=$(config::normalise_value "verbose" "on")
  _config_write_single "$_CONFIG_FILE" "verbose" "$n1"
  n2=$(config::normalise_value "audit" "off")
  _config_write_single "$_CONFIG_FILE" "audit" "$n2"
  local verbose audit
  verbose=$(_config_read_single "$_CONFIG_FILE" "verbose" "")
  audit=$(_config_read_single "$_CONFIG_FILE" "audit" "")
  assert_equals "true" "$verbose"
  assert_equals "false" "$audit"
}

function test_should_apply_mixed_boolean_and_model_writes() {
  local n1 n2 n3
  n1=$(config::normalise_value "enhancement" "yes")
  _config_write_single "$_CONFIG_FILE" "enhancement" "$n1"
  n2=$(config::normalise_value "enhancement_model" "opus")
  _config_write_single "$_CONFIG_FILE" "enhancement_model" "$n2"
  n3=$(config::normalise_value "verbose" "no")
  _config_write_single "$_CONFIG_FILE" "verbose" "$n3"
  local enhancement model verbose
  enhancement=$(_config_read_single "$_CONFIG_FILE" "enhancement" "")
  model=$(_config_read_single "$_CONFIG_FILE" "enhancement_model" "")
  verbose=$(_config_read_single "$_CONFIG_FILE" "verbose" "")
  assert_equals "true" "$enhancement"
  assert_equals "opus" "$model"
  assert_equals "false" "$verbose"
}

###
### Error propagation in pipeline
###

function test_should_fail_write_when_config_missing() {
  local normalised
  normalised=$(config::normalise_value "verbose" "on")
  local result
  result=$(_config_write_single "/nonexistent/file.md" "verbose" "$normalised") && result="ok" || result="fail"
  assert_equals "fail" "$result"
}

function test_should_not_mutate_file_when_key_not_found() {
  local before
  before=$(cat "$_CONFIG_FILE")
  _config_write_single "$_CONFIG_FILE" "nonexistent_key" "true"
  local after
  after=$(cat "$_CONFIG_FILE")
  assert_equals "$before" "$after"
}

function test_should_preserve_body_content_after_write() {
  local normalised
  normalised=$(config::normalise_value "verbose" "on")
  _config_write_single "$_CONFIG_FILE" "verbose" "$normalised"
  local body
  body=$(awk 'NR>1' "$_CONFIG_FILE" | tail -n +2 | grep "Body content below")
  assert_contains "Body content below" "$body"
}
