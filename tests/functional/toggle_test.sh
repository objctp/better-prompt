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
### resolve → write → read round-trip (flip)
###

function test_should_round_trip_flip_false_to_true() {
  local new_value
  new_value=$(toggle::resolve_new_value "false" "")
  assert_equals "true" "$new_value"
  _config_write_single "$_CONFIG_FILE" "verbose" "$new_value"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "verbose" "")
  assert_equals "true" "$result"
}

function test_should_round_trip_flip_true_to_false() {
  local new_value
  new_value=$(toggle::resolve_new_value "true" "")
  assert_equals "false" "$new_value"
  _config_write_single "$_CONFIG_FILE" "correction" "$new_value"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  assert_equals "false" "$result"
}

###
### resolve → write → read round-trip (explicit on/off)
###

function test_should_round_trip_explicit_on() {
  local new_value
  new_value=$(toggle::resolve_new_value "false" "on")
  assert_equals "true" "$new_value"
  _config_write_single "$_CONFIG_FILE" "translation" "$new_value"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "translation" "")
  assert_equals "true" "$result"
}

function test_should_round_trip_explicit_off() {
  local new_value
  new_value=$(toggle::resolve_new_value "true" "off")
  assert_equals "false" "$new_value"
  _config_write_single "$_CONFIG_FILE" "audit" "$new_value"
  local result
  result=$(_config_read_single "$_CONFIG_FILE" "audit" "")
  assert_equals "false" "$result"
}

###
### Write isolation: other settings preserved
###

function test_should_preserve_other_keys_when_toggling() {
  local correction_before model_before
  correction_before=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  model_before=$(_config_read_single "$_CONFIG_FILE" "correction_model" "")
  local new_value
  new_value=$(toggle::resolve_new_value "false" "on")
  _config_write_single "$_CONFIG_FILE" "verbose" "$new_value"
  local correction_after model_after
  correction_after=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  model_after=$(_config_read_single "$_CONFIG_FILE" "correction_model" "")
  assert_equals "$correction_before" "$correction_after"
  assert_equals "$model_before" "$model_after"
}

###
### Sequential writes
###

function test_should_apply_sequential_on_off_toggles() {
  local n1 n2
  n1=$(toggle::resolve_new_value "false" "on")
  _config_write_single "$_CONFIG_FILE" "verbose" "$n1"
  n2=$(toggle::resolve_new_value "true" "off")
  _config_write_single "$_CONFIG_FILE" "audit" "$n2"
  local verbose audit
  verbose=$(_config_read_single "$_CONFIG_FILE" "verbose" "")
  audit=$(_config_read_single "$_CONFIG_FILE" "audit" "")
  assert_equals "true" "$verbose"
  assert_equals "false" "$audit"
}

function test_should_apply_sequential_flips() {
  local n1 n2
  n1=$(toggle::resolve_new_value "true" "")
  _config_write_single "$_CONFIG_FILE" "correction" "$n1"
  n2=$(toggle::resolve_new_value "false" "")
  _config_write_single "$_CONFIG_FILE" "translation" "$n2"
  local correction translation
  correction=$(_config_read_single "$_CONFIG_FILE" "correction" "")
  translation=$(_config_read_single "$_CONFIG_FILE" "translation" "")
  assert_equals "false" "$correction"
  assert_equals "true" "$translation"
}

###
### Error propagation
###

function test_should_fail_write_when_config_missing() {
  local new_value
  new_value=$(toggle::resolve_new_value "false" "on")
  local result
  result=$(_config_write_single "/nonexistent/file.md" "verbose" "$new_value") && result="ok" || result="fail"
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

function test_should_preserve_body_content_after_toggle() {
  local new_value
  new_value=$(toggle::resolve_new_value "false" "on")
  _config_write_single "$_CONFIG_FILE" "verbose" "$new_value"
  local body
  body=$(awk 'NR>1' "$_CONFIG_FILE" | tail -n +2 | grep "Body content below")
  assert_contains "Body content below" "$body"
}
