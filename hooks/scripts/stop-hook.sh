#!/usr/bin/env bash
#
# Rewind session after prompt enhancement: reads enhanced prompt from
# clipboard and types it into the TTY so Claude receives the improved version
# Usage: stop-hook.sh < stdin-payload
#
set -euo pipefail

CONFIG="${BETTER_PROMPT_CONFIG:-$HOME/.claude/better-prompt.local.md}"
ACTIVE_SESSIONS_DIR="${BETTER_PROMPT_SESSIONS_DIR:-$HOME/.claude/sessions}"
readonly CONFIG ACTIVE_SESSIONS_DIR

# shellcheck source=lib/config.sh
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/hooks/scripts/lib/config.sh"

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

_debug() {
  local dbg="$1"
  shift
  if [[ "$dbg" == "true" ]]; then
    printf '[better-prompt-stop] DEBUG: %s\n' "$*" >&2
  fi
  return 0
}

###
### :::: Public Functions :::: #########
###

stop::resolve_session_id() {
  local session_id=""

  if [[ ! -t 0 ]]; then
    session_id=$(jq -r '.session_id // empty' 2>/dev/null) || session_id=""
    # Spawned from enhance.sh with </dev/null — no JSON on stdin
    [[ -z "$session_id" ]] && session_id="${CLAUDE_SESSION_ID:-}"
  else
    session_id="${CLAUDE_SESSION_ID:-}"
  fi

  printf '%s' "$session_id"
  return 0
}

stop::find_session_pid_file() {
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
  return 0
}

stop::find_active_cli_session() {
  local project_dir="${CLAUDE_PROJECT_DIR:-}"
  local pid_file=""

  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    local entrypoint cwd pid
    entrypoint=$(jq -r '.entrypoint // empty' "$f" 2>/dev/null) || continue
    [[ "$entrypoint" == "cli" ]] || continue
    if [[ -n "$project_dir" ]]; then
      cwd=$(jq -r '.cwd // empty' "$f" 2>/dev/null) || continue
      [[ "$cwd" == "$project_dir" ]] || continue
    fi
    pid=$(jq -r '.pid // empty' "$f" 2>/dev/null) || continue
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      pid_file="$f"
      break
    fi
  done < <(ls -t "$ACTIVE_SESSIONS_DIR"/*.json 2>/dev/null)

  printf '%s' "$pid_file"
  return 0
}

stop::extract_pid() {
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
  return 0
}

stop::is_process_running() {
  kill -0 "$1" 2>/dev/null
}

stop::read_clipboard() {
  local content=""

  if [[ "$IS_MACOS" == true ]]; then
    content=$(pbpaste 2>/dev/null) || content=""
  else
    if command -v xclip &>/dev/null; then
      content=$(xclip -selection clipboard -o 2>/dev/null) || content=""
    elif command -v xsel &>/dev/null; then
      content=$(xsel --clipboard --output 2>/dev/null) || content=""
    fi
  fi

  printf '%s' "$content"
  return 0
}

stop::send_rewind_sequence() {
  local debug="$1"
  local session_pid="$2"

  # Re-verify session is still alive before injecting keystrokes
  if [[ -n "$session_pid" ]] && ! stop::is_process_running "$session_pid"; then
    _debug "$debug" "Session $session_pid died before rewind — aborting keystroke injection"
    return 1
  fi

  sleep 1

  if [[ "$IS_MACOS" == true ]]; then
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

stop::check_prerequisites() {
  local debug="$1"
  local session_id="$2"

  if [[ -z "$session_id" ]]; then
    _debug "$debug" "No session ID found, skipping rewind"
    printf 'no_session'
    return 0
  fi

  _debug "$debug" "Stop hook fired for session: $session_id"

  local session_pid_file
  session_pid_file=$(stop::find_session_pid_file "$session_id")

  if [[ -z "$session_pid_file" ]] || [[ ! -f "$session_pid_file" ]]; then
    _debug "$debug" "Session PID file not found for session: $session_id, trying active CLI session fallback"
    session_pid_file=$(stop::find_active_cli_session)
    if [[ -z "$session_pid_file" ]] || [[ ! -f "$session_pid_file" ]]; then
      _debug "$debug" "No active CLI session found either"
      printf 'no_pid_file'
      return 0
    fi
  fi

  local session_pid
  session_pid=$(stop::extract_pid "$session_pid_file")

  if [[ -z "$session_pid" ]]; then
    _debug "$debug" "Failed to extract PID from session file: $session_pid_file"
    printf 'no_pid'
    return 0
  fi

  _debug "$debug" "Found session PID: $session_pid"

  if ! stop::is_process_running "$session_pid"; then
    _debug "$debug" "Process $session_pid not running"
    printf 'process_dead'
    return 0
  fi

  # Print the session PID on success — caller uses it for liveness checks
  printf '%s' "$session_pid"
}

# Side effects: sets REWIND_RESULT global — empty on success, "clipboard_empty" or
# "rewind_failed" on failure. Reads system clipboard and sends keystrokes.
# Arguments:
#   $1 - debug: "true"/"false" for debug output
#   $2 - session_pid: PID of the Claude session (for liveness check)
stop::attempt_rewind() {
  local debug="$1"
  local session_pid="$2"

  CLIPBOARD_CONTENT=$(stop::read_clipboard)

  if [[ -z "$CLIPBOARD_CONTENT" ]]; then
    _debug "$debug" "Clipboard empty — cannot inject enhanced prompt"
    _debug "$debug" "The enhanced prompt was included in the block reason; check the Claude response above."
    REWIND_RESULT="clipboard_empty"
    return 0
  fi

  if ! stop::send_rewind_sequence "$debug" "$session_pid"; then
    _debug "$debug" "Rewind keystroke injection failed — the enhanced prompt was included in the block reason"
    REWIND_RESULT="rewind_failed"
    return 0
  fi

  _debug "$debug" "Rewind completed — enhanced prompt submitted via paste"
  REWIND_RESULT=""
}

###
### :::: Main :::: #####################
###

_stop_cleanup() {
  local pid_file="${CLAUDE_PROJECT_DIR:-.}/.claude/better-prompt/.stop-pid"
  rm -f "$pid_file" 2>/dev/null
  return 0
}

main() {
  trap _stop_cleanup EXIT

  local VERBOSE
  VERBOSE=$(_config_read_single "$CONFIG" "verbose" "false")

  local SESSION_ID
  SESSION_ID=$(stop::resolve_session_id)

  local CHECK_RESULT
  CHECK_RESULT=$(stop::check_prerequisites "$VERBOSE" "$SESSION_ID")
  if [[ "$CHECK_RESULT" == "no_session" ]] || [[ "$CHECK_RESULT" == "no_pid_file" ]] || [[ "$CHECK_RESULT" == "no_pid" ]] || [[ "$CHECK_RESULT" == "process_dead" ]]; then
    printf '{"continue": true}\n'
    exit 0
  fi

  local SESSION_PID="$CHECK_RESULT"
  stop::attempt_rewind "$VERBOSE" "$SESSION_PID"
  if [[ -n "$REWIND_RESULT" ]]; then
    printf '{"continue": true}\n'
    exit 0
  fi

  printf '{"continue": true}\n'
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap 'printf "[better-prompt-stop] Error at line %d\n" "$LINENO" >&2; exit 1' ERR
  main "$@"
fi
