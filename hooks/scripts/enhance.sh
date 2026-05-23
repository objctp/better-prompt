#!/usr/bin/env bash
#
# Enhance user prompts via correction, translation, and enhancement stages
# Usage: enhance.sh < stdin-payload
#
set -euo pipefail

###
### :::: Constants and Globals :::: ####
###

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
CONFIG="${BETTER_PROMPT_CONFIG:-$HOME/.claude/better-prompt.local.md}"

if [[ -z "${_IS_MACOS:-}" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    _IS_MACOS=true
  else
    _IS_MACOS=false
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
    printf '%s' "$input" | sed 's/\\/\\\\/g; s/"/\\"/g'
  fi
  return 0
}

_atomic_write() {
  local target="$1" content="$2"
  local tmp
  tmp=$(mktemp "${target}.XXXXXX") || return 1
  # Temp + rename prevents partial reads from concurrent processes
  printf '%s' "$content" >"$tmp" && mv -f "$tmp" "$target"
  return 0
}

_md5() {
  # macOS `md5` prints only the digest; GNU `md5sum` appends the filename
  printf '%s' "$1" | (md5 2>/dev/null || md5sum 2>/dev/null | cut -c1-32)
  return 0
}

_get_setting() {
  local key="$1"
  local default="$2"
  printf '%s' "${_CFG[$key]:-$default}" # falls back to $default when key absent
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

_run_enhance() {
  local resume_args=()
  if [[ -f "$ENHANCE_SESSION_FILE" ]]; then
    local stored_id
    stored_id=$(cat "$ENHANCE_SESSION_FILE" 2>/dev/null || true)
    if [[ -n "$stored_id" ]]; then
      resume_args=(--resume "$stored_id")
      _debug "Resuming enhancement session: $stored_id"
    fi
  fi

  claude -p \
    "${resume_args[@]}" \
    --output-format json \
    --agent better-prompt:prompt-enhancement \
    --model "$ENHANCEMENT_MODEL" \
    "Enhance the following prompt. Return ONLY the enhanced prompt text — no explanation, no preamble, no quotes.

Prompt:
$WORKING_PROMPT" 2>&1
  return 0
}

###
### :::: Main :::: #####################
###

main() {
  local STDIN_PAYLOAD ORIGINAL_PROMPT
  STDIN_PAYLOAD=$(_read_stdin_payload)
  ORIGINAL_PROMPT=$(printf '%s' "$STDIN_PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null || true)

  local SENTINEL="${CLAUDE_PROJECT_DIR:-.}/.claude/.better-prompt-sentinel" # project-scoped, survives rewinds

  declare -A _CFG=()
  _parse_config

  local DEBUG # bootstrap early so _debug() works on first call
  DEBUG=$(_get_setting "debug_mode" "false")

  local ENABLED CORRECTION CORRECTION_MODEL
  local ENHANCEMENT ENHANCEMENT_MODEL
  local TRANSLATION TRANSLATION_MODEL
  local AUDIT AUDIT_LOG
  ENABLED=$(_get_setting "enabled" "true")
  CORRECTION=$(_get_setting "correction" "true")
  CORRECTION_MODEL=$(_get_setting "correction_model" "haiku")
  ENHANCEMENT=$(_get_setting "enhancement" "false")
  ENHANCEMENT_MODEL=$(_get_setting "enhancement_model" "sonnet")
  TRANSLATION=$(_get_setting "translation" "false")
  TRANSLATION_MODEL=$(_get_setting "translation_model" "haiku")
  AUDIT=$(_get_setting "audit" "true")
  AUDIT_LOG="${CLAUDE_PROJECT_DIR:-.}/.claude/prompts.json"

  ###
  ### :::: Global Kill Switch :::: #######
  ###

  if [[ "$ENABLED" == "false" ]]; then
    printf '{"continue": true}\n'
    exit 0
  fi

  ###
  ### :::: Resolve Session ID :::: ######
  ###

  local SESSION_ID="" # stdin → env → most-recent session file

  if [[ -n "$STDIN_PAYLOAD" ]] && command -v jq &>/dev/null; then
    SESSION_ID=$(printf '%s' "$STDIN_PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
  fi

  if [[ -z "$SESSION_ID" ]] && [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    SESSION_ID="$CLAUDE_SESSION_ID"
  fi

  if [[ -z "$SESSION_ID" ]]; then
    local SESSION_DIR="$HOME/.claude/session-env/"
    if [[ -d "$SESSION_DIR" ]]; then
      if [[ "$_IS_MACOS" == true ]]; then
        SESSION_ID=$(find "$SESSION_DIR" -mindepth 1 -maxdepth 1 -type d \
          -exec stat -f '%m %N' {} \; 2>/dev/null |
          sort -rn | head -1 | awk '{print $NF}' | xargs basename) || {
          _warn "Failed to find session ID on macOS"
          SESSION_ID=""
        }
      else
        SESSION_ID=$(find "$SESSION_DIR" -mindepth 1 -maxdepth 1 -type d \
          -printf '%T@ %f\n' 2>/dev/null |
          sort -rn | head -1 | cut -d' ' -f2-) || {
          _warn "Failed to find session ID"
          SESSION_ID=""
        }
      fi
    fi
  fi

  if [[ -n "$SESSION_ID" ]]; then
    if ! [[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      _warn "Invalid session ID format: $SESSION_ID"
      SESSION_ID=""
    fi
  fi

  ###
  ### :::: Early Exit :::: ##############
  ###

  if [[ -z "$ORIGINAL_PROMPT" ]] || [[ -z "$SESSION_ID" ]]; then
    printf '{"continue": true}\n'
    exit 0
  fi

  if [[ "$ORIGINAL_PROMPT" =~ ^[/!] ]]; then # Claude Code UI directives, not natural language
    printf '{"continue": true}\n'
    exit 0
  fi

  ###
  ### :::: Sentinel Loop Guard :::: ######
  ###

  # Content-based hash (not session ID) so the guard survives rewinds,
  # which assign a fresh session ID and would otherwise reprocess the prompt.
  #
  #   first run  → write hash of ENHANCED_PROMPT to $SENTINEL
  #   second run → compare incoming hash → bypass on match
  if [[ -f "$SENTINEL" ]]; then
    local SENTINEL_AGE
    SENTINEL_AGE=$(($(date +%s) - $(stat -f '%m' "$SENTINEL" 2>/dev/null ||
      stat -c '%Y' "$SENTINEL" 2>/dev/null || echo 0)))
    if [[ "$SENTINEL_AGE" -lt 60 ]]; then
      local STORED_HASH INCOMING_HASH
      STORED_HASH=$(cat "$SENTINEL" 2>/dev/null || echo "")
      INCOMING_HASH=$(_md5 "$ORIGINAL_PROMPT")
      if [[ -n "$STORED_HASH" ]] && [[ "$INCOMING_HASH" == "$STORED_HASH" ]]; then
        _debug "Sentinel matched (${SENTINEL_AGE}s old, hash=${INCOMING_HASH}) — passing re-fired prompt through"
        rm -f "$SENTINEL"
        printf '{"continue": true}\n'
        exit 0
      else
        _debug "Sentinel present but hash mismatch — new prompt, proceeding (stored=${STORED_HASH:-empty}, incoming=${INCOMING_HASH})"
      fi
    else
      _debug "Stale sentinel (${SENTINEL_AGE}s old) — removing"
      rm -f "$SENTINEL"
    fi
  fi

  ###
  ### :::: Correction Stage :::: ########
  ###

  # Punctuation is NOT classified as a mistake.
  # Returns: { "corrected": "...", "mistakes": [...] }
  local WORKING_PROMPT="$ORIGINAL_PROMPT"
  local CORRECTIONS_JSON="[]"
  local MISTAKE_NATURE_JSON="[]"
  local CORRECTED_PROMPT="$ORIGINAL_PROMPT"

  if [[ "$CORRECTION" == "true" ]]; then
    _debug "Running correction with model: $CORRECTION_MODEL"

    local CORRECTION_RESULT=""
    CORRECTION_RESULT=$(claude -p \
      --agent better-prompt:prompt-correction \
      --model "$CORRECTION_MODEL" \
      "Correct the following prompt in terms of grammar and make it clear in context. Return ONLY the raw JSON object — no markdown, no code blocks.

Prompt: $WORKING_PROMPT" 2>&1) || {
      _warn "Correction stage failed: $CORRECTION_RESULT"
      CORRECTION_RESULT=""
    }

    if [[ -n "$CORRECTION_RESULT" ]] && command -v jq &>/dev/null; then
      CORRECTION_RESULT=$(printf '%s' "$CORRECTION_RESULT" |
        sed -e 's/^```[a-zA-Z]*$//' -e 's/^```$//' -e '/^[[:space:]]*$/d' |
        tr -d '\r') # strip markdown code fences the model may add despite instructions

      local CORRECTED
      CORRECTED=$(printf '%s' "$CORRECTION_RESULT" | jq -r '.corrected // empty' 2>/dev/null || true)
      CORRECTIONS_JSON=$(printf '%s' "$CORRECTION_RESULT" | jq -c '.mistakes // []' 2>/dev/null || echo "[]")

      [[ -n "$CORRECTED" ]] && WORKING_PROMPT="$CORRECTED"

      MISTAKE_NATURE_JSON=$(printf '%s' "$CORRECTIONS_JSON" |
        jq -c '[.[].type] | unique' \
          2>/dev/null || echo "[]")
    fi
  fi

  CORRECTED_PROMPT="$WORKING_PROMPT" # snapshot before translation overwrites WORKING_PROMPT

  ###
  ### :::: Translation Stage :::: ########
  ###

  # Already-English prompts are passed through unchanged
  if [[ "$TRANSLATION" == "true" ]]; then
    _debug "Running translation with model: $TRANSLATION_MODEL"

    local TRANSLATION_RESULT=""
    TRANSLATION_RESULT=$(claude -p \
      --agent better-prompt:prompt-translation \
      --model "$TRANSLATION_MODEL" \
      "$WORKING_PROMPT" 2>&1) || {
      _warn "Translation stage failed: $TRANSLATION_RESULT"
      TRANSLATION_RESULT=""
    }

    [[ -n "$TRANSLATION_RESULT" ]] && WORKING_PROMPT="$TRANSLATION_RESULT"
  fi

  ###
  ### :::: Enhancement Stage :::: #######
  ###

  # --resume keeps a persistent session for context across invocations
  local ENHANCED_PROMPT="$WORKING_PROMPT"
  local ENHANCE_SESSION_FILE="${CLAUDE_PROJECT_DIR:-.}/.claude/.better-prompt-enhance-session"

  if [[ "$ENHANCEMENT" == "true" ]]; then
    _debug "Running enhancement with model: $ENHANCEMENT_MODEL"

    local ENHANCE_JSON=""
    ENHANCE_JSON=$(_run_enhance) || {
      # Session may have expired — retry without --resume
      if [[ -f "$ENHANCE_SESSION_FILE" ]]; then
        _debug "Resume failed, retrying without session"
        rm -f "$ENHANCE_SESSION_FILE"
        ENHANCE_JSON=$(claude -p \
          --output-format json \
          --agent better-prompt:prompt-enhancement \
          --model "$ENHANCEMENT_MODEL" \
          "Enhance the following prompt. Return ONLY the enhanced prompt text — no explanation, no preamble, no quotes.

Prompt:
$WORKING_PROMPT" 2>&1) || {
          _warn "Enhancement stage failed: $ENHANCE_JSON"
          ENHANCE_JSON=""
        }
      else
        _warn "Enhancement stage failed: $ENHANCE_JSON"
        ENHANCE_JSON=""
      fi
    }

    local ENHANCED_RESULT=""
    if [[ -n "$ENHANCE_JSON" ]] && command -v jq &>/dev/null; then
      ENHANCED_RESULT=$(printf '%s' "$ENHANCE_JSON" | jq -r '.result // empty' 2>/dev/null || true)
      local ENHANCE_SID
      ENHANCE_SID=$(printf '%s' "$ENHANCE_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)
      [[ -n "$ENHANCE_SID" ]] && _atomic_write "$ENHANCE_SESSION_FILE" "$ENHANCE_SID"
    else
      ENHANCED_RESULT="$ENHANCE_JSON"
    fi

    ENHANCED_PROMPT="$ENHANCED_RESULT"
    [[ -z "$ENHANCED_PROMPT" ]] && ENHANCED_PROMPT="$WORKING_PROMPT"
  fi

  ###
  ### :::: Audit Log :::: ###############
  ###

  if [[ "$AUDIT" == "true" ]] && command -v jq &>/dev/null; then
    mkdir -p "$(dirname "$AUDIT_LOG")"

    # Record null for disabled stages so the log reflects what actually ran
    local AUDIT_CORRECTION_MODEL="null"
    local AUDIT_ENHANCEMENT_MODEL="null"
    local AUDIT_TRANSLATION_MODEL="null"
    [[ "$CORRECTION" == "true" ]] && AUDIT_CORRECTION_MODEL="\"$CORRECTION_MODEL\""
    [[ "$ENHANCEMENT" == "true" ]] && AUDIT_ENHANCEMENT_MODEL="\"$ENHANCEMENT_MODEL\""
    [[ "$TRANSLATION" == "true" ]] && AUDIT_TRANSLATION_MODEL="\"$TRANSLATION_MODEL\""

    jq -nc \
      --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg prompt "$ORIGINAL_PROMPT" \
      --arg corrected "$CORRECTED_PROMPT" \
      --arg enhanced "$ENHANCED_PROMPT" \
      --argjson nature "$MISTAKE_NATURE_JSON" \
      --argjson mistakes "$CORRECTIONS_JSON" \
      --argjson correction_model "$AUDIT_CORRECTION_MODEL" \
      --argjson enhancement_model "$AUDIT_ENHANCEMENT_MODEL" \
      --argjson translation_model "$AUDIT_TRANSLATION_MODEL" \
      '{
              date:             $date,
              prompt:           $prompt,
              corrected:        $corrected,
              enhanced:         $enhanced,
              "mistake-nature": $nature,
              mistakes:         $mistakes,
              models: {
                  correction:   $correction_model,
                  translation:  $translation_model,
                  enhancement:  $enhancement_model
              }
          }' >>"$AUDIT_LOG"
  fi

  ###
  ### :::: Final Prompt :::: ############
  ###

  local FINAL_PROMPT="$ENHANCED_PROMPT" # last enabled stage wins: original → corrected → translated → enhanced

  # Write sentinel after FINAL_PROMPT is known so the hash is exact;
  # next invocation compares the same hash to bypass reprocessing.
  local FINAL_HASH
  FINAL_HASH=$(_md5 "$FINAL_PROMPT")
  if [[ -n "$FINAL_HASH" ]]; then
    _atomic_write "$SENTINEL" "$FINAL_HASH"
    _debug "Sentinel written: $SENTINEL (hash=$FINAL_HASH)"
  else
    _warn "Could not compute prompt hash — sentinel not written; rewind loop guard inactive"
  fi

  ###
  ### :::: Emit Hook Response :::: ######
  ###

  # Debug: block original, surface all stages in block reason.
  # Normal: block original; final prompt is on clipboard for the Stop hook to paste.
  if [[ "$DEBUG" == "true" ]]; then
    local DEBUG_MSG
    DEBUG_MSG=$(printf '[Better Prompt Debug]\nOriginal:   %s\nCorrected:  %s\nTranslated: %s\nEnhanced:   %s' \
      "$ORIGINAL_PROMPT" "$CORRECTED_PROMPT" "$WORKING_PROMPT" "$ENHANCED_PROMPT")
    local ESCAPED_DEBUG
    ESCAPED_DEBUG=$(_json_escape "$DEBUG_MSG")
    printf '{"decision": "block", "reason": %s, "suppressOutput": false}\n' "$ESCAPED_DEBUG"
  else
    printf '{"decision": "block", "reason": "Prompt replaced by better-prompt plugin.", "suppressOutput": false}\n'
  fi

  # Clipboard copy keeps the Stop-hook rewind path available where
  # additionalContext injection is unreliable
  if [[ "$_IS_MACOS" == true ]]; then
    printf '%s' "$FINAL_PROMPT" | pbcopy 2>/dev/null || true
  else
    if command -v xclip &>/dev/null; then
      printf '%s' "$FINAL_PROMPT" | xclip -selection clipboard 2>/dev/null || true
    elif command -v xsel &>/dev/null; then
      printf '%s' "$FINAL_PROMPT" | xsel --clipboard --input 2>/dev/null || true
    else
      _warn "No clipboard utility found. Install xclip or xsel."
    fi
  fi

  _debug "Original prompt blocked; final prompt copied to clipboard for rewind"

  # Detach stop-hook from this process group so it survives
  # when the hook runner kills enhance.sh on exit
  local STOP_LOG="${TMPDIR:-/tmp}/better-prompt-stop.log"
  CLAUDE_SESSION_ID="$SESSION_ID" \
    nohup bash "${PLUGIN_ROOT}/hooks/scripts/stop-hook.sh" \
    </dev/null >>"$STOP_LOG" 2>&1 &
  disown

  _debug "stop-hook.sh spawned (pid $!), log: $STOP_LOG"
  exit 0
}

###
### :::: Error Handling and Entry :::: #
###

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap 'printf "[better-prompt] Error at line %d\n" "$LINENO" >&2; exit 1' ERR
  main "$@"
fi
