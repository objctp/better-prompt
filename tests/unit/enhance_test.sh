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
  PROMPT_RESULT=""
  SESSION_ID_RESULT=""
  unset CLAUDE_SESSION_ID 2>/dev/null || true
}

###
### enhance::is_directive
###

function test_should_detect_slash_command() {
  enhance::is_directive "/command"
  assert_successful_code
}

function test_should_detect_exclamation_command() {
  enhance::is_directive "!command"
  assert_successful_code
}

function test_should_reject_regular_text() {
  enhance::is_directive "hello world"
  assert_general_error
}

function test_should_reject_empty_string() {
  enhance::is_directive ""
  assert_general_error
}

function test_should_detect_bare_slash() {
  enhance::is_directive "/"
  assert_successful_code
}

###
### _extract_payload_fields
###

function test_should_extract_prompt_and_session_id() {
  _extract_payload_fields '{"prompt":"hello world","session_id":"abc-123"}'
  assert_equals "hello world" "$PROMPT_RESULT"
  assert_equals "abc-123" "$SESSION_ID_RESULT"
}

function test_should_fallback_to_env_session_id() {
  CLAUDE_SESSION_ID="env-session-456"
  _extract_payload_fields '{"prompt":"hello"}'
  assert_equals "hello" "$PROMPT_RESULT"
  assert_equals "env-session-456" "$SESSION_ID_RESULT"
}

function test_should_clear_invalid_session_id_format() {
  _extract_payload_fields '{"prompt":"hello","session_id":"bad@id!"}'
  assert_equals "hello" "$PROMPT_RESULT"
  assert_equals "" "$SESSION_ID_RESULT"
}

function test_should_handle_empty_payload() {
  _extract_payload_fields '{}'
  assert_equals "" "$PROMPT_RESULT"
  assert_equals "" "$SESSION_ID_RESULT"
}

###
### _strip_agent_wrappers
###

function test_should_strip_json_code_fences() {
  local input=$'```json\n{"corrected":"hello"}\n```'
  local result
  result=$(_strip_agent_wrappers "$input")
  assert_not_contains '```' "$result"
  assert_contains 'hello' "$result"
}

function test_should_strip_carriage_returns() {
  local input=$'line1\r\nline2\r'
  local result
  result=$(_strip_agent_wrappers "$input")
  assert_not_matches $'\r' "$result"
}

function test_should_preserve_normal_text() {
  local input="just normal text here"
  local result
  result=$(_strip_agent_wrappers "$input")
  assert_contains "just normal text here" "$result"
}

###
### _accumulate_cost
###

function test_should_accumulate_from_valid_json() {
  declare -gA _ac_test1=()
  _ac_test1[COST_USD]="0"
  _ac_test1[INPUT_TOKENS]="0"
  _ac_test1[OUTPUT_TOKENS]="0"
  _ac_test1[CACHE_WRITE_TOKENS]="0"
  _ac_test1[CACHE_READ_TOKENS]="0"

  _accumulate_cost _ac_test1 '{"total_cost_usd":0.005,"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":20,"cache_read_input_tokens":30}}'

  assert_equals "0.005000" "${_ac_test1[COST_USD]}"
  assert_equals "100" "${_ac_test1[INPUT_TOKENS]}"
  assert_equals "50" "${_ac_test1[OUTPUT_TOKENS]}"
  assert_equals "20" "${_ac_test1[CACHE_WRITE_TOKENS]}"
  assert_equals "30" "${_ac_test1[CACHE_READ_TOKENS]}"
}

function test_should_not_change_state_on_empty_input() {
  declare -gA _ac_test2=()
  _ac_test2[COST_USD]="0.001000"
  _ac_test2[INPUT_TOKENS]="10"
  _ac_test2[OUTPUT_TOKENS]="5"
  _ac_test2[CACHE_WRITE_TOKENS]="0"
  _ac_test2[CACHE_READ_TOKENS]="0"

  _accumulate_cost _ac_test2 ""

  assert_equals "0.001000" "${_ac_test2[COST_USD]}"
  assert_equals "10" "${_ac_test2[INPUT_TOKENS]}"
}

function test_should_accumulate_additively_across_calls() {
  declare -gA _ac_test3=()
  _ac_test3[COST_USD]="0.005000"
  _ac_test3[INPUT_TOKENS]="100"
  _ac_test3[OUTPUT_TOKENS]="50"
  _ac_test3[CACHE_WRITE_TOKENS]="20"
  _ac_test3[CACHE_READ_TOKENS]="30"

  _accumulate_cost _ac_test3 '{"total_cost_usd":0.003,"usage":{"input_tokens":200,"output_tokens":100}}'

  assert_equals "0.008000" "${_ac_test3[COST_USD]}"
  assert_equals "300" "${_ac_test3[INPUT_TOKENS]}"
  assert_equals "150" "${_ac_test3[OUTPUT_TOKENS]}"
  assert_equals "20" "${_ac_test3[CACHE_WRITE_TOKENS]}"
  assert_equals "30" "${_ac_test3[CACHE_READ_TOKENS]}"
}

###
### enhance::format_response
###

function test_should_produce_valid_json_in_non_verbose_mode() {
  local result
  result=$(enhance::format_response "false" "original" "corrected" "working" "enhanced text" \
    "true" "false" "false" "0" "0" "0" "0" "0" "")
  echo "$result" | jq -e . >/dev/null
  assert_successful_code
}

function test_should_include_block_decision_and_enhanced_prompt() {
  local result
  result=$(enhance::format_response "false" "original" "corrected" "working" "enhanced text" \
    "true" "false" "false" "0" "0" "0" "0" "0" "")
  local decision enhanced
  decision=$(echo "$result" | jq -r '.decision')
  enhanced=$(echo "$result" | jq -r '.enhanced')
  assert_equals "block" "$decision"
  assert_equals "enhanced text" "$enhanced"
}

function test_should_include_debug_info_in_verbose_mode() {
  local result
  result=$(enhance::format_response "true" "original" "corrected" "working" "enhanced" \
    "true" "false" "false" "0.005000" "100" "50" "0" "0" "  → correction: done")
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  assert_contains "Debug" "$reason"
  assert_contains "correction" "$reason"
}

###
### enhance::should_skip
###

function test_should_skip_when_disabled() {
  local reason
  reason=$(enhance::should_skip "false" "hello" "session-1" "/tmp/nonexistent" "true" "false" "false")
  assert_equals "disabled" "$reason"
}

function test_should_skip_when_prompt_empty() {
  local reason
  reason=$(enhance::should_skip "true" "" "session-1" "/tmp/nonexistent" "true" "false" "false")
  assert_equals "empty_input" "$reason"
}

function test_should_skip_when_session_id_empty() {
  local reason
  reason=$(enhance::should_skip "true" "hello" "" "/tmp/nonexistent" "true" "false" "false")
  assert_equals "empty_input" "$reason"
}

function test_should_skip_when_directive() {
  local reason
  reason=$(enhance::should_skip "true" "/command" "session-1" "/tmp/nonexistent" "true" "false" "false")
  assert_equals "directive" "$reason"
}

function test_should_skip_when_all_stages_disabled() {
  local reason
  reason=$(enhance::should_skip "true" "hello" "session-1" "/tmp/nonexistent" "false" "false" "false")
  assert_equals "no_stages" "$reason"
}

function test_should_not_skip_normal_prompt_with_stages() {
  local reason
  reason=$(enhance::should_skip "true" "hello world" "session-1" "/tmp/nonexistent" "true" "false" "false")
  assert_equals "" "$reason"
}

###
### enhance::parse_correction_result
###

# Regression: a multi-line `corrected` caused `read` to truncate at the first
# newline, leaving CORRECTIONS_JSON empty and crashing write_audit's jq --argjson.
function test_should_preserve_multiline_corrected_text() {
  declare -gA _cs=()
  local corrected_original=$'well then here:\n  """\n  pasted block\n  """\n  can i say Agentic?'
  local inner_result
  inner_result=$(jq -nc --arg c "$corrected_original" \
    '{corrected:$c, language:"en", mistakes:[{type:"spelling",original:"thenn",correction:"then"}]}')

  enhance::parse_correction_result _cs "$inner_result"

  assert_equals "$corrected_original" "$CORRECTION_CORRECTED"
}

function test_should_keep_corrections_json_valid_with_multiline_corrected() {
  declare -gA _cs=()
  local inner_result
  inner_result=$(jq -nc --arg c $'one\ntwo' \
    '{corrected:$c, language:"en", mistakes:[{type:"spelling",original:"thenn",correction:"then"}]}')

  enhance::parse_correction_result _cs "$inner_result"

  assert_not_empty "${_cs[CORRECTIONS_JSON]}"
  jq -e . <<<"${_cs[CORRECTIONS_JSON]}" >/dev/null
  assert_successful_code "$?"
}

function test_should_extract_unique_mistake_types() {
  declare -gA _cs=()
  local inner_result='{"corrected":"fixed","language":"en","mistakes":[{"type":"spelling","original":"a","correction":"b"},{"type":"grammar","original":"c","correction":"d"},{"type":"spelling","original":"e","correction":"f"}]}'

  enhance::parse_correction_result _cs "$inner_result"

  assert_equals '["grammar","spelling"]' "${_cs[MISTAKE_NATURE_JSON]}"
  assert_equals "en" "${_cs[DETECTED_LANGUAGE]}"
}

function test_should_default_arrays_when_mistakes_absent() {
  declare -gA _cs=()
  local inner_result='{"corrected":"no errors","language":"fr"}'

  enhance::parse_correction_result _cs "$inner_result"

  assert_equals "[]" "${_cs[CORRECTIONS_JSON]}"
  assert_equals "[]" "${_cs[MISTAKE_NATURE_JSON]}"
  assert_equals "fr" "${_cs[DETECTED_LANGUAGE]}"
  assert_equals "no errors" "$CORRECTION_CORRECTED"
}

function test_should_reset_state_on_empty_input() {
  declare -gA _cs=()
  _cs[CORRECTIONS_JSON]='[{"stale":true}]'
  _cs[DETECTED_LANGUAGE]="de"

  enhance::parse_correction_result _cs ""

  assert_equals "[]" "${_cs[CORRECTIONS_JSON]}"
  assert_equals "[]" "${_cs[MISTAKE_NATURE_JSON]}"
  assert_equals "en" "${_cs[DETECTED_LANGUAGE]}"
  assert_empty "$CORRECTION_CORRECTED"
}

function test_should_not_crash_on_malformed_json() {
  declare -gA _cs=()
  enhance::parse_correction_result _cs "this is not json at all"

  assert_equals "[]" "${_cs[CORRECTIONS_JSON]}"
  assert_equals "[]" "${_cs[MISTAKE_NATURE_JSON]}"
}

###
### enhance::read_context_state
###

function test_should_preserve_multiline_summary_on_round_trip() {
  local ctx
  ctx=$(bashunit::temp_file)
  local summary=$'First sentence.\nSecond sentence.\nThird sentence.'
  enhance::write_context_state "$ctx" "$summary" "3" "uuid-abc"

  CONTEXT_SUMMARY="stale"
  CONTEXT_COUNT="99"
  CONTEXT_LAST_UUID="stale"

  enhance::read_context_state "$ctx"

  assert_equals "$summary" "$CONTEXT_SUMMARY"
  assert_equals "3" "$CONTEXT_COUNT"
  assert_equals "uuid-abc" "$CONTEXT_LAST_UUID"
  rm -f "$ctx"
}

function test_should_reset_when_context_file_missing() {
  enhance::read_context_state "/nonexistent/context-file"

  assert_empty "$CONTEXT_SUMMARY"
  assert_equals "0" "$CONTEXT_COUNT"
  assert_empty "$CONTEXT_LAST_UUID"
}
