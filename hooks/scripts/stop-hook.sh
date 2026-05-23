#!/usr/bin/env bash
#
# Rewind session after prompt enhancement: reads enhanced prompt from
# clipboard and types it into the TTY so Claude receives the improved version
# Usage: stop-hook.sh < stdin-payload
#
set -euo pipefail

###
### :::: Constants and globals :::: ####
###

CONFIG="${BETTER_PROMPT_CONFIG:-$HOME/.claude/better-prompt.local.md}"
ACTIVE_SESSIONS_DIR="${BETTER_PROMPT_SESSIONS_DIR:-$HOME/.claude/sessions}"

if [[ -z "${_IS_MACOS:-}" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    _IS_MACOS=true
  else
    _IS_MACOS=false
  fi
fi

###
### :::: Private functions :::: ########
###

_bootstrap_debug() {
  if [[ ! -f "$CONFIG" ]]; then
    printf 'false'
    return 0
  fi
  awk '/^---$/{count++; next} count==1 && /^debug_mode:/{
		sub(/^debug_mode:[[:space:]]*/,""); sub(/#.*$/,"")
		gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit
	} count>=2{exit}' "$CONFIG"
  return 0
}

_debug() {
  local dbg="$1"
  shift
  if [[ "$dbg" == "true" ]]; then
    printf '[better-prompt-stop] DEBUG: %s\n' "$*" >&2
  fi
  return 0
}

###
### :::: Testable functions :::: #######
###

# Resolve session ID from stdin JSON or environment variable.
# Prints the session ID, or empty string if none found.
stop_resolve_session_id() {
  local session_id=""

  if [[ ! -t 0 ]]; then
    session_id=$(jq -r '.session_id // empty' 2>/dev/null) || session_id=""
    # Spawned from enhance.sh with </dev/null — no JSON on stdin
    [[ -z "$session_id" ]] && session_id="${CLAUDE_SESSION_ID:-}"
  else
    session_id="${CLAUDE_SESSION_ID:-}"
  fi

  printf '%s' "$session_id"
}

# Find the session PID file matching the given session ID.
# Prints the file path, or empty string if not found.
stop_find_session_pid_file() {
  local session_id="$1"
  local pid_file=""

  for f in "$ACTIVE_SESSIONS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if jq -e --arg sid "$session_id" '.sessionId == $sid' "$f" &>/dev/null; then
      pid_file="$f"
      break
    fi
  done

  printf '%s' "$pid_file"
}

# Extract the PID from a session PID file.
# Prints the PID, or empty string if extraction fails.
stop_extract_pid() {
  local pid_file="$1"

  if [[ -z "$pid_file" ]] || [[ ! -f "$pid_file" ]]; then
    printf ''
    return 0
  fi

  local pid
  pid=$(jq -r '.pid' "$pid_file" 2>/dev/null) || pid=""

  if [[ -z "$pid" ]] || [[ "$pid" == "null" ]]; then
    printf ''
  else
    printf '%s' "$pid"
  fi
}

# Check whether a process is running.
# Returns 0 if running, 1 otherwise.
stop_is_process_running() {
  kill -0 "$1" 2>/dev/null
}

# Read the clipboard content. Prints the content or empty string.
stop_read_clipboard() {
  local content=""

  if [[ "$_IS_MACOS" == true ]]; then
    content=$(pbpaste 2>/dev/null) || content=""
  else
    if command -v xclip &>/dev/null; then
      content=$(xclip -selection clipboard -o 2>/dev/null) || content=""
    elif command -v xsel &>/dev/null; then
      content=$(xsel --clipboard --output 2>/dev/null) || content=""
    fi
  fi

  printf '%s' "$content"
}

# Send the Cmd+V + Enter keystroke sequence to inject the enhanced prompt.
# Returns 0 on success, 1 if the required tool is unavailable or execution fails.
stop_send_rewind_sequence() {
  local debug="$1"

  sleep 1

  if [[ "$_IS_MACOS" == true ]]; then
    if ! command -v osascript &>/dev/null; then
      _debug "$debug" "osascript not found — cannot send keystrokes on macOS"
      return 1
    fi
    _debug "$debug" "Sending rewind sequence via osascript"
    osascript <<'APPLESCRIPT'
tell application "System Events"
    keystroke "v" using command down
    delay 0.2
    key code 36
end tell
APPLESCRIPT
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      _debug "$debug" "osascript failed with exit code $rc"
      return 1
    fi
  else
    if command -v ydotool &>/dev/null; then
      _debug "$debug" "Sending rewind sequence via ydotool"
      if ! ydotool key 29:1 47:1 47:0 29:0 2>/dev/null; then
        _debug "$debug" "ydotool Ctrl+V failed"
        return 1
      fi
      sleep 0.2
      if ! ydotool key 28:1 28:0 2>/dev/null; then
        _debug "$debug" "ydotool Enter failed"
        return 1
      fi
    else
      _debug "$debug" "ydotool not found — cannot inject enhanced prompt on Linux"
      return 1
    fi
  fi

  _debug "$debug" "Rewind sequence sent"
  return 0
}

# Check whether the stop hook should skip rewind because prerequisite checks fail.
# Prints the skip reason string (non-empty) if the hook should pass through.
# Prints empty string if rewind should proceed.
stop_check_prerequisites() {
  local debug="$1"
  local session_id="$2"

  if [[ -z "$session_id" ]]; then
    _debug "$debug" "No session ID found, skipping rewind"
    printf 'no_session'
    return 0
  fi

  _debug "$debug" "Stop hook fired for session: $session_id"

  local session_pid_file
  session_pid_file=$(stop_find_session_pid_file "$session_id")

  if [[ -z "$session_pid_file" ]] || [[ ! -f "$session_pid_file" ]]; then
    _debug "$debug" "Session PID file not found for session: $session_id"
    printf 'no_pid_file'
    return 0
  fi

  local session_pid
  session_pid=$(stop_extract_pid "$session_pid_file")

  if [[ -z "$session_pid" ]]; then
    _debug "$debug" "Failed to extract PID from session file: $session_pid_file"
    printf 'no_pid'
    return 0
  fi

  _debug "$debug" "Found session PID: $session_pid"

  if ! stop_is_process_running "$session_pid"; then
    _debug "$debug" "Process $session_pid not running"
    printf 'process_dead'
    return 0
  fi

  printf ''
}

# Attempt the rewind: read clipboard and send the keystroke sequence.
# Sets REWIND_RESULT global to the skip reason (non-empty) or empty on success.
stop_attempt_rewind() {
  local debug="$1"

  CLIPBOARD_CONTENT=$(stop_read_clipboard)

  if [[ -z "$CLIPBOARD_CONTENT" ]]; then
    _debug "$debug" "Clipboard empty — cannot inject enhanced prompt"
    REWIND_RESULT="clipboard_empty"
    return 0
  fi

  if ! stop_send_rewind_sequence "$debug"; then
    REWIND_RESULT="rewind_failed"
    return 0
  fi

  REWIND_RESULT=""
}

###
### :::: Main :::: #####################
###

main() {
  local DEBUG
  DEBUG=$(_bootstrap_debug)

  local SESSION_ID
  SESSION_ID=$(stop_resolve_session_id)

  local SKIP_REASON
  SKIP_REASON=$(stop_check_prerequisites "$DEBUG" "$SESSION_ID")
  if [[ -n "$SKIP_REASON" ]]; then
    printf '{"continue": true}\n'
    exit 0
  fi

  stop_attempt_rewind "$DEBUG"
  if [[ -n "$REWIND_RESULT" ]]; then
    printf '{"continue": true}\n'
    exit 0
  fi

  printf '{"continue": true}\n'
  exit 0
}

###
### :::: Error handling and entry :::: ##
###

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap 'printf "[better-prompt-stop] Error at line %d\n" "$LINENO" >&2; exit 1' ERR
  main "$@"
fi
