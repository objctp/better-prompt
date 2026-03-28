#!/usr/bin/env bash
# hooks/scripts/stop-hook.sh
# Invoked by FileChanged hook on better-prompt-audit.json
# Reads enhanced prompt from clipboard, rewinds session, types it into TTY

set -euo pipefail

# ── Environment ────────────────────────────────────────────────────────────────
CONFIG="$HOME/.claude/better-prompt.local.md"

# Bootstrap debug
_bootstrap_debug() {
    if [ ! -f "$CONFIG" ]; then
        printf 'false'
        return
    fi
    awk '/^---$/{count++; next} count==1 && /^debug_mode:/{
		sub(/^debug_mode:[[:space:]]*/,""); sub(/#.*$/,"")
		gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit
	} count>=2{exit}' "$CONFIG"
}
DEBUG=$(_bootstrap_debug)

# Log debug message to stderr
debug() {
    if [ "$DEBUG" = "true" ]; then
        printf '[better-prompt-stop] DEBUG: %s\n' "$*" >&2
    fi
}

# Get session ID from stdin JSON input (preferred) or environment
SESSION_ID=""

# Try reading from stdin JSON input
if [ -t 0 ]; then
    SESSION_ID="${CLAUDE_SESSION_ID:-}"
else
    SESSION_ID=$(jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
    # Spawned from enhance.sh with </dev/null — stdin has no JSON, fall back to env var
    [ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-}"
fi

if [ -z "$SESSION_ID" ]; then
    debug "No session ID found, skipping rewind"
    printf '{"continue": true}\n'
    exit 0
fi

debug "Stop hook fired for session: $SESSION_ID"

# ═════════════════════════════════════════════════════════════════════════════
# Locate session PID
# ═════════════════════════════════════════════════════════════════════════════
ACTIVE_SESSIONS_DIR="$HOME/.claude/sessions"

# Find the session JSON file where sessionId matches our SESSION_ID
SESSION_PID_FILE=$(grep -l "\"sessionId\":\"$SESSION_ID\"" "$ACTIVE_SESSIONS_DIR"/*.json 2>/dev/null | head -1)

if [ ! -f "$SESSION_PID_FILE" ]; then
    debug "Session PID file not found for session: $SESSION_ID"
    printf '{"continue": true}\n'
    exit 0
fi

# Extract the 'pid' field from the JSON content
SESSION_PID=$(jq -r '.pid' "$SESSION_PID_FILE" 2>/dev/null)

if [ -z "$SESSION_PID" ] || [ "$SESSION_PID" = "null" ]; then
    debug "Failed to extract PID from session file: $SESSION_PID_FILE"
    printf '{"continue": true}\n'
    exit 0
fi

debug "Found session PID: $SESSION_PID"

# Verify process is still running
if ! kill -0 "$SESSION_PID" 2>/dev/null; then
    debug "Process $SESSION_PID not running"
    printf '{"continue": true}\n'
    exit 0
fi

# Read enhanced prompt from clipboard and write directly to TTY input buffer.
# This is more reliable than any paste keybinding, which varies by terminal emulator.
ENHANCED_PROMPT=""
if [[ "$(uname -s)" == "Darwin" ]]; then
    ENHANCED_PROMPT=$(pbpaste 2>/dev/null) || ENHANCED_PROMPT=""
else
    if command -v xclip &>/dev/null; then
        ENHANCED_PROMPT=$(xclip -selection clipboard -o 2>/dev/null) || ENHANCED_PROMPT=""
    elif command -v xsel &>/dev/null; then
        ENHANCED_PROMPT=$(xsel --clipboard --output 2>/dev/null) || ENHANCED_PROMPT=""
    fi
fi

if [[ -z "$ENHANCED_PROMPT" ]]; then
    debug "Clipboard empty — cannot inject enhanced prompt"
    printf '{"continue": true}\n'
    exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# Send rewind keyboard sequence via TTY (Linux support - reserved for future use)
# ═════════════════════════════════════════════════════════════════════════════
# # Resolve TTY
# TTY_RAW=$(ps -p "$SESSION_PID" -o tty= | tr -d ' ')
#
# if [[ -z "$TTY_RAW" ]] || [[ "$TTY_RAW" == "?" ]]; then
#     debug "Could not determine TTY for PID $SESSION_PID"
#     printf '{"continue": true}\n'
#     exit 0
# fi
#
# TTY_DEV="/dev/$TTY_RAW"
#
# if [[ ! -w "$TTY_DEV" ]]; then
#     debug "Cannot write to $TTY_DEV"
#     printf '{"continue": true}\n'
#     exit 0
# fi

# ── Wait for the block message to render before sending keystrokes ─────────────
sleep 1

debug "Sending rewind sequence via osascript"

# Trigger paste + submit via osascript — this targets the focused input correctly.
osascript <<'APPLESCRIPT'
tell application "System Events"
    keystroke "v" using command down
    delay 0.2
    key code 36
end tell
APPLESCRIPT

debug "Rewind sequence sent"

printf '{"continue": true}\n'
exit 0
