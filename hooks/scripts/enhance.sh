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

# Derive the session transcript path from env vars.  Sets SESSION_FILE global.
enhance::resolve_session_file() {
  local slug
  slug=$(printf '%s' "${CLAUDE_PROJECT_DIR:-.}" | tr '/' '-')
  SESSION_FILE="$HOME/.claude/projects/$slug/$CLAUDE_SESSION_ID.jsonl"
}

# Read JSON context state and populate globals.
# Resets to defaults if the stored session_id does not match the current session
# — context is only meaningful within the session that created it.
# Sets: CONTEXT_SUMMARY, CONTEXT_COUNT, CONTEXT_LAST_UUID
enhance::read_context_state() {
  local context_file="$1"
  CONTEXT_SUMMARY=""
  CONTEXT_COUNT=0
  CONTEXT_LAST_UUID=""

  if [[ ! -f "$context_file" ]]; then
    return 0
  fi

  local parsed stored_session_id current_session_id="${CLAUDE_SESSION_ID:-}"
  parsed=$(jq -r --arg sid "$current_session_id" \
    '[.summary // "", .prompt_count // 0, .last_uuid // "", .session_id // ""] | @tsv' \
    <"$context_file" 2>/dev/null) || parsed=$'\t\t\t\t'

  IFS=$'\t' read -r CONTEXT_SUMMARY CONTEXT_COUNT CONTEXT_LAST_UUID stored_session_id <<<"$parsed"

  # Stale context from a different session — reset to defaults
  if [[ -n "$stored_session_id" ]] && [[ "$stored_session_id" != "$current_session_id" ]]; then
    CONTEXT_SUMMARY=""
    CONTEXT_COUNT=0
    CONTEXT_LAST_UUID=""
  fi
  return 0
}

# Write JSON context state atomically.
enhance::write_context_state() {
  local context_file="$1"
  local summary="$2"
  local count="$3"
  local last_uuid="$4"

  local json
  json=$(jq -n --arg s "$summary" --argjson c "$count" --arg u "$last_uuid" \
    '{summary: $s, prompt_count: $c, last_uuid: $u}')

  _atomic_write "$context_file" "$json"
  return 0
}

# Extract all user messages + all assistant text entries from the session
# transcript, excluding the last user entry (the current prompt being enhanced).
# Returns formatted "User: <text>" / "Assistant: <text>" lines.
# Sets EXTRACT_LAST_UUID with the UUID of the last assistant message.
enhance::extract_full_history() {
  local session_file="$1"
  EXTRACT_LAST_UUID=""

  [[ ! -f "$session_file" ]] && return 0

  # Two-pass approach:
  #   Pass 1: find the UUID of the last user entry (to exclude it).
  #   Pass 2: extract and format all messages before that entry.
  local last_user_uuid
  last_user_uuid=$(jq -r 'select(.type == "user") | .uuid' <"$session_file" 2>/dev/null | tail -1) || last_user_uuid=""

  # Single jq pass: extract and format all messages
  local output
  output=$(jq -r --arg exclude_uuid "$last_user_uuid" '
    def extract_text:
      if .type == "user" then
        (.message.content | if type == "string" then . elif type == "array" then [.[] | select(.type=="text") | .text] | join(" ") else "" end)
      else
        (if (.message.content | type) == "array" then [.message.content[] | select(.type=="text") | .text] | join(" ") else "" end)
      end;

    select(
      (.type == "user" or .type == "assistant")
      and (.isSidechain // false) == false
    )
    | .uuid as $uuid
    | extract_text as $text
    | select($text | length > 0)
    | "\(.type | sub("assistant";"Assistant") | sub("user";"User")): \($text)"
  ' <"$session_file" 2>/dev/null) || output=""

  # Remove lines after and including the last user message
  if [[ -n "$last_user_uuid" ]] && [[ -n "$output" ]]; then
    output=$(awk -v uuid="$last_user_uuid" '
      /^User: / { lines[NR] = $0; user_lines[NR] = 1; next }
      { lines[NR] = $0 }
      END {
        # Find last user line and print everything before it
        last_user = 0
        for (i = NR; i >= 1; i--) {
          if (user_lines[i]) { last_user = i; break }
        }
        for (i = 1; i < last_user; i++) {
          if (lines[i] != "") print lines[i]
        }
      }
    ' <<<"$output") || output=""
  fi

  printf '%s\n' "$output"

  # Find the UUID of the last assistant text entry before the excluded user message
  EXTRACT_LAST_UUID=$(jq -r --arg exclude_uuid "$last_user_uuid" '
    select(
      .type == "assistant"
      and (.isSidechain // false) == false
      and (.message.content | type) == "array"
      and ([.message.content[] | select(.type=="text") | .text] | join("") | length) > 0
    )
    | .uuid
  ' <"$session_file" 2>/dev/null | tail -1) || EXTRACT_LAST_UUID=""

  return 0
}

# Extract messages after the given UUID for incremental updates.
# Same format and filtering as extract_full_history, including exclusion
# of the current user message.
# Sets EXTRACT_LAST_UUID with the UUID of the last assistant message.
enhance::extract_since_uuid() {
  local session_file="$1"
  local last_uuid="$2"
  EXTRACT_LAST_UUID=""

  [[ ! -f "$session_file" ]] && return 0
  [[ -z "$last_uuid" ]] && {
    enhance::extract_full_history "$session_file"
    return 0
  }

  # Find the UUID of the last user entry (to exclude it)
  local last_user_uuid
  last_user_uuid=$(jq -r 'select(.type == "user") | .uuid' <"$session_file" 2>/dev/null | tail -1) || last_user_uuid=""

  # Use awk to skip lines up to and including the last_uuid line, then jq on remainder
  local remainder
  remainder=$(awk -v uuid="$last_uuid" '
    found { print; next }
    /"uuid"\s*:\s*"/ && $0 ~ uuid { found = 1 }
  ' "$session_file") || remainder=""

  [[ -z "$remainder" ]] && return 0

  # Extract formatted messages from the remainder, excluding current user message
  local output
  output=$(jq -r --arg exclude_uuid "$last_user_uuid" '
    def extract_text:
      if .type == "user" then
        (.message.content | if type == "string" then . elif type == "array" then [.[] | select(.type=="text") | .text] | join(" ") else "" end)
      else
        (if (.message.content | type) == "array" then [.message.content[] | select(.type=="text") | .text] | join(" ") else "" end)
      end;

    select(
      (.type == "user" or .type == "assistant")
      and (.isSidechain // false) == false
    )
    | .uuid as $uuid
    | select($uuid != $exclude_uuid)
    | extract_text as $text
    | select($text | length > 0)
    | "\(.type | sub("assistant";"Assistant") | sub("user";"User")): \($text)"
  ' <<<"$remainder" 2>/dev/null) || output=""

  printf '%s\n' "$output"

  # Find the last assistant UUID from the remainder
  EXTRACT_LAST_UUID=$(jq -r --arg exclude_uuid "$last_user_uuid" '
    select(
      .type == "assistant"
      and (.isSidechain // false) == false
      and (.message.content | type) == "array"
      and ([.message.content[] | select(.type=="text") | .text] | join("") | length) > 0
      and .uuid != $exclude_uuid
    )
    | .uuid
  ' <<<"$remainder" 2>/dev/null | tail -1) || EXTRACT_LAST_UUID=""

  return 0
}

# Build prompt for full summarisation from extracted history.
enhance::format_full_summary_input() {
  local history_text="$1"
  printf 'Summarise this conversation in 3-5 sentences. Focus on topic, technical context, user'"'"'s goal, and key decisions. Be concise.\n\n%s\n\nSummary:' "$history_text"
}

# Build prompt for incremental summarisation update.
enhance::format_incremental_input() {
  local summary="$1"
  local new_exchange="$2"
  printf 'Given this summary:\n%s\n\nUpdate it with this new exchange:\n%s\n\nProvide an updated summary in 3-5 sentences. Drop stale details if no longer relevant.\n\nUpdated summary:' "$summary" "$new_exchange"
}

# Main summarisation orchestrator.
# Arguments:
#   $1 - state_nameref: pipeline state associative array
#   $2 - context_file: path to .context JSON state file
#   $3 - incremental_model: model for incremental updates (e.g. correction_model)
#   $4 - full_refresh_model: model for full refreshes (e.g. enhancement_model)
# Sets CONTEXT_SUMMARY global for the enhancement stage.
enhance::run_summarisation() {
  local -n _su_st="$1"
  local context_file="$2"
  local incremental_model="$3"
  local full_refresh_model="$4"

  CONTEXT_SUMMARY=""
  enhance::resolve_session_file
  enhance::read_context_state "$context_file"

  # First prompt — nothing to summarise yet
  if [[ "${CONTEXT_COUNT:-0}" -eq 0 ]]; then
    enhance::write_context_state "$context_file" "" 1 ""
    _debug "summarisation: skipped (first prompt)"
    return 0
  fi

  local model input_text new_uuid

  if [[ "${CONTEXT_COUNT:-0}" -ge 10 ]] || [[ -z "${CONTEXT_LAST_UUID:-}" ]]; then
    # Full refresh — read entire transcript
    model="$full_refresh_model"
    _debug "summarisation ($model): full refresh"
    local history
    history=$(enhance::extract_full_history "$SESSION_FILE") || history=""
    new_uuid="${EXTRACT_LAST_UUID:-}"
    input_text=$(enhance::format_full_summary_input "$history")
  else
    # Incremental — only new messages since last_uuid
    model="$incremental_model"
    _debug "summarisation ($model): incremental"
    local new_exchange
    new_exchange=$(enhance::extract_since_uuid "$SESSION_FILE" "$CONTEXT_LAST_UUID") || new_exchange=""
    new_uuid="${EXTRACT_LAST_UUID:-}"
    input_text=$(enhance::format_incremental_input "$CONTEXT_SUMMARY" "$new_exchange")
  fi

  local summary_json=""
  summary_json=$(printf '%s' "$input_text" | BETTER_PROMPT_CHILD=1 claude -p \
    --no-session-persistence --output-format json \
    --agent better-prompt:prompt-summarisation --model "$model" 2>&1) || {
    _warn "Summarisation stage failed: $summary_json"
    _debug "summarisation ($model): failed"
    CONTEXT_SUMMARY=""
    return 0
  }

  _accumulate_cost _su_st "$summary_json"

  local summary_result=""
  if [[ -n "$summary_json" ]]; then
    summary_result=$(jq -r '.result // empty' <<<"$summary_json" 2>/dev/null) || summary_result=""
  fi

  if [[ -n "$summary_result" ]]; then
    CONTEXT_SUMMARY="$summary_result"
    _debug "summarisation ($model): done"
  else
    CONTEXT_SUMMARY=""
    _debug "summarisation ($model): empty result"
  fi

  enhance::write_context_state "$context_file" "${CONTEXT_SUMMARY}" "$((CONTEXT_COUNT + 1))" "${new_uuid:-$CONTEXT_LAST_UUID}"
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
  parsed=$(jq -r '[.total_cost_usd // 0, (.usage.input_tokens // 0), (.usage.output_tokens // 0), (.usage.cache_creation_input_tokens // 0), (.usage.cache_read_input_tokens // 0)] | @tsv' \
    <<<"$raw_json" 2>/dev/null) || parsed=$'0\t0\t0\t0\t0'

  local stage_cost stage_input stage_output stage_cache_write stage_cache_read
  IFS=$'\t' read -r stage_cost stage_input stage_output stage_cache_write stage_cache_read <<<"$parsed"

  # Sanitise: ensure all values are numeric before arithmetic / awk interpolation
  [[ "$stage_cost" =~ ^[0-9]*\.?[0-9]+$ ]] || stage_cost="0"
  [[ "$stage_input" =~ ^[0-9]+$ ]] || stage_input="0"
  [[ "$stage_output" =~ ^[0-9]+$ ]] || stage_output="0"
  [[ "$stage_cache_write" =~ ^[0-9]+$ ]] || stage_cache_write="0"
  [[ "$stage_cache_read" =~ ^[0-9]+$ ]] || stage_cache_read="0"

  # Use awk for float addition (avoids bc dependency)
  _ac_st[COST_USD]=$(awk "BEGIN {printf \"%.6f\", (${_ac_st[COST_USD]:-0}) + $stage_cost}")
  _ac_st[INPUT_TOKENS]="$((${_ac_st[INPUT_TOKENS]:-0} + stage_input))"
  _ac_st[OUTPUT_TOKENS]="$((${_ac_st[OUTPUT_TOKENS]:-0} + stage_output))"
  _ac_st[CACHE_WRITE_TOKENS]="$((${_ac_st[CACHE_WRITE_TOKENS]:-0} + stage_cache_write))"
  _ac_st[CACHE_READ_TOKENS]="$((${_ac_st[CACHE_READ_TOKENS]:-0} + stage_cache_read))"
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

  local correction_result=""
  correction_result=$(printf '%s' "$working_prompt" | BETTER_PROMPT_CHILD=1 claude -p --no-session-persistence --output-format json --agent better-prompt:prompt-correction --model "$correction_model" 2>&1) || {
    _warn "Correction stage failed: $correction_result"
    _debug "correction ($correction_model): stage failed"
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

  local mistake_count
  mistake_count=$(jq 'length' <<<"${_cr_st[CORRECTIONS_JSON]}" 2>/dev/null) || mistake_count=0
  if [[ "$mistake_count" -gt 0 ]]; then
    _debug "correction ($correction_model): $mistake_count mistakes fixed"
  else
    _debug "correction ($correction_model): no changes"
  fi

  return 0
}

enhance::run_translation() {
  local -n _tr_st="$1"
  local working_prompt="${_tr_st[WORKING_PROMPT]}"
  local translation_model="$2"

  local translation_result=""
  translation_result=$(printf '%s' "$working_prompt" | BETTER_PROMPT_CHILD=1 claude -p --no-session-persistence --output-format json --agent better-prompt:prompt-translation --model "$translation_model" 2>&1) || {
    _warn "Translation stage failed: $translation_result"
    _debug "translation ($translation_model): stage failed"
    translation_result=""
  }

  _accumulate_cost _tr_st "$translation_result"

  if [[ -n "$translation_result" ]]; then
    local translated_text
    translated_text=$(jq -r '.result // empty' <<<"$translation_result" 2>/dev/null) || translated_text=""
    if [[ -z "$translated_text" ]]; then
      translated_text="$translation_result"
    fi
    if [[ -n "$translated_text" ]]; then
      _tr_st[WORKING_PROMPT]="$translated_text"
      _debug "translation ($translation_model): done"
    fi
  fi
  return 0
}

enhance::run_enhancement_stage() {
  local -n _en_st="$1"
  local working_prompt="$2"
  local enhancement_model="$3"

  local enhance_input=""

  if [[ -n "${CONTEXT_SUMMARY:-}" ]]; then
    enhance_input+="Conversation context: ${CONTEXT_SUMMARY}

"
  fi

  enhance_input+="$working_prompt"

  local enhance_json=""
  enhance_json=$(printf '%s' "$enhance_input" | BETTER_PROMPT_CHILD=1 claude -p --no-session-persistence --output-format json --agent better-prompt:prompt-enhancement --model "$enhancement_model" 2>&1) || {
    _warn "Enhancement stage failed: $enhance_json"
    _debug "enhancement ($enhancement_model): stage failed"
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

  if [[ "$enhanced_result" != "$working_prompt" ]]; then
    _debug "enhancement ($enhancement_model): done"
  else
    _debug "enhancement ($enhancement_model): no changes"
  fi

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
  local -r audit_filter='{"date":$date,"prompt":$prompt,"language":$language,"corrected":(if $correction_on then $corrected else null end),"enhanced":(if $enhancement_on then $enhanced else null end),"mistake-nature":$nature,"mistakes":$mistakes,"models":{"correction":$correction_model,"translation":$translation_model,"enhancement":$enhancement_model}}'

  jq -nc --arg date "$audit_date" --arg prompt "$original_prompt" --argjson language "$audit_language" --arg corrected "$corrected_prompt" --arg enhanced "$enhanced_prompt" --argjson correction_on "$correction" --argjson enhancement_on "$enhancement" --argjson nature "$mistake_nature_json" --argjson mistakes "$corrections_json" --argjson correction_model "$audit_correction_model" --argjson enhancement_model "$audit_enhancement_model" --argjson translation_model "$audit_translation_model" "$audit_filter" >>"$audit_log"
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
#   $12 - cache_write_tokens: accumulated cache creation tokens
#   $13 - cache_read_tokens: accumulated cache read tokens
#   $14 - debug_log: buffered pipeline stage messages
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
  local cache_write_tokens="${12:-0}"
  local cache_read_tokens="${13:-0}"
  local debug_log="${14:-}"

  # Always include the full enhanced prompt so the user can verify what was
  # sent, even when rewind fails (clipboard clobbered, permission denied, etc.).
  local escaped_enhanced
  escaped_enhanced=$(_json_escape "$enhanced_prompt")

  # Truncated previews for the reason field (UI display only).
  local preview_original preview_enhanced
  preview_original=$(_truncate_for_display "$original_prompt")
  preview_enhanced=$(_truncate_for_display "$enhanced_prompt")

  if [[ "$verbose" == "true" ]]; then
    local debug_msg="[Better Prompt Debug]\n Original:   $preview_original"
    [[ -n "$debug_log" ]] && debug_msg+="\n$debug_log"
    if [[ "$correction" == "true" ]]; then
      local preview_corrected
      preview_corrected=$(_truncate_for_display "$corrected_prompt")
      debug_msg+="\n Corrected:  $preview_corrected"
    fi
    if [[ "$translation" == "true" ]]; then
      debug_msg+="\n Language:   ${DETECTED_LANGUAGE:-en}"
      if [[ "${DETECTED_LANGUAGE:-en}" != "en" ]]; then
        local preview_working
        preview_working=$(_truncate_for_display "$working_prompt")
        debug_msg+="\n Translated: $preview_working"
      fi
    fi
    [[ "$enhancement" == "true" ]] && debug_msg+="\n Enhanced:   $preview_enhanced"
    if [[ -n "$cost_usd" ]] && [[ "$cost_usd" != "0" ]] && [[ "$cost_usd" != "0.000000" ]]; then
      debug_msg+="\n Cost:       \$$(printf '%.6f' "$cost_usd")"
      local token_line="${input_tokens} in"
      [[ "$cache_write_tokens" != "0" ]] && token_line+=" (${cache_write_tokens} w)"
      token_line+=" / ${output_tokens} out"
      [[ "$cache_read_tokens" != "0" ]] && token_line+=" (${cache_read_tokens} r)"
      debug_msg+="\n Tokens:     $token_line"
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

  # Pass through without blocking.
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
  _pl_st[CACHE_WRITE_TOKENS]="0"
  _pl_st[CACHE_READ_TOKENS]="0"
  _DEBUG_LOG=""

  # When enhancement is enabled without translation, correction is redundant —
  # enhancement subsumes grammar/spelling fixes and no language detection is needed.
  local skip_correction="false"
  if [[ "$enhancement" == "true" ]] && [[ "$translation" != "true" ]] && [[ "$correction" == "true" ]]; then
    skip_correction="true"
    _debug "correction: skipped (enhancement subsumes it)"
  fi

  # When translation is enabled without correction, still run the correction
  # agent to detect language — then discard corrections so the user's original
  # wording is preserved.  This avoids an extra claude -p invocation.
  local correction_only_for_language="false"
  if [[ "$translation" == "true" ]] && [[ "$correction" != "true" ]] && [[ -z "${_pl_st[DETECTED_LANGUAGE]:-}" ]]; then
    correction_only_for_language="true"
  fi

  if [[ "$skip_correction" != "true" ]] && { [[ "$correction" == "true" ]] || [[ "$correction_only_for_language" == "true" ]]; }; then
    local pre_prompt="${_pl_st[WORKING_PROMPT]}"
    enhance::run_correction "$1" "$correction_model"

    if [[ "$correction_only_for_language" == "true" ]]; then
      # Discard corrections — restore original wording, keep only language
      _pl_st[WORKING_PROMPT]="$pre_prompt"
      _pl_st[CORRECTIONS_JSON]="[]"
      _pl_st[MISTAKE_NATURE_JSON]="[]"
      _debug "language detection ($correction_model): ${_pl_st[DETECTED_LANGUAGE]}"
    fi
  fi
  _pl_st[CORRECTED_PROMPT]="${_pl_st[WORKING_PROMPT]}"

  if [[ "$translation" == "true" ]]; then
    if [[ -n "${_pl_st[DETECTED_LANGUAGE]:-}" && "${_pl_st[DETECTED_LANGUAGE]}" == "en" ]]; then
      _debug "translation ($translation_model): skipped (english)"
    else
      enhance::run_translation "$1" "$translation_model"
    fi
  fi

  _pl_st[ENHANCED_PROMPT]="${_pl_st[WORKING_PROMPT]}"
  if [[ "$enhancement" == "true" ]]; then
    # Context summarisation — only runs with enhancement
    enhance::run_summarisation "$1" "$CONTEXT_FILE" "$correction_model" "$enhancement_model"
    _pl_st[ENHANCED_PROMPT]=$(enhance::run_enhancement_stage "$1" "${_pl_st[WORKING_PROMPT]}" "$enhancement_model")
  fi
  return 0
}

enhance::finalize() {
  local -n _fn_st="$1"
  local original_prompt="$2"
  local session_id="$3"

  local final_prompt="${_fn_st[ENHANCED_PROMPT]:-${_fn_st[WORKING_PROMPT]}}"

  if [[ "$AUDIT" == "true" ]] && command -v jq &>/dev/null; then
    enhance::write_audit "$AUDIT_LOG" "$original_prompt" "${_fn_st[CORRECTED_PROMPT]}" "$final_prompt" \
      "${_fn_st[MISTAKE_NATURE_JSON]}" "${_fn_st[CORRECTIONS_JSON]}" "${_fn_st[DETECTED_LANGUAGE]:-}" \
      "$CORRECTION" "$CORRECTION_MODEL" "$ENHANCEMENT" "$ENHANCEMENT_MODEL" "$TRANSLATION" "$TRANSLATION_MODEL"
  fi

  enhance::write_sentinel "$SENTINEL" "$final_prompt"
  enhance::copy_to_clipboard "$final_prompt"
  _debug "clipboard: final prompt copied"
  enhance::spawn_stop_hook "$session_id"
  enhance::format_response "$VERBOSE" "$original_prompt" "${_fn_st[CORRECTED_PROMPT]}" "${_fn_st[WORKING_PROMPT]}" "$final_prompt" \
    "$CORRECTION" "$TRANSLATION" "$ENHANCEMENT" \
    "${_fn_st[COST_USD]:-0}" "${_fn_st[INPUT_TOKENS]:-0}" "${_fn_st[OUTPUT_TOKENS]:-0}" \
    "${_fn_st[CACHE_WRITE_TOKENS]:-0}" "${_fn_st[CACHE_READ_TOKENS]:-0}" "${_DEBUG_LOG:-}"
}

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
    return 0
  fi
  if [[ "$first_char" == "/" || "$first_char" == "!" ]]; then
    return 0
  fi

  # No fast-fail condition matched — proceed to full pipeline
  return 1
}

###
### :::: Main :::: #####################
###

main() {
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
