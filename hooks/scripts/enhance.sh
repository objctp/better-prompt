#!/usr/bin/env bash
# shellcheck disable=SC2153
#
# Enhance user prompts via correction, translation, and enhancement stages
# Usage: enhance.sh < stdin-payload
#
set -euo pipefail

# Prevent recursive hook invocation: sub-agents (correction, translation,
# enhancement) are spawned via `claude -p` which re-triggers UserPromptSubmit.
# When this env var is set, pass through immediately.
if [[ "${BETTER_PROMPT_CHILD:-}" == "1" ]]; then
  printf '{"continue": true}\n'
  exit 0
fi
export BETTER_PROMPT_CHILD=1

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
CONFIG="${BETTER_PROMPT_CONFIG:-$HOME/.claude/better-prompt.local.md}"
# shellcheck disable=SC2034
readonly PLUGIN_ROOT CONFIG

# shellcheck source=lib/common.sh
source "${PLUGIN_ROOT}/hooks/scripts/lib/common.sh"

_detect_os

###
### :::: Private Functions :::: ########
###

# Extract the last N prior prompts from the context file as a numbered list.
# Prints nothing when file is missing or count is 0.
enhance::extract_prior_context() {
  local context_file="$1"
  local count="$2"

  if [[ ! -f "$context_file" ]] || [[ "$count" -eq 0 ]]; then
    return 0
  fi

  tail -n "$count" "$context_file" |
    awk 'NF {printf "%d. \"%s\"\n", ++n, $0}' 2>/dev/null
  return 0
}

# Append a final prompt to the context file and trim to the last N lines.
enhance::append_prior_context() {
  local context_file="$1"
  local count="$2"
  local enhanced_text="$3"

  [[ -z "$enhanced_text" ]] && return 0

  mkdir -p "$(dirname "$context_file")"
  printf '%s\n' "$enhanced_text" >>"$context_file"

  # Trim to last N lines (sliding window)
  local trimmed
  trimmed=$(tail -n "$count" "$context_file") && printf '%s\n' "$trimmed" >"$context_file"
  return 0
}

# Accumulate cost and usage from a --output-format json response into the
# pipeline state nameref.  Arguments:
#   $1 - nameref (associative array with COST_USD, INPUT_TOKENS, OUTPUT_TOKENS)
#   $2 - raw JSON output from claude -p --output-format json
_accumulate_cost() {
  local -n _ac_st="$1"
  local raw_json="$2"

  if [[ -z "$raw_json" ]]; then
    return 0
  fi

  # Single jq pass: extract cost and token counts, delimited by tab.
  local parsed
  parsed=$(jq -r '[.total_cost_usd // 0, (.usage.input_tokens // 0), (.usage.output_tokens // 0)] | @tsv' \
    <<<"$raw_json" 2>/dev/null) || parsed=$'0\t0\t0'

  local stage_cost stage_input stage_output
  IFS=$'\t' read -r stage_cost stage_input stage_output <<<"$parsed"

  # Sanitise: ensure all values are numeric before arithmetic / awk interpolation
  [[ "$stage_cost" =~ ^[0-9]*\.?[0-9]+$ ]] || stage_cost="0"
  [[ "$stage_input" =~ ^[0-9]+$ ]] || stage_input="0"
  [[ "$stage_output" =~ ^[0-9]+$ ]] || stage_output="0"

  # Use awk for float addition (avoids bc dependency)
  _ac_st[COST_USD]=$(awk "BEGIN {printf \"%.6f\", (${_ac_st[COST_USD]:-0}) + $stage_cost}")
  _ac_st[INPUT_TOKENS]="$((${_ac_st[INPUT_TOKENS]:-0} + stage_input))"
  _ac_st[OUTPUT_TOKENS]="$((${_ac_st[OUTPUT_TOKENS]:-0} + stage_output))"
  return 0
}

###
### :::: Public Functions :::: #########
###

# Extract prompt and session_id from the payload in a single jq pass.
# Sets PROMPT_RESULT and SESSION_ID_RESULT globals (avoids two subshell+jq invocations).
_extract_payload_fields() {
  local payload="$1"
  local parsed
  parsed=$(jq -r '[.prompt // "", .session_id // ""] | @tsv' <<<"$payload" 2>/dev/null) || parsed=$'\t'

  IFS=$'\t' read -r PROMPT_RESULT SESSION_ID_RESULT <<<"$parsed"

  # Fall back to env var if session_id missing from payload
  if [[ -z "$SESSION_ID_RESULT" ]] && [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    SESSION_ID_RESULT="$CLAUDE_SESSION_ID"
  fi

  if [[ -z "$SESSION_ID_RESULT" ]]; then
    _warn "No session ID found in payload or CLAUDE_SESSION_ID env — skipping prompt enhancement"
  fi

  if [[ -n "$SESSION_ID_RESULT" ]] && ! [[ "$SESSION_ID_RESULT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    _warn "Invalid session ID format: $SESSION_ID_RESULT"
    SESSION_ID_RESULT=""
  fi
  return 0
}

enhance::resolve_session_id() {
  local payload="$1"
  local session_id=""

  if [[ -n "$payload" ]]; then
    session_id=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null) || session_id=""
  fi

  if [[ -z "$session_id" ]] && [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    session_id="$CLAUDE_SESSION_ID"
  fi

  if [[ -z "$session_id" ]]; then
    _warn "No session ID found in payload or CLAUDE_SESSION_ID env — skipping prompt enhancement"
  fi

  if [[ -n "$session_id" ]]; then
    if ! [[ "$session_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      _warn "Invalid session ID format: $session_id"
      session_id=""
    fi
  fi

  printf '%s' "$session_id"
  return 0
}

enhance::is_directive() {
  if [[ "$1" =~ ^[/!] ]]; then
    return 0
  fi
  return 1
}

# Guard against re-fired prompts within 60s by comparing MD5 hashes.
# Arguments:
#   $1 - sentinel_path: file holding the previous prompt hash
#   $2 - original_prompt: the incoming prompt text
# Returns:
#   0 - sentinel matched (prompt should pass through unchanged)
#   1 - no match or stale sentinel (prompt should proceed)
enhance::check_sentinel() {
  local sentinel_path="$1"
  local original_prompt="$2"

  if [[ ! -f "$sentinel_path" ]]; then
    return 1
  fi

  local sentinel_age
  sentinel_age=$(($(date +%s) - $(stat -f '%m' "$sentinel_path" 2>/dev/null ||
    stat -c '%Y' "$sentinel_path" 2>/dev/null || echo 0)))
  if [[ "$sentinel_age" -lt 60 ]]; then
    local stored_hash incoming_hash
    stored_hash=$(cat "$sentinel_path" 2>/dev/null || echo "")
    incoming_hash=$(_md5 "$original_prompt")
    if [[ -n "$stored_hash" ]] && [[ "$incoming_hash" == "$stored_hash" ]]; then
      _debug "Sentinel matched (${sentinel_age}s old, hash=${incoming_hash}) — passing re-fired prompt through"
      rm -f "$sentinel_path"
      return 0
    else
      _debug "Sentinel present but hash mismatch — new prompt, proceeding (stored=${stored_hash:-empty}, incoming=${incoming_hash})"
    fi
  else
    _debug "Stale sentinel (${sentinel_age}s old) — removing"
    rm -f "$sentinel_path"
  fi

  return 1
}

# State keys used across pipeline functions:
#   WORKING_PROMPT, CORRECTED_PROMPT, ENHANCED_PROMPT,
#   CORRECTIONS_JSON, MISTAKE_NATURE_JSON, DETECTED_LANGUAGE

# Strip markdown code fences and carriage returns from agent output.
# Only intended for the correction agent which returns JSON — LLMs sometimes
# wrap structured output in ```json ... ``` fences that break jq parsing.
# NOT applied to translation/enhancement output, which is plain text that
# may legitimately contain ``` in the user's prompt content.
_strip_agent_wrappers() {
  local input="$1"
  # Use sed for line-precise matching — only strips ``` on standalone lines,
  # not inline occurrences that belong to the user's content.
  sed -e 's/^```[a-zA-Z]*$//' -e 's/^```$//' -e '/^[[:space:]]*$/d' <<<"$input" | tr -d '\r'
  return 0
}

enhance::run_correction() {
  local -n _cr_st="$1"
  local working_prompt="${_cr_st[WORKING_PROMPT]}"
  local correction_model="$2"

  _debug "Running correction with model: $correction_model"

  local correction_result=""
  correction_result=$(printf '%s' "$working_prompt" | BETTER_PROMPT_CHILD=1 claude -p --output-format json --agent better-prompt:prompt-correction --model "$correction_model" 2>&1) || {
    _warn "Correction stage failed: $correction_result"
    correction_result=""
  }

  _accumulate_cost _cr_st "$correction_result"

  local corrected=""
  _cr_st[CORRECTIONS_JSON]="[]"
  _cr_st[MISTAKE_NATURE_JSON]="[]"

  if [[ -n "$correction_result" ]]; then
    # Extract inner result from --output-format json wrapper, then strip fences.
    local inner_result
    inner_result=$(jq -r '.result // empty' <<<"$correction_result" 2>/dev/null) || inner_result=""
    [[ -z "$inner_result" ]] && inner_result="$correction_result"
    inner_result=$(_strip_agent_wrappers "$inner_result")

    # Single jq pass extracts all four fields using unit separator (ASCII 31)
    # as delimiter — safe for natural language text that never contains \x1f.
    local parsed
    parsed=$(jq -r --arg sep $'\x1f' '
      [.corrected // "", .language // "en",
       (.mistakes // [] | tostring // "[]"),
       ([.mistakes[]?.type] | unique | tostring // "[]")
      ] | join($sep)
    ' <<<"$inner_result" 2>/dev/null) || parsed=""

    if [[ -n "$parsed" ]]; then
      IFS=$'\x1f' read -r corrected _cr_lang _cr_mistakes _cr_types <<<"$parsed"
      _cr_st[DETECTED_LANGUAGE]="$_cr_lang"
      _cr_st[CORRECTIONS_JSON]="$_cr_mistakes"
      _cr_st[MISTAKE_NATURE_JSON]="$_cr_types"
    fi
  fi

  [[ -n "$corrected" ]] && _cr_st[WORKING_PROMPT]="$corrected"
  _cr_st[CORRECTED_PROMPT]="${_cr_st[WORKING_PROMPT]}"
  return 0
}

enhance::run_translation() {
  local -n _tr_st="$1"
  local working_prompt="${_tr_st[WORKING_PROMPT]}"
  local translation_model="$2"

  _debug "Running translation with model: $translation_model"

  local translation_result=""
  translation_result=$(printf '%s' "$working_prompt" | BETTER_PROMPT_CHILD=1 claude -p --output-format json --agent better-prompt:prompt-translation --model "$translation_model" 2>&1) || {
    _warn "Translation stage failed: $translation_result"
    translation_result=""
  }

  _accumulate_cost _tr_st "$translation_result"

  if [[ -n "$translation_result" ]]; then
    local translated_text
    translated_text=$(jq -r '.result // empty' <<<"$translation_result" 2>/dev/null) || translated_text=""
    # Fallback: if .result is empty, use raw output
    if [[ -z "$translated_text" ]]; then
      translated_text="$translation_result"
    fi
    [[ -n "$translated_text" ]] && _tr_st[WORKING_PROMPT]="$translated_text"
  fi
  return 0
}

enhance::run_enhancement_stage() {
  local -n _en_st="$1"
  local working_prompt="$2"
  local enhancement_model="$3"
  local context_file="$4"
  local context_count="$5"

  _debug "Running enhancement with model: $enhancement_model"

  local prior_context=""
  prior_context=$(enhance::extract_prior_context "$context_file" "$context_count")

  local enhance_input=""

  if [[ -n "$prior_context" ]]; then
    enhance_input+="Prior prompts in this session:
$prior_context

"
  fi

  enhance_input+="$working_prompt"

  local enhance_json=""
  enhance_json=$(printf '%s' "$enhance_input" | BETTER_PROMPT_CHILD=1 claude -p --output-format json --agent better-prompt:prompt-enhancement --model "$enhancement_model" 2>&1) || {
    _warn "Enhancement stage failed: $enhance_json"
    enhance_json=""
  }

  _accumulate_cost _en_st "$enhance_json"

  local enhanced_result=""
  if [[ -n "$enhance_json" ]]; then
    enhanced_result=$(jq -r '.result // empty' <<<"$enhance_json" 2>/dev/null) || enhanced_result=""
  else
    enhanced_result="$enhance_json"
  fi

  [[ -z "$enhanced_result" ]] && enhanced_result="$working_prompt"
  printf '%s' "$enhanced_result"
  return 0
}

# Arguments:
#   $1  - audit_log: path to the JSONL audit file
#   $2  - original_prompt: unmodified user prompt
#   $3  - corrected_prompt: post-correction text
#   $4  - enhanced_prompt: final prompt after all stages
#   $5  - mistake_nature_json: JSON array of mistake type strings
#   $6  - corrections_json: JSON array of mistake objects
#   $7  - correction: "true"/"false" whether correction ran
#   $8  - correction_model: model used for correction
#   $9  - enhancement: "true"/"false" whether enhancement ran
#   $10 - enhancement_model: model used for enhancement
#   $11 - translation: "true"/"false" whether translation ran
#   $12 - translation_model: model used for translation
enhance::write_audit() {
  local audit_log="$1"
  local original_prompt="$2"
  local corrected_prompt="$3"
  local enhanced_prompt="$4"
  local mistake_nature_json="$5"
  local corrections_json="$6"
  local detected_language="$7"
  local correction="$8"
  local correction_model="$9"
  local enhancement="${10}"
  local enhancement_model="${11}"
  local translation="${12}"
  local translation_model="${13}"

  if [[ "$correction" == "true" ]]; then
    local audit_correction_model="\"$correction_model\""
  else
    local audit_correction_model="null"
  fi
  if [[ "$enhancement" == "true" ]]; then
    local audit_enhancement_model="\"$enhancement_model\""
  else
    local audit_enhancement_model="null"
  fi
  if [[ "$translation" == "true" ]]; then
    local audit_translation_model="\"$translation_model\""
  else
    local audit_translation_model="null"
  fi

  mkdir -p "$(dirname "$audit_log")"

  local audit_language
  if [[ -n "$detected_language" ]]; then
    audit_language="\"$detected_language\""
  else
    audit_language="null"
  fi

  local audit_date
  audit_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # shellcheck disable=SC2016
  local -r audit_filter='{"date":$date,"prompt":$prompt,"language":$language,"corrected":$corrected,"enhanced":$enhanced,"mistake-nature":$nature,"mistakes":$mistakes,"models":{"correction":$correction_model,"translation":$translation_model,"enhancement":$enhancement_model}}'

  jq -nc --arg date "$audit_date" --arg prompt "$original_prompt" --argjson language "$audit_language" --arg corrected "$corrected_prompt" --arg enhanced "$enhanced_prompt" --argjson nature "$mistake_nature_json" --argjson mistakes "$corrections_json" --argjson correction_model "$audit_correction_model" --argjson enhancement_model "$audit_enhancement_model" --argjson translation_model "$audit_translation_model" "$audit_filter" >>"$audit_log"
  return 0
}

enhance::write_sentinel() {
  local sentinel_path="$1"
  local final_prompt="$2"
  local final_hash
  final_hash=$(_md5 "$final_prompt")
  if [[ -n "$final_hash" ]]; then
    _atomic_write "$sentinel_path" "$final_hash"
    _debug "Sentinel written: $sentinel_path (hash=$final_hash)"
  else
    _warn "Could not compute prompt hash — sentinel not written; rewind loop guard inactive"
  fi
}

enhance::copy_to_clipboard() {
  local text="$1"
  if [[ "$IS_MACOS" == true ]]; then
    printf '%s' "$text" | pbcopy 2>/dev/null || true
  else
    if command -v xclip &>/dev/null; then
      printf '%s' "$text" | xclip -selection clipboard 2>/dev/null || true
    elif command -v xsel &>/dev/null; then
      printf '%s' "$text" | xsel --clipboard --input 2>/dev/null || true
    else
      _warn "No clipboard utility found. Install xclip or xsel."
    fi
  fi
  return 0
}

# Arguments:
#   $1 - verbose: "true"/"false"
#   $2 - original_prompt: unmodified user prompt
#   $3 - corrected_prompt: post-correction text
#   $4 - working_prompt: current state (may include translation)
#   $5 - enhanced_prompt: final prompt after all stages
#   $6 - correction: "true"/"false"
#   $7 - translation: "true"/"false"
#   $8 - enhancement: "true"/"false"
#   $9 - cost_usd: accumulated cost string (e.g. "0.003210")
#   $10 - input_tokens: accumulated input tokens
#   $11 - output_tokens: accumulated output tokens
enhance::format_response() {
  local verbose="$1"
  local original_prompt="$2"
  local corrected_prompt="$3"
  local working_prompt="$4"
  local enhanced_prompt="$5"
  local correction="$6"
  local translation="$7"
  local enhancement="$8"
  local cost_usd="${9:-0}"
  local input_tokens="${10:-0}"
  local output_tokens="${11:-0}"

  # Always include the full enhanced prompt so the user can verify what was
  # sent, even when rewind fails (clipboard clobbered, permission denied, etc.).
  local escaped_enhanced
  escaped_enhanced=$(_json_escape "$enhanced_prompt")

  # Truncated previews for the reason field (UI display only).
  local preview_original preview_enhanced
  preview_original=$(_truncate_for_display "$original_prompt")
  preview_enhanced=$(_truncate_for_display "$enhanced_prompt")

  if [[ "$verbose" == "true" ]]; then
    local debug_msg="[Better Prompt Debug]\nOriginal:   $preview_original"
    if [[ "$correction" == "true" ]]; then
      local preview_corrected
      preview_corrected=$(_truncate_for_display "$corrected_prompt")
      debug_msg+="\nCorrected:  $preview_corrected"
    fi
    if [[ "$translation" == "true" ]]; then
      debug_msg+="\nLanguage:   ${DETECTED_LANGUAGE:-en}"
      if [[ "${DETECTED_LANGUAGE:-en}" != "en" ]]; then
        local preview_working
        preview_working=$(_truncate_for_display "$working_prompt")
        debug_msg+="\nTranslated: $preview_working"
      fi
    fi
    [[ "$enhancement" == "true" ]] && debug_msg+="\nEnhanced:   $preview_enhanced"
    if [[ -n "$cost_usd" ]] && [[ "$cost_usd" != "0" ]] && [[ "$cost_usd" != "0.000000" ]]; then
      debug_msg+="\nCost:       \$$(printf '%.6f' "$cost_usd")"
      debug_msg+="\nTokens:     ${input_tokens} in / ${output_tokens} out"
    fi
    debug_msg=$(printf '%b' "$debug_msg")
    local escaped_debug
    escaped_debug=$(_json_escape "$debug_msg")
    printf '{"decision": "block", "reason": %s, "enhanced": %s, "suppressOutput": false}\n' "$escaped_debug" "$escaped_enhanced"
  else
    local summary="Prompt enhanced by better-prompt.\nOriginal: ${preview_original}\nEnhanced: ${preview_enhanced}"
    local escaped_summary
    escaped_summary=$(_json_escape "$(printf '%b' "$summary")")
    printf '{"decision": "block", "reason": %s, "enhanced": %s, "suppressOutput": false}\n' "$escaped_summary" "$escaped_enhanced"
  fi
  return 0
}

enhance::spawn_stop_hook() {
  local session_id="$1"
  local stop_log="${TMPDIR:-/tmp}/better-prompt-stop.log"
  local stop_pid_file="${RUNTIME_DIR}/.stop-pid"
  CLAUDE_SESSION_ID="$session_id" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    nohup bash "${PLUGIN_ROOT}/hooks/scripts/stop-hook.sh" \
    </dev/null >>"$stop_log" 2>&1 &
  local stop_pid=$!
  disown
  _atomic_write "$stop_pid_file" "$stop_pid"
  _debug "stop-hook.sh spawned (pid $stop_pid), log: $stop_log"
  return 0
}

enhance::load_settings() {
  VERBOSE=$(_get_setting "verbose" "false")
  ENABLED=$(_get_setting "enabled" "true")
  CORRECTION=$(_get_setting "correction" "true")
  CORRECTION_MODEL=$(_get_setting "correction_model" "haiku")
  ENHANCEMENT=$(_get_setting "enhancement" "false")
  ENHANCEMENT_MODEL=$(_get_setting "enhancement_model" "sonnet")
  TRANSLATION=$(_get_setting "translation" "false")
  TRANSLATION_MODEL=$(_get_setting "translation_model" "haiku")
  AUDIT=$(_get_setting "audit" "true")
  RUNTIME_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/better-prompt"
  AUDIT_LOG="${RUNTIME_DIR}/audit.json"
  SENTINEL="${RUNTIME_DIR}/.sentinel"
  CONTEXT_FILE="${RUNTIME_DIR}/.context"
  mkdir -p "$RUNTIME_DIR"

  # Validate model names look reasonable (non-empty, valid characters only).
  # We do not restrict to a hardcoded set — any valid model identifier is accepted.
  local _model_re='^[a-zA-Z0-9._:-]+$'
  local _model
  for _model in "$CORRECTION_MODEL" "$ENHANCEMENT_MODEL" "$TRANSLATION_MODEL"; do
    if [[ -n "$_model" ]] && ! [[ "$_model" =~ $_model_re ]]; then
      _warn "Model name '$_model' contains unexpected characters — expected alphanumeric, dot, dash, colon, or underscore"
    fi
  done
  return 0
}

enhance::should_skip() {
  local enabled="$1"
  local prompt="$2"
  local session_id="$3"
  local sentinel_path="$4"
  local correction="$5"
  local translation="$6"
  local enhancement="$7"

  if [[ "$enabled" == "false" ]]; then
    printf 'disabled'
    return 0
  fi

  if [[ -z "$prompt" ]] || [[ -z "$session_id" ]]; then
    printf 'empty_input'
    return 0
  fi

  if enhance::is_directive "$prompt"; then
    printf 'directive'
    return 0
  fi

  if enhance::check_sentinel "$sentinel_path" "$prompt"; then
    printf 'sentinel'
    return 0
  fi

  # No stages active — nothing to enhance, pass through without blocking.
  if [[ "$correction" != "true" ]] && [[ "$translation" != "true" ]] && [[ "$enhancement" != "true" ]]; then
    _debug "All stages disabled — passing through"
    printf 'no_stages'
    return 0
  fi

  printf ''
}

enhance::run_pipeline() {
  local -n _pl_st="$1"
  local correction="$2"
  local correction_model="$3"
  local translation="$4"
  local translation_model="$5"
  local enhancement="$6"
  local enhancement_model="$7"

  _pl_st[CORRECTIONS_JSON]="[]"
  _pl_st[MISTAKE_NATURE_JSON]="[]"
  _pl_st[COST_USD]="0"
  _pl_st[INPUT_TOKENS]="0"
  _pl_st[OUTPUT_TOKENS]="0"

  # When enhancement is enabled without translation, correction is redundant —
  # enhancement subsumes grammar/spelling fixes and no language detection is needed.
  local skip_correction="false"
  if [[ "$enhancement" == "true" ]] && [[ "$translation" != "true" ]] && [[ "$correction" == "true" ]]; then
    skip_correction="true"
    _debug "Enhancement enabled without translation — skipping correction (enhancement subsumes it)"
  fi

  # When translation is enabled without correction, still run the correction
  # agent to detect language — then discard corrections so the user's original
  # wording is preserved.  This avoids an extra claude -p invocation.
  local correction_only_for_language="false"
  if [[ "$translation" == "true" ]] && [[ "$correction" != "true" ]] && [[ -z "${_pl_st[DETECTED_LANGUAGE]:-}" ]]; then
    correction_only_for_language="true"
    _debug "Translation enabled without correction — running correction agent for language detection only"
  fi

  if [[ "$skip_correction" != "true" ]] && { [[ "$correction" == "true" ]] || [[ "$correction_only_for_language" == "true" ]]; }; then
    local pre_prompt="${_pl_st[WORKING_PROMPT]}"
    enhance::run_correction "$1" "$correction_model"

    if [[ "$correction_only_for_language" == "true" ]]; then
      # Discard corrections — restore original wording, keep only language
      _pl_st[WORKING_PROMPT]="$pre_prompt"
      _pl_st[CORRECTIONS_JSON]="[]"
      _pl_st[MISTAKE_NATURE_JSON]="[]"
      _debug "Language-only correction done (detected: ${_pl_st[DETECTED_LANGUAGE]}), corrections discarded"
    fi
  fi
  _pl_st[CORRECTED_PROMPT]="${_pl_st[WORKING_PROMPT]}"

  if [[ "$translation" == "true" ]]; then
    if [[ -n "${_pl_st[DETECTED_LANGUAGE]:-}" && "${_pl_st[DETECTED_LANGUAGE]}" == "en" ]]; then
      _debug "Prompt is English — skipping translation"
    else
      enhance::run_translation "$1" "$translation_model"
    fi
  fi

  _pl_st[ENHANCED_PROMPT]="${_pl_st[WORKING_PROMPT]}"
  if [[ "$enhancement" == "true" ]]; then
    _pl_st[ENHANCED_PROMPT]=$(enhance::run_enhancement_stage "$1" "${_pl_st[WORKING_PROMPT]}" "$enhancement_model" "$CONTEXT_FILE" 5)
  fi
  return 0
}

enhance::finalize() {
  local -n _fn_st="$1"
  local original_prompt="$2"
  local session_id="$3"

  local final_prompt="${_fn_st[ENHANCED_PROMPT]:-${_fn_st[WORKING_PROMPT]}}"

  enhance::append_prior_context "$CONTEXT_FILE" 5 "$final_prompt"

  if [[ "$AUDIT" == "true" ]] && command -v jq &>/dev/null; then
    enhance::write_audit "$AUDIT_LOG" "$original_prompt" "${_fn_st[CORRECTED_PROMPT]}" "$final_prompt" \
      "${_fn_st[MISTAKE_NATURE_JSON]}" "${_fn_st[CORRECTIONS_JSON]}" "${_fn_st[DETECTED_LANGUAGE]:-}" \
      "$CORRECTION" "$CORRECTION_MODEL" "$ENHANCEMENT" "$ENHANCEMENT_MODEL" "$TRANSLATION" "$TRANSLATION_MODEL"
  fi

  enhance::write_sentinel "$SENTINEL" "$final_prompt"
  enhance::format_response "$VERBOSE" "$original_prompt" "${_fn_st[CORRECTED_PROMPT]}" "${_fn_st[WORKING_PROMPT]}" "$final_prompt" \
    "$CORRECTION" "$TRANSLATION" "$ENHANCEMENT" \
    "${_fn_st[COST_USD]:-0}" "${_fn_st[INPUT_TOKENS]:-0}" "${_fn_st[OUTPUT_TOKENS]:-0}"
  enhance::copy_to_clipboard "$final_prompt"
  _debug "Original prompt blocked; final prompt copied to clipboard for rewind"
  enhance::spawn_stop_hook "$session_id"
}

###
### :::: Main :::: #####################
###

###
### :::: Fast-Fail Gate :::: ############
###

# Bash-only early exit for the common case where the hook should pass through.
# Avoids jq and full config parse — uses parameter expansion and line scanning.
# Returns 0 (continue) when a fast-fail condition is met, 1 when the full
# pipeline should run.  Sets _FF_PAYLOAD with the raw stdin content.
_fast_fail_gate() {
  local payload=""
  if [[ ! -t 0 ]]; then
    read -r -d '' payload
  fi
  _FF_PAYLOAD="$payload"

  # No payload — outside a hook context
  [[ -z "$payload" ]] && return 0

  # Quick enabled check — scan config frontmatter with bash builtins only.
  local enabled="true"
  if [[ -f "$CONFIG" ]]; then
    local line in_front=0
    while IFS= read -r line; do
      if [[ "$line" == "---" ]]; then
        ((++in_front))
        continue
      fi
      [[ "$in_front" -eq 1 ]] || continue
      if [[ "$line" == "enabled:"* ]]; then
        enabled="${line#enabled:}"
        enabled="${enabled%%#*}"
        enabled="${enabled#"${enabled%%[![:space:]]*}"}"
        enabled="${enabled%"${enabled##*[![:space:]]}"}"
        break
      fi
    done <"$CONFIG"
  fi

  # Plugin disabled — pass through without jq, without full config parse
  if [[ "$enabled" == "false" ]]; then
    return 0
  fi

  # Peek at prompt value — is it empty or a directive (/ or !)?
  # We only need the first character; no full JSON decode required.
  local after="${payload#*\"prompt\":\"}"
  if [[ "$after" == "$payload" ]]; then
    # No prompt field — likely a command_args payload, not for this hook
    return 0
  fi
  local first_char="${after:0:1}"
  if [[ -z "$first_char" ]]; then
    # Empty prompt
    return 0
  fi
  if [[ "$first_char" == "/" || "$first_char" == "!" ]]; then
    # Directive — pass through
    return 0
  fi

  # All fast-fail checks passed — the full pipeline is needed
  return 1
}

###
### :::: Main :::: #####################
###

main() {
  # Fast-fail gate: bash-only checks avoid jq and config parse on common paths.
  # On disabled/directive/empty prompts (~90% of invocations), this exits in ~15ms
  # instead of ~49ms by skipping jq process spawn and full YAML parsing.
  if _fast_fail_gate; then
    printf '{"continue": true}\n'
    exit 0
  fi

  if ! command -v jq &>/dev/null; then
    printf '{"continue": true}\n'
    _warn "jq is required but not found on PATH. Install jq to enable prompt enhancement."
    exit 0
  fi

  local STDIN_PAYLOAD="$_FF_PAYLOAD"

  # Single jq pass extracts both prompt and session_id (was two separate jq calls).
  # shellcheck disable=SC2034
  _extract_payload_fields "$STDIN_PAYLOAD"
  local ORIGINAL_PROMPT="$PROMPT_RESULT"
  local SESSION_ID="$SESSION_ID_RESULT"

  # shellcheck disable=SC2034
  declare -A _CFG=()
  _parse_config _CFG
  enhance::load_settings

  local SKIP_REASON
  SKIP_REASON=$(enhance::should_skip "$ENABLED" "$ORIGINAL_PROMPT" "$SESSION_ID" "$SENTINEL" "$CORRECTION" "$TRANSLATION" "$ENHANCEMENT")
  if [[ -n "$SKIP_REASON" ]]; then
    printf '{"continue": true}\n'
    exit 0
  fi

  declare -A pipeline_state=()
  pipeline_state[WORKING_PROMPT]="$ORIGINAL_PROMPT"
  pipeline_state[CORRECTED_PROMPT]="$ORIGINAL_PROMPT"
  pipeline_state[ENHANCED_PROMPT]=""
  pipeline_state[CORRECTIONS_JSON]="[]"
  pipeline_state[MISTAKE_NATURE_JSON]="[]"
  # shellcheck disable=SC2034
  pipeline_state[DETECTED_LANGUAGE]=""

  enhance::run_pipeline pipeline_state \
    "$CORRECTION" "$CORRECTION_MODEL" \
    "$TRANSLATION" "$TRANSLATION_MODEL" \
    "$ENHANCEMENT" "$ENHANCEMENT_MODEL"

  enhance::finalize pipeline_state "$ORIGINAL_PROMPT" "$SESSION_ID"

  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap 'printf "[better-prompt] Error at %s:%d (%s)\n" "${BASH_SOURCE[0]##*/}" "$LINENO" "${FUNCNAME[0]:-main}" >&2; exit 1' ERR
  main "$@"
fi
