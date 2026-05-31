#!/usr/bin/env bash
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
readonly PLUGIN_ROOT CONFIG

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
  if [[ "${DEBUG:-false}" == "true" ]]; then
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

# macOS md5 prints only the digest; GNU md5sum appends the filename
_md5() {
  printf '%s' "$1" | (md5 2>/dev/null || md5sum 2>/dev/null | cut -c1-32)
  return 0
}

_get_setting() {
  local key="$1"
  local default="$2"
  printf '%s' "${_CFG[$key]:-$default}"
  return 0
}

_parse_config() {
  if [[ ! -f "$CONFIG" ]]; then
    return 0
  fi
  local key val in_front=0
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      ((++in_front))
      continue
    fi
    [[ "$in_front" -eq 1 ]] || continue
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    key="${line%%:*}"
    [[ -z "$key" ]] && continue
    val="${line#*:}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    _CFG["$key"]="$val"
  done <"$CONFIG"
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
    local session_dir="$HOME/.claude/session-env/"
    if [[ -d "$session_dir" ]]; then
      # ls -t is ~50x faster than find -exec stat; session IDs are UUIDs
      # shellcheck disable=SC2012
      session_id=$(ls -1t "$session_dir" 2>/dev/null | head -n 1) || {
        _warn "Failed to find session ID"
        session_id=""
      }
    fi
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

# Side effects: sets globals WORKING_PROMPT, CORRECTED_PROMPT, CORRECTIONS_JSON,
# MISTAKE_NATURE_JSON, DETECTED_LANGUAGE.
# Arguments:
#   $1 - working_prompt: prompt text to correct
#   $2 - correction_model: model identifier for the correction agent
enhance::run_correction() {
  local working_prompt="$1"
  local correction_model="$2"

  _debug "Running correction with model: $correction_model"

  local correction_prompt="Correct the following prompt in terms of grammar and make it clear in context. Return ONLY the raw JSON object — no markdown, no code blocks.

Prompt: $working_prompt"

  local correction_result=""
  correction_result=$(BETTER_PROMPT_CHILD=1 claude -p --agent better-prompt:prompt-correction --model "$correction_model" "$correction_prompt" 2>&1) || {
    _warn "Correction stage failed: $correction_result"
    correction_result=""
  }

  local corrected=""
  CORRECTIONS_JSON="[]"
  MISTAKE_NATURE_JSON="[]"

  if [[ -n "$correction_result" ]] && command -v jq &>/dev/null; then
    correction_result=$(printf '%s' "$correction_result" | sed -e 's/^```[a-zA-Z]*$//' -e 's/^```$//' -e '/^[[:space:]]*$/d' | tr -d '\r')

    local -r _sep=$'\x01'
    local _cr_output
    _cr_output=$(printf '%s' "$correction_result" | jq -j --arg s "$_sep" \
      '.corrected // "", $s, (.mistakes // [] | @json), $s, ([.mistakes[]?.type] | unique | @json), $s, (.language // "en")' 2>/dev/null) || _cr_output=""
    if [[ -n "$_cr_output" ]]; then
      corrected="${_cr_output%%"$_sep"*}"
      local _rest="${_cr_output#*"$_sep"}"
      CORRECTIONS_JSON="${_rest%%"$_sep"*}"
      local _rest2="${_rest#*"$_sep"}"
      MISTAKE_NATURE_JSON="${_rest2%%"$_sep"*}"
      DETECTED_LANGUAGE="${_rest2#*"$_sep"}"
    fi
  fi

  [[ -n "$corrected" ]] && WORKING_PROMPT="$corrected"
  CORRECTED_PROMPT="$WORKING_PROMPT"
  return 0
}

# Side effects: overwrites WORKING_PROMPT global with translated text.
# Arguments:
#   $1 - working_prompt: prompt text to translate
#   $2 - translation_model: model identifier for the translation agent
enhance::run_translation() {
  local working_prompt="$1"
  local translation_model="$2"

  _debug "Running translation with model: $translation_model"

  local translation_prompt="Translate the following text to English if it is not already in English. If it is already in English, return it unchanged. Preserve @mentions, code identifiers, and technical terms exactly. Return ONLY the translated or unchanged text.

Text: $working_prompt"

  local translation_result=""
  translation_result=$(BETTER_PROMPT_CHILD=1 claude -p --agent better-prompt:prompt-translation --model "$translation_model" "$translation_prompt" 2>&1) || {
    _warn "Translation stage failed: $translation_result"
    translation_result=""
  }

  [[ -n "$translation_result" ]] && WORKING_PROMPT="$translation_result"
  return 0
}

enhance::run_enhancement_stage() {
  local working_prompt="$1"
  local enhancement_model="$2"
  local enhance_session_file="$3"

  _debug "Running enhancement with model: $enhancement_model"

  local resume_args=()
  if [[ -f "$enhance_session_file" ]]; then
    local stored_id
    stored_id=$(cat "$enhance_session_file" 2>/dev/null || true)
    if [[ -n "$stored_id" ]]; then
      resume_args=(--resume "$stored_id")
      _debug "Resuming enhancement session: $stored_id"
    fi
  fi

  local enhance_prompt="Enhance the following prompt. Return ONLY the enhanced prompt text — no explanation, no preamble, no quotes.

Prompt:
$working_prompt"

  local enhance_json=""
  enhance_json=$(BETTER_PROMPT_CHILD=1 claude -p "${resume_args[@]}" --output-format json --agent better-prompt:prompt-enhancement --model "$enhancement_model" "$enhance_prompt" 2>&1) || {
    if [[ -f "$enhance_session_file" ]]; then
      _debug "Resume failed, retrying without session"
      rm -f "$enhance_session_file"
      enhance_json=$(BETTER_PROMPT_CHILD=1 claude -p --output-format json --agent better-prompt:prompt-enhancement --model "$enhancement_model" "$enhance_prompt" 2>&1) || {
        _warn "Enhancement stage failed: $enhance_json"
        enhance_json=""
      }
    else
      _warn "Enhancement stage failed: $enhance_json"
      enhance_json=""
    fi
  }

  local enhanced_result=""
  if [[ -n "$enhance_json" ]] && command -v jq &>/dev/null; then
    local -r _sep=$'\x01'
    local _en_output
    _en_output=$(printf '%s' "$enhance_json" | jq -j --arg s "$_sep" \
      '.result // "", $s, .session_id // ""' 2>/dev/null) || _en_output=""
    if [[ -n "$_en_output" ]]; then
      enhanced_result="${_en_output%%"$_sep"*}"
      local enhance_sid="${_en_output#*"$_sep"}"
      [[ -n "$enhance_sid" ]] && _atomic_write "$enhance_session_file" "$enhance_sid"
    fi
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
  local correction="$7"
  local correction_model="$8"
  local enhancement="$9"
  local enhancement_model="${10}"
  local translation="${11}"
  local translation_model="${12}"

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
  if [[ -n "${DETECTED_LANGUAGE:-}" ]]; then
    audit_language="\"$DETECTED_LANGUAGE\""
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
#   $1 - debug_mode: "true"/"false"
#   $2 - original_prompt: unmodified user prompt
#   $3 - corrected_prompt: post-correction text
#   $4 - working_prompt: current state (may include translation)
#   $5 - enhanced_prompt: final prompt after all stages
#   $6 - correction: "true"/"false"
#   $7 - translation: "true"/"false"
#   $8 - enhancement: "true"/"false"
enhance::format_response() {
  local debug_mode="$1"
  local original_prompt="$2"
  local corrected_prompt="$3"
  local working_prompt="$4"
  local enhanced_prompt="$5"
  local correction="$6"
  local translation="$7"
  local enhancement="$8"

  if [[ "$debug_mode" == "true" ]]; then
    local debug_msg="[Better Prompt Debug]\nOriginal:   $original_prompt"
    [[ "$correction" == "true" ]] && debug_msg+="\nCorrected:  $corrected_prompt"
    if [[ "$translation" == "true" ]]; then
      debug_msg+="\nLanguage:   ${DETECTED_LANGUAGE:-en}"
      [[ "${DETECTED_LANGUAGE:-en}" != "en" ]] && debug_msg+="\nTranslated: $working_prompt"
    fi
    [[ "$enhancement" == "true" ]] && debug_msg+="\nEnhanced:   $enhanced_prompt"
    debug_msg=$(printf '%b' "$debug_msg")
    local escaped_debug
    escaped_debug=$(_json_escape "$debug_msg")
    printf '{"decision": "block", "reason": %s, "suppressOutput": false}\n' "$escaped_debug"
  else
    printf '{"decision": "block", "reason": "Prompt replaced by better-prompt plugin.", "suppressOutput": false}\n'
  fi
  return 0
}

enhance::spawn_stop_hook() {
  local session_id="$1"
  local stop_log="${TMPDIR:-/tmp}/better-prompt-stop.log"
  CLAUDE_SESSION_ID="$session_id" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    nohup bash "${PLUGIN_ROOT}/hooks/scripts/stop-hook.sh" \
    </dev/null >>"$stop_log" 2>&1 &
  disown
  _debug "stop-hook.sh spawned (pid $!), log: $stop_log"
  return 0
}

enhance::load_settings() {
  DEBUG=$(_get_setting "debug_mode" "false")
  ENABLED=$(_get_setting "enabled" "true")
  CORRECTION=$(_get_setting "correction" "true")
  CORRECTION_MODEL=$(_get_setting "correction_model" "haiku")
  ENHANCEMENT=$(_get_setting "enhancement" "false")
  ENHANCEMENT_MODEL=$(_get_setting "enhancement_model" "sonnet")
  TRANSLATION=$(_get_setting "translation" "false")
  TRANSLATION_MODEL=$(_get_setting "translation_model" "haiku")
  AUDIT=$(_get_setting "audit" "true")
  AUDIT_LOG="${CLAUDE_PROJECT_DIR:-.}/.claude/prompts.json"
  SENTINEL="${CLAUDE_PROJECT_DIR:-.}/.claude/.better-prompt-sentinel"
  ENHANCE_SESSION_FILE="${CLAUDE_PROJECT_DIR:-.}/.claude/.better-prompt-enhance-session"
  return 0
}

enhance::should_skip() {
  local enabled="$1"
  local prompt="$2"
  local session_id="$3"
  local sentinel_path="$4"

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

  printf ''
}

enhance::run_pipeline() {
  local original_prompt="$1"
  local correction="$2"
  local correction_model="$3"
  local translation="$4"
  local translation_model="$5"
  local enhancement="$6"
  local enhancement_model="$7"
  local enhance_session_file="$8"

  WORKING_PROMPT="$original_prompt"
  CORRECTED_PROMPT="$original_prompt"
  CORRECTIONS_JSON="[]"
  MISTAKE_NATURE_JSON="[]"

  if [[ "$correction" == "true" ]]; then
    enhance::run_correction "$WORKING_PROMPT" "$correction_model"
  fi
  CORRECTED_PROMPT="$WORKING_PROMPT"

  if [[ "$translation" == "true" ]]; then
    if [[ -n "${DETECTED_LANGUAGE:-}" && "$DETECTED_LANGUAGE" == "en" ]]; then
      _debug "Prompt is English — skipping translation"
    else
      enhance::run_translation "$WORKING_PROMPT" "$translation_model"
    fi
  fi

  ENHANCED_PROMPT="$WORKING_PROMPT"
  if [[ "$enhancement" == "true" ]]; then
    ENHANCED_PROMPT=$(enhance::run_enhancement_stage "$WORKING_PROMPT" "$enhancement_model" "$enhance_session_file")
  fi
  return 0
}

enhance::finalize() {
  local original_prompt="$1"
  local session_id="$2"

  local final_prompt="${ENHANCED_PROMPT:-$WORKING_PROMPT}"

  if [[ "$AUDIT" == "true" ]] && command -v jq &>/dev/null; then
    enhance::write_audit "$AUDIT_LOG" "$original_prompt" "$CORRECTED_PROMPT" "$final_prompt" \
      "$MISTAKE_NATURE_JSON" "$CORRECTIONS_JSON" \
      "$CORRECTION" "$CORRECTION_MODEL" "$ENHANCEMENT" "$ENHANCEMENT_MODEL" "$TRANSLATION" "$TRANSLATION_MODEL"
  fi

  enhance::write_sentinel "$SENTINEL" "$final_prompt"
  enhance::format_response "$DEBUG" "$original_prompt" "$CORRECTED_PROMPT" "$WORKING_PROMPT" "$final_prompt" \
    "$CORRECTION" "$TRANSLATION" "$ENHANCEMENT"
  enhance::copy_to_clipboard "$final_prompt"
  _debug "Original prompt blocked; final prompt copied to clipboard for rewind"
  enhance::spawn_stop_hook "$session_id"
}

###
### :::: Main :::: #####################
###

main() {
  local STDIN_PAYLOAD ORIGINAL_PROMPT
  STDIN_PAYLOAD=$(_read_stdin_payload)
  ORIGINAL_PROMPT=$(enhance::extract_prompt "$STDIN_PAYLOAD")

  declare -A _CFG=()
  _parse_config
  enhance::load_settings

  local SESSION_ID
  SESSION_ID=$(enhance::resolve_session_id "$STDIN_PAYLOAD")

  local SKIP_REASON
  SKIP_REASON=$(enhance::should_skip "$ENABLED" "$ORIGINAL_PROMPT" "$SESSION_ID" "$SENTINEL")
  if [[ -n "$SKIP_REASON" ]]; then
    printf '{"continue": true}\n'
    exit 0
  fi

  WORKING_PROMPT="" CORRECTED_PROMPT="" ENHANCED_PROMPT=""
  CORRECTIONS_JSON="[]" MISTAKE_NATURE_JSON="[]" DETECTED_LANGUAGE=""

  enhance::run_pipeline "$ORIGINAL_PROMPT" \
    "$CORRECTION" "$CORRECTION_MODEL" \
    "$TRANSLATION" "$TRANSLATION_MODEL" \
    "$ENHANCEMENT" "$ENHANCEMENT_MODEL" \
    "$ENHANCE_SESSION_FILE"

  enhance::finalize "$ORIGINAL_PROMPT" "$SESSION_ID"

  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap 'printf "[better-prompt] Error at %s:%d (%s)\n" "${BASH_SOURCE[0]##*/}" "$LINENO" "${FUNCNAME[0]:-main}" >&2; exit 1' ERR
  main "$@"
fi
