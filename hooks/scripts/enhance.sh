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

# shellcheck source=lib/config.sh
source "${PLUGIN_ROOT}/hooks/scripts/lib/config.sh"

if [[ -z "${IS_MACOS:-}" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    IS_MACOS=true
  else
    IS_MACOS=false
  fi
fi

###
### :::: Private Functions :::: ########
###

_warn() {
  printf '[better-prompt] WARNING: %s\n' "$*" >&2
  return 0
}

_debug() {
  if [[ "${VERBOSE:-false}" == "true" ]]; then
    printf '[better-prompt] DEBUG: %s\n' "$*" >&2
  fi
  return 0
}

_json_escape() {
  local input="$1"
  if command -v jq &>/dev/null; then
    printf '%s' "$input" | jq -Rs .
  else
    printf '%s' "$input" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/'
  fi
  return 0
}

# temp + rename prevents partial reads from concurrent processes
_atomic_write() {
  local target="$1" content="$2"
  local tmp
  tmp=$(mktemp "${target}.XXXXXX") || return 1
  printf '%s' "$content" >"$tmp" && mv -f "$tmp" "$target"
  return 0
}

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

# macOS md5 prints only the digest; GNU md5sum appends the filename
_md5() {
  printf '%s' "$1" | (md5 2>/dev/null || md5sum 2>/dev/null | cut -c1-32)
  return 0
}

# Accumulate cost and usage from a --output-format json response into the
# pipeline state nameref.  Arguments:
#   $1 - nameref (associative array with COST_USD, INPUT_TOKENS, OUTPUT_TOKENS)
#   $2 - raw JSON output from claude -p --output-format json
_accumulate_cost() {
  local -n _ac_st="$1"
  local raw_json="$2"

  if [[ -z "$raw_json" ]] || ! command -v jq &>/dev/null; then
    return 0
  fi

  local stage_cost stage_input stage_output
  stage_cost=$(printf '%s' "$raw_json" | jq -r '.total_cost_usd // 0' 2>/dev/null) || stage_cost="0"
  stage_input=$(printf '%s' "$raw_json" | jq -r '.usage.input_tokens // 0' 2>/dev/null) || stage_input="0"
  stage_output=$(printf '%s' "$raw_json" | jq -r '.usage.output_tokens // 0' 2>/dev/null) || stage_output="0"

  # Use awk for float addition (avoids bc dependency)
  _ac_st[COST_USD]=$(awk "BEGIN {printf \"%.6f\", (${_ac_st[COST_USD]:-0}) + $stage_cost}")
  _ac_st[INPUT_TOKENS]="$((${_ac_st[INPUT_TOKENS]:-0} + stage_input))"
  _ac_st[OUTPUT_TOKENS]="$((${_ac_st[OUTPUT_TOKENS]:-0} + stage_output))"
  return 0
}

_read_stdin_payload() {
  # Must run before any subshell consumes stdin
  # Payload format: { "prompt": "...", "session_id": "...", ... }
  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat)
  fi
  printf '%s' "$payload"
  return 0
}

###
### :::: Public Functions :::: #########
###

enhance::extract_prompt() {
  local payload="$1"
  printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null || true
  return 0
}

enhance::resolve_session_id() {
  local payload="$1"
  local session_id=""

  if [[ -n "$payload" ]] && command -v jq &>/dev/null; then
    session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || session_id=""
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

enhance::run_correction() {
  local -n _cr_st="$1"
  local working_prompt="${_cr_st[WORKING_PROMPT]}"
  local correction_model="$2"

  _debug "Running correction with model: $correction_model"

  local correction_prompt="Correct the following prompt in terms of grammar and make it clear in context. Return ONLY the raw JSON object — no markdown, no code blocks.

Prompt: $working_prompt"

  local correction_result=""
  correction_result=$(printf '%s' "$correction_prompt" | BETTER_PROMPT_CHILD=1 claude -p --output-format json --agent better-prompt:prompt-correction --model "$correction_model" 2>&1) || {
    _warn "Correction stage failed: $correction_result"
    correction_result=""
  }

  _accumulate_cost _cr_st "$correction_result"

  local corrected=""
  _cr_st[CORRECTIONS_JSON]="[]"
  _cr_st[MISTAKE_NATURE_JSON]="[]"

  if [[ -n "$correction_result" ]] && command -v jq &>/dev/null; then
    # Extract inner result from --output-format json wrapper
    local inner_result
    inner_result=$(printf '%s' "$correction_result" | jq -r '.result // empty' 2>/dev/null) || inner_result=""
    # Strip markdown fences and blank lines from the agent's raw output
    inner_result=$(printf '%s' "$inner_result" | sed -e 's/^```[a-zA-Z]*$//' -e 's/^```$//' -e '/^[[:space:]]*$/d' | tr -d '\r')
    # Fallback: if .result is empty, treat the raw output as the correction JSON
    [[ -z "$inner_result" ]] && inner_result=$(printf '%s' "$correction_result" | sed -e 's/^```[a-zA-Z]*$//' -e 's/^```$//' -e '/^[[:space:]]*$/d' | tr -d '\r')

    corrected=$(printf '%s' "$inner_result" | jq -r '.corrected // empty' 2>/dev/null) || corrected=""
    _cr_st[CORRECTIONS_JSON]=$(printf '%s' "$inner_result" | jq '.mistakes // []' 2>/dev/null) || _cr_st[CORRECTIONS_JSON]="[]"
    _cr_st[MISTAKE_NATURE_JSON]=$(printf '%s' "$inner_result" | jq '[.mistakes[]?.type] | unique' 2>/dev/null) || _cr_st[MISTAKE_NATURE_JSON]="[]"
    _cr_st[DETECTED_LANGUAGE]=$(printf '%s' "$inner_result" | jq -r '.language // "en"' 2>/dev/null) || _cr_st[DETECTED_LANGUAGE]="en"
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

  local translation_prompt="Translate the following text to English if it is not already in English. If it is already in English, return it unchanged. Preserve @mentions, code identifiers, and technical terms exactly. Return ONLY the translated or unchanged text.

Text: $working_prompt"

  local translation_result=""
  translation_result=$(printf '%s' "$translation_prompt" | BETTER_PROMPT_CHILD=1 claude -p --output-format json --agent better-prompt:prompt-translation --model "$translation_model" 2>&1) || {
    _warn "Translation stage failed: $translation_result"
    translation_result=""
  }

  _accumulate_cost _tr_st "$translation_result"

  if [[ -n "$translation_result" ]] && command -v jq &>/dev/null; then
    local translated_text
    translated_text=$(printf '%s' "$translation_result" | jq -r '.result // empty' 2>/dev/null) || translated_text=""
    # Strip markdown fences from the agent's raw output
    translated_text=$(printf '%s' "$translated_text" | sed -e 's/^```[a-zA-Z]*$//' -e 's/^```$//' -e '/^[[:space:]]*$/d' | tr -d '\r')
    # Fallback: if .result is empty, use raw output
    if [[ -z "$translated_text" ]]; then
      translated_text="$translation_result"
    fi
    [[ -n "$translated_text" ]] && _tr_st[WORKING_PROMPT]="$translated_text"
  else
    [[ -n "$translation_result" ]] && _tr_st[WORKING_PROMPT]="$translation_result"
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

  local enhance_prompt="Enhance the following prompt. Return ONLY the enhanced prompt text — no explanation, no preamble, no quotes."

  if [[ -n "$prior_context" ]]; then
    enhance_prompt+="

Prior prompts in this session:
$prior_context"
  fi

  enhance_prompt+="

Prompt:
$working_prompt"

  local enhance_json=""
  enhance_json=$(printf '%s' "$enhance_prompt" | BETTER_PROMPT_CHILD=1 claude -p --output-format json --agent better-prompt:prompt-enhancement --model "$enhancement_model" 2>&1) || {
    _warn "Enhancement stage failed: $enhance_json"
    enhance_json=""
  }

  _accumulate_cost _en_st "$enhance_json"

  local enhanced_result=""
  if [[ -n "$enhance_json" ]] && command -v jq &>/dev/null; then
    enhanced_result=$(printf '%s' "$enhance_json" | jq -r '.result // empty' 2>/dev/null) || enhanced_result=""
    enhanced_result=$(printf '%s' "$enhanced_result" | sed -e 's/^```[a-zA-Z]*$//' -e 's/^```$//' -e '/^[[:space:]]*$/d' | tr -d '\r')
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

  # Always include the final prompt so the user can verify what was sent,
  # even when rewind fails (clipboard clobbered, permission denied, etc.).
  local escaped_enhanced
  escaped_enhanced=$(_json_escape "$enhanced_prompt")

  if [[ "$verbose" == "true" ]]; then
    local debug_msg="[Better Prompt Debug]\nOriginal:   $original_prompt"
    [[ "$correction" == "true" ]] && debug_msg+="\nCorrected:  $corrected_prompt"
    if [[ "$translation" == "true" ]]; then
      debug_msg+="\nLanguage:   ${DETECTED_LANGUAGE:-en}"
      [[ "${DETECTED_LANGUAGE:-en}" != "en" ]] && debug_msg+="\nTranslated: $working_prompt"
    fi
    [[ "$enhancement" == "true" ]] && debug_msg+="\nEnhanced:   $enhanced_prompt"
    if [[ -n "$cost_usd" ]] && [[ "$cost_usd" != "0" ]] && [[ "$cost_usd" != "0.000000" ]]; then
      debug_msg+="\nCost:       \$$(printf '%.6f' "$cost_usd")"
      debug_msg+="\nTokens:     ${input_tokens} in / ${output_tokens} out"
    fi
    debug_msg=$(printf '%b' "$debug_msg")
    local escaped_debug
    escaped_debug=$(_json_escape "$debug_msg")
    printf '{"decision": "block", "reason": %s, "enhanced": %s, "suppressOutput": false}\n' "$escaped_debug" "$escaped_enhanced"
  else
    local summary="Prompt enhanced by better-prompt.\nOriginal: ${original_prompt}\nEnhanced: ${enhanced_prompt}"
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
  local _skip_correction="false"
  if [[ "$enhancement" == "true" ]] && [[ "$translation" != "true" ]] && [[ "$correction" == "true" ]]; then
    _skip_correction="true"
    _debug "Enhancement enabled without translation — skipping correction (enhancement subsumes it)"
  fi

  # When translation is enabled without correction, still run the correction
  # agent to detect language — then discard corrections so the user's original
  # wording is preserved.  This avoids an extra claude -p invocation.
  local _correction_only_for_language="false"
  if [[ "$translation" == "true" ]] && [[ "$correction" != "true" ]] && [[ -z "${_pl_st[DETECTED_LANGUAGE]:-}" ]]; then
    _correction_only_for_language="true"
    _debug "Translation enabled without correction — running correction agent for language detection only"
  fi

  if [[ "$_skip_correction" != "true" ]] && { [[ "$correction" == "true" ]] || [[ "$_correction_only_for_language" == "true" ]]; }; then
    local _pre_prompt="${_pl_st[WORKING_PROMPT]}"
    enhance::run_correction "$1" "$correction_model"

    if [[ "$_correction_only_for_language" == "true" ]]; then
      # Discard corrections — restore original wording, keep only language
      _pl_st[WORKING_PROMPT]="$_pre_prompt"
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

main() {
  if ! command -v jq &>/dev/null; then
    printf '{"continue": true}\n'
    _warn "jq is required but not found on PATH. Install jq to enable prompt enhancement."
    exit 0
  fi

  local STDIN_PAYLOAD ORIGINAL_PROMPT
  STDIN_PAYLOAD=$(_read_stdin_payload)
  ORIGINAL_PROMPT=$(enhance::extract_prompt "$STDIN_PAYLOAD")

  declare -A _CFG=()
  _parse_config
  enhance::load_settings

  # Clean up orphaned session file from previous --resume mechanism
  rm -f "${RUNTIME_DIR}/.enhance-session"

  local SESSION_ID
  SESSION_ID=$(enhance::resolve_session_id "$STDIN_PAYLOAD")

  local SKIP_REASON
  SKIP_REASON=$(enhance::should_skip "$ENABLED" "$ORIGINAL_PROMPT" "$SESSION_ID" "$SENTINEL" "$CORRECTION" "$TRANSLATION" "$ENHANCEMENT")
  if [[ -n "$SKIP_REASON" ]]; then
    printf '{"continue": true}\n'
    exit 0
  fi

  declare -A _PS=()
  _PS[WORKING_PROMPT]="$ORIGINAL_PROMPT"
  _PS[CORRECTED_PROMPT]="$ORIGINAL_PROMPT"
  _PS[ENHANCED_PROMPT]=""
  _PS[CORRECTIONS_JSON]="[]"
  _PS[MISTAKE_NATURE_JSON]="[]"
  _PS[DETECTED_LANGUAGE]=""

  enhance::run_pipeline _PS \
    "$CORRECTION" "$CORRECTION_MODEL" \
    "$TRANSLATION" "$TRANSLATION_MODEL" \
    "$ENHANCEMENT" "$ENHANCEMENT_MODEL"

  enhance::finalize _PS "$ORIGINAL_PROMPT" "$SESSION_ID"

  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap 'printf "[better-prompt] Error at %s:%d (%s)\n" "${BASH_SOURCE[0]##*/}" "$LINENO" "${FUNCNAME[0]:-main}" >&2; exit 1' ERR
  main "$@"
fi
