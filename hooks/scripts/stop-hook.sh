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
### :::: Main :::: #####################
###

main() {
  local DEBUG
  DEBUG=$(_bootstrap_debug)

  local SESSION_ID="" # stdin JSON → env var fallback

  if [[ -t 0 ]]; then
    SESSION_ID="${CLAUDE_SESSION_ID:-}"
  else
    SESSION_ID=$(jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
    # Spawned from enhance.sh with </dev/null — no JSON on stdin
    [[ -z "$SESSION_ID" ]] && SESSION_ID="${CLAUDE_SESSION_ID:-}"
  fi

  if [[ -z "$SESSION_ID" ]]; then
    _debug "$DEBUG" "No session ID found, skipping rewind"
    printf '{"continue": true}\n'
    exit 0
  fi

  _debug "$DEBUG" "Stop hook fired for session: $SESSION_ID"

  ###
  ### :::: Locate session PID :::: ######
  ###

  # Use jq for reliable JSON matching — avoids false misses from whitespace/quoting variations
  local SESSION_PID_FILE=""
  for f in "$ACTIVE_SESSIONS_DIR"/*.json; do
    [[ -f "$f" ]] || continue # glob may not match any files
    if jq -e --arg sid "$SESSION_ID" '.sessionId == $sid' "$f" &>/dev/null; then
      SESSION_PID_FILE="$f"
      break
    fi
  done

  if [[ -z "$SESSION_PID_FILE" ]] || [[ ! -f "$SESSION_PID_FILE" ]]; then
    _debug "$DEBUG" "Session PID file not found for session: $SESSION_ID"
    printf '{"continue": true}\n'
    exit 0
  fi

  local SESSION_PID=""
  SESSION_PID=$(jq -r '.pid' "$SESSION_PID_FILE" 2>/dev/null) || SESSION_PID=""

  if [[ -z "$SESSION_PID" ]] || [[ "$SESSION_PID" == "null" ]]; then
    _debug "$DEBUG" "Failed to extract PID from session file: $SESSION_PID_FILE"
    printf '{"continue": true}\n'
    exit 0
  fi

  _debug "$DEBUG" "Found session PID: $SESSION_PID"

  if ! kill -0 "$SESSION_PID" 2>/dev/null; then
    _debug "$DEBUG" "Process $SESSION_PID not running"
    printf '{"continue": true}\n'
    exit 0
  fi

  ###
  ### :::: Read clipboard :::: ##########
  ###

  # Clipboard carries the enhanced prompt from enhance.sh; this is more
  # reliable than paste keybindings, which vary by terminal emulator.
  local ENHANCED_PROMPT=""
  if [[ "$_IS_MACOS" == true ]]; then
    ENHANCED_PROMPT=$(pbpaste 2>/dev/null) || ENHANCED_PROMPT=""
  else
    if command -v xclip &>/dev/null; then
      ENHANCED_PROMPT=$(xclip -selection clipboard -o 2>/dev/null) || ENHANCED_PROMPT=""
    elif command -v xsel &>/dev/null; then
      ENHANCED_PROMPT=$(xsel --clipboard --output 2>/dev/null) || ENHANCED_PROMPT=""
    fi
  fi

  if [[ -z "$ENHANCED_PROMPT" ]]; then
    _debug "$DEBUG" "Clipboard empty — cannot inject enhanced prompt"
    printf '{"continue": true}\n'
    exit 0
  fi

  ###
  ### :::: Send rewind sequence :::: ####
  ###

  sleep 1 # wait for block message to render before sending keystrokes

  if [[ "$_IS_MACOS" == true ]]; then
    if ! command -v osascript &>/dev/null; then
      _debug "$DEBUG" "osascript not found — cannot send keystrokes on macOS"
      printf '{"continue": true}\n'
      exit 0
    fi
    _debug "$DEBUG" "Sending rewind sequence via osascript"

    osascript <<'APPLESCRIPT'
tell application "System Events"
    keystroke "v" using command down
    delay 0.2
    key code 36
end tell
APPLESCRIPT
  else
    if command -v ydotool &>/dev/null; then
      _debug "$DEBUG" "Sending rewind sequence via ydotool"
      # Linux kernel key codes: 29=left ctrl, 47=v, 28=enter; state: 1=press, 0=release
      ydotool key 29:1 47:1 47:0 29:0
      sleep 0.2
      ydotool key 28:1 28:0
    else
      _debug "$DEBUG" "ydotool not found — cannot inject enhanced prompt on Linux"
      printf '{"continue": true}\n'
      exit 0
    fi
  fi

  _debug "$DEBUG" "Rewind sequence sent"

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
