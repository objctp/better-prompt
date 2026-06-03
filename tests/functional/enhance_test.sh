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
  _CONTEXT_FILE=$(bashunit::temp_file)
  _AUDIT_FILE=$(bashunit::temp_file)
  _SENTINEL_FILE=$(bashunit::temp_file)
}

function tear_down() {
  rm -f "$_CONTEXT_FILE" "$_AUDIT_FILE" "$_SENTINEL_FILE"
}

###
### enhance::extract_prior_context
###

function test_should_extract_recent_entries_from_file() {
  printf '%s\n' "first prompt" "second prompt" "third prompt" >"$_CONTEXT_FILE"
  local result
  result=$(enhance::extract_prior_context "$_CONTEXT_FILE" 2)
  assert_contains '1. "second prompt"' "$result"
  assert_contains '2. "third prompt"' "$result"
  assert_not_contains "first prompt" "$result"
}

function test_should_return_nothing_for_missing_file() {
  local result
  result=$(enhance::extract_prior_context "/nonexistent/file" 5)
  assert_empty "$result"
}

function test_should_return_nothing_when_count_is_zero() {
  printf '%s\n' "first prompt" >"$_CONTEXT_FILE"
  local result
  result=$(enhance::extract_prior_context "$_CONTEXT_FILE" 0)
  assert_empty "$result"
}

###
### enhance::append_prior_context
###

function test_should_append_to_file() {
  printf '%s\n' "first" >"$_CONTEXT_FILE"
  enhance::append_prior_context "$_CONTEXT_FILE" 5 "second"
  local result
  result=$(cat "$_CONTEXT_FILE")
  assert_contains "first" "$result"
  assert_contains "second" "$result"
}

function test_should_trim_to_window_size() {
  printf '%s\n' "line1" "line2" "line3" >"$_CONTEXT_FILE"
  enhance::append_prior_context "$_CONTEXT_FILE" 2 "line4"
  local result
  result=$(cat "$_CONTEXT_FILE")
  assert_not_contains "line1" "$result"
  assert_not_contains "line2" "$result"
  assert_contains "line3" "$result"
  assert_contains "line4" "$result"
}

function test_should_skip_when_text_is_empty() {
  printf '%s\n' "existing" >"$_CONTEXT_FILE"
  local before
  before=$(cat "$_CONTEXT_FILE")
  enhance::append_prior_context "$_CONTEXT_FILE" 5 ""
  local after
  after=$(cat "$_CONTEXT_FILE")
  assert_equals "$before" "$after"
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
