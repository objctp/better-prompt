#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function set_up_before_script() {
  # See .claude/rules/testing.md — "Sourcing Scripts Under Test"
  local _opts
  _opts=$(shopt -po errexit nounset pipefail 2>/dev/null || true)
  CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT"
  source "$PROJECT_ROOT/hooks/scripts/enhance.sh"
  eval "$_opts"
}

function set_up() {
  _AUDIT_FILE=$(bashunit::temp_file)
  _SENTINEL_FILE=$(bashunit::temp_file)
}

function tear_down() {
  rm -f "$_AUDIT_FILE" "$_SENTINEL_FILE"
}

###
### enhance::write_audit
###

function test_should_write_valid_jsonl_entry_with_active_models() {
  enhance::write_audit "$_AUDIT_FILE" "original" "corrected" "enhanced" \
    '["spelling"]' '[{"type":"spelling","original":"helo","correction":"hello"}]' \
    "en" "true" "haiku" "false" "sonnet" "false" "opus"

  local line
  line=$(tail -1 "$_AUDIT_FILE")
  echo "$line" | jq -e . >/dev/null
  assert_successful_code
  local correction_model translation_model
  correction_model=$(echo "$line" | jq -r '.models.correction')
  translation_model=$(echo "$line" | jq -r '.models.translation')
  assert_equals "haiku" "$correction_model"
  assert_equals "null" "$translation_model"
}

function test_should_write_null_models_for_disabled_stages() {
  enhance::write_audit "$_AUDIT_FILE" "prompt" "prompt" "prompt" \
    '[]' '[]' "" "false" "haiku" "false" "sonnet" "false" "opus"

  local line
  line=$(tail -1 "$_AUDIT_FILE")
  local correction_model enhancement_model
  correction_model=$(echo "$line" | jq -r '.models.correction')
  enhancement_model=$(echo "$line" | jq -r '.models.enhancement')
  assert_equals "null" "$correction_model"
  assert_equals "null" "$enhancement_model"
}

###
### enhance::write_sentinel
###

function test_should_write_hash_to_file() {
  enhance::write_sentinel "$_SENTINEL_FILE" "test prompt"
  assert_file_exists "$_SENTINEL_FILE"
  local content
  content=$(cat "$_SENTINEL_FILE")
  assert_not_empty "$content"
}

function test_should_produce_consistent_hash_for_same_input() {
  enhance::write_sentinel "$_SENTINEL_FILE" "test prompt"
  local hash1
  hash1=$(cat "$_SENTINEL_FILE")
  : >"$_SENTINEL_FILE"
  enhance::write_sentinel "$_SENTINEL_FILE" "test prompt"
  local hash2
  hash2=$(cat "$_SENTINEL_FILE")
  assert_equals "$hash1" "$hash2"
}

###
### enhance::check_sentinel
###

function test_should_mismatch_when_file_missing() {
  enhance::check_sentinel "/nonexistent/sentinel" "test prompt"
  assert_general_error
}

function test_should_match_when_hash_matches_and_fresh() {
  local hash
  hash=$(_md5 "test prompt")
  printf '%s' "$hash" >"$_SENTINEL_FILE"
  enhance::check_sentinel "$_SENTINEL_FILE" "test prompt"
  assert_successful_code
}

function test_should_mismatch_when_hash_differs() {
  printf '%s' "wrong_hash" >"$_SENTINEL_FILE"
  enhance::check_sentinel "$_SENTINEL_FILE" "test prompt"
  assert_general_error
}
