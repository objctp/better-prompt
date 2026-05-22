#!/usr/bin/env bash
# hooks/scripts/enhance.sh
# Invoked by UserPromptSubmit hook (type: command)
# Reads ~/.claude/better-prompt.local.md for all settings

set -euo pipefail

# ── Read stdin payload immediately — must happen before any subshell consumes it ──
# UserPromptSubmit delivers: { "prompt": "...", "session_id": "...", ... }
STDIN_PAYLOAD=""
if [ ! -t 0 ]; then
  STDIN_PAYLOAD=$(cat)
fi

# ── Early environment (needed by helpers before config is fully parsed) ───────
ORIGINAL_PROMPT=$(printf '%s' "$STDIN_PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null || true)
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
CONFIG="$HOME/.claude/better-prompt.local.md"

# Bootstrap DEBUG from config immediately so debug() works from the first call.
# Full config parsing happens in section 1; this is a lightweight early read.
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

# ═════════════════════════════════════════════════════════════════════════════
# 0. Helper functions
# ═════════════════════════════════════════════════════════════════════════════

# Log warning to stderr
warn() {
  printf '[better-prompt] WARNING: %s\n' "$*" >&2
}

# Log debug message to stderr (only when DEBUG=true)
debug() {
  if [ "$DEBUG" = "true" ]; then
    printf '[better-prompt] DEBUG: %s\n' "$*" >&2
  fi
}

# Properly escape string for JSON using jq
json_escape() {
  if command -v jq &>/dev/null; then
    printf '%s' "$1" | jq -Rs .
  else
    # Fallback: minimal escaping if jq unavailable
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
  fi
}

# Detect OS type for platform-specific commands
if [[ "$(uname -s)" == "Darwin" ]]; then
  _IS_MACOS=true
else
  _IS_MACOS=false
fi

# ── Sentinel path — project-scoped, session-ID-independent ───────────────────
# Set here so any early-exit trap can clean up if needed.
# The actual sentinel file stores the hash of the enhanced prompt; it is
# written in section 7.5 (after FINAL_PROMPT is known) and checked below.
SENTINEL="${CLAUDE_PROJECT_DIR:-.}/.claude/.better-prompt-sentinel"

# ═════════════════════════════════════════════════════════════════════════════
# 1. Parse config
# Reads a key from the YAML frontmatter of better-prompt.local.md.
# Strips inline comments (# ...) and surrounding whitespace.
# Falls back to $2 (default) if the file or key is missing.
# ═════════════════════════════════════════════════════════════════════════════
get_setting() {
  local key="$1"
  local default="$2"

  if [ ! -f "$CONFIG" ]; then
    printf '%s' "$default"
    return
  fi

  local value
  value=$(awk -v key="$key" '
        /^---$/ { count++; next }
        count == 1 {
            if (match($0, "^" key ":")) {
                sub("^" key ":[[:space:]]*", "")
                sub(/#.*$/, "")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                print
                exit
            }
        }
        count >= 2 { exit }
    ' "$CONFIG")

  printf '%s' "${value:-$default}"
}

ENABLED=$(get_setting "enabled" "true")
CORRECTION=$(get_setting "correction" "true")
CORRECTION_MODEL=$(get_setting "correction_model" "haiku")
ENHANCEMENT=$(get_setting "enhancement" "false")
ENHANCEMENT_MODEL=$(get_setting "enhancement_model" "sonnet")
TRANSLATION=$(get_setting "translation" "false")
TRANSLATION_MODEL=$(get_setting "translation_model" "haiku")
AUDIT=$(get_setting "audit" "true")
DEBUG=$(get_setting "debug_mode" "false")
AUDIT_LOG="${CLAUDE_PROJECT_DIR:-.}/.claude/prompts.json"

# ═════════════════════════════════════════════════════════════════════════════
# 2. Global kill switch
# ═════════════════════════════════════════════════════════════════════════════
if [ "$ENABLED" = "false" ]; then
  printf '{"continue": true}\n'
  exit 0
fi

# ── Resolve session ID ────────────────────────────────────────────────────────
# Try stdin JSON input first, then env var, then most recent session-env entry
# Validate session ID format (UUID-like pattern)
SESSION_ID=""

# Parse session_id from the stdin payload captured at startup
if [ -n "$STDIN_PAYLOAD" ] && command -v jq &>/dev/null; then
  SESSION_ID=$(printf '%s' "$STDIN_PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
fi

# Fall back to environment variable
if [ -z "$SESSION_ID" ] && [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  SESSION_ID="$CLAUDE_SESSION_ID"
fi

# Fall back to finding most recent session file
if [ -z "$SESSION_ID" ]; then
  SESSION_DIR="$HOME/.claude/session-env/"
  if [ -d "$SESSION_DIR" ]; then
    if [ "$_IS_MACOS" = true ]; then
      # macOS/BSD: stat -f '%m %N' gives mtime + full path; extract filename only
      SESSION_ID=$(find "$SESSION_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -f '%m %N' {} \; 2>/dev/null |
        sort -rn | head -1 | awk '{print $NF}' | xargs basename) || {
        warn "Failed to find session ID on macOS"
        SESSION_ID=""
      }
    else
      # GNU find: use -printf for efficiency
      SESSION_ID=$(find "$SESSION_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null |
        sort -rn | head -1 | cut -d' ' -f2-) || {
        warn "Failed to find session ID"
        SESSION_ID=""
      }
    fi
  fi
fi

# Validate session ID (basic sanity check - alphanumeric with dashes/underscores)
if [ -n "$SESSION_ID" ]; then
  if ! [[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    warn "Invalid session ID format: $SESSION_ID"
    SESSION_ID=""
  fi
fi

# ── Bail early if nothing to process ─────────────────────────────────────────
if [ -z "$ORIGINAL_PROMPT" ] || [ -z "$SESSION_ID" ]; then
  printf '{"continue": true}\n'
  exit 0
fi

# ── Skip slash commands, @ mentions, and ! shell commands ────────────────────────────
# These are Claude Code UI directives, not natural-language prompts.
if [[ "$ORIGINAL_PROMPT" =~ ^[/!] ]]; then
  printf '{"continue": true}\n'
  exit 0
fi

# ── Sentinel: pass through our own re-fired enhanced prompt ──────────────────
# The sentinel is a project-scoped file whose CONTENT is the md5 hash of the
# enhanced prompt.  Keying on content (not session ID) means the guard survives
# conversation rewinds, which cause Claude Code to issue a fresh session ID for
# the subsequent UserPromptSubmit event — the original session-keyed sentinel
# was invisible to that new ID, allowing the loop to occur.
#
# Flow:
#   first run  → hash of ENHANCED_PROMPT written to $SENTINEL  (section 7.5)
#   second run → hash of incoming prompt compared to stored hash → bypass if match

# Portable md5: macOS `md5` prints just the digest; GNU `md5sum` appends filename.
_md5() { md5 2>/dev/null <<<"$1" || printf '%s' "$1" | md5sum 2>/dev/null | cut -c1-32; }

if [ -f "$SENTINEL" ]; then
  SENTINEL_AGE=$(($(date +%s) - $(stat -f '%m' "$SENTINEL" 2>/dev/null ||
    stat -c '%Y' "$SENTINEL" 2>/dev/null || echo 0)))
  if [ "$SENTINEL_AGE" -lt 60 ]; then
    STORED_HASH=$(cat "$SENTINEL" 2>/dev/null || echo "")
    INCOMING_HASH=$(_md5 "$ORIGINAL_PROMPT")
    if [ -n "$STORED_HASH" ] && [ "$INCOMING_HASH" = "$STORED_HASH" ]; then
      debug "Sentinel matched (${SENTINEL_AGE}s old, hash=${INCOMING_HASH}) — passing re-fired prompt through"
      rm -f "$SENTINEL"
      printf '{"continue": true}\n'
      exit 0
    else
      debug "Sentinel present but hash mismatch — new prompt, proceeding (stored=${STORED_HASH:-empty}, incoming=${INCOMING_HASH})"
    fi
  else
    debug "Stale sentinel (${SENTINEL_AGE}s old) — removing"
    rm -f "$SENTINEL"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 3. Correction stage
# Fixes grammar and spelling only. Punctuation is NOT classified as a mistake.
# Returns JSON: { "corrected": "...", "mistakes": [...] }
# ═════════════════════════════════════════════════════════════════════════════
WORKING_PROMPT="$ORIGINAL_PROMPT"
CORRECTIONS_JSON="[]"
MISTAKE_NATURE_JSON="[]"

if [ "$CORRECTION" = "true" ]; then
  debug "Running correction with model: $CORRECTION_MODEL"

  CORRECTION_RESULT=$(claude -p \
    --agent better-prompt:prompt-correction \
    --model "$CORRECTION_MODEL" \
    "Correct the following prompt in terms of grammar and make it clear in context. Return ONLY the raw JSON object — no markdown, no code blocks.

Prompt: $WORKING_PROMPT" 2>&1) || {
    warn "Correction stage failed: $CORRECTION_RESULT"
    CORRECTION_RESULT=""
  }

  if [ -n "$CORRECTION_RESULT" ] && command -v jq &>/dev/null; then
    # Strip markdown code fences if the model wrapped its output despite instructions
    CORRECTION_RESULT=$(printf '%s' "$CORRECTION_RESULT" | sed 's/^```[a-zA-Z]*$//' | sed 's/^```$//' | sed '/^[[:space:]]*$/d' | tr -d '\r')

    CORRECTED=$(printf '%s' "$CORRECTION_RESULT" | jq -r '.corrected // empty' 2>/dev/null || true)
    CORRECTIONS_JSON=$(printf '%s' "$CORRECTION_RESULT" | jq -c '.mistakes // []' 2>/dev/null || echo "[]")

    [ -n "$CORRECTED" ] && WORKING_PROMPT="$CORRECTED"

    # Build mistake-nature: unique types from whatever the agent classified
    MISTAKE_NATURE_JSON=$(printf '%s' "$CORRECTIONS_JSON" |
      jq -c '[.[].type] | unique' \
        2>/dev/null || echo "[]")
  fi
fi

# Snapshot post-correction state before translation may overwrite WORKING_PROMPT.
CORRECTED_PROMPT="$WORKING_PROMPT"

# ═════════════════════════════════════════════════════════════════════════════
# 4. Translation stage
# Translates non-English prompts to English. If the prompt is already in
# English, the agent passes it through unchanged. Returns plain text only.
# ═════════════════════════════════════════════════════════════════════════════
if [ "$TRANSLATION" = "true" ]; then
  debug "Running translation with model: $TRANSLATION_MODEL"

  TRANSLATION_RESULT=$(claude -p \
    --agent better-prompt:prompt-translation \
    --model "$TRANSLATION_MODEL" \
    "$WORKING_PROMPT" 2>&1) || {
    warn "Translation stage failed: $TRANSLATION_RESULT"
    TRANSLATION_RESULT=""
  }

  [ -n "$TRANSLATION_RESULT" ] && WORKING_PROMPT="$TRANSLATION_RESULT"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 5. Enhancement stage
# Uses --resume to maintain a persistent session so the model sees
# previously enhanced prompts as context — without needing the user's
# original conversation history.
# ═════════════════════════════════════════════════════════════════════════════
ENHANCED_PROMPT="$WORKING_PROMPT"
ENHANCE_SESSION_FILE="${CLAUDE_PROJECT_DIR:-.}/.claude/.better-prompt-enhance-session"

if [ "$ENHANCEMENT" = "true" ]; then
  debug "Running enhancement with model: $ENHANCEMENT_MODEL"

  _run_enhance() {
    local resume_args=()
    if [ -f "$ENHANCE_SESSION_FILE" ]; then
      local stored_id
      stored_id=$(cat "$ENHANCE_SESSION_FILE" 2>/dev/null || true)
      if [ -n "$stored_id" ]; then
        resume_args=(--resume "$stored_id")
        debug "Resuming enhancement session: $stored_id"
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
  }

  ENHANCE_JSON=$(_run_enhance) || {
    # Resume failed — session may have expired. Retry without --resume.
    if [ -f "$ENHANCE_SESSION_FILE" ]; then
      debug "Resume failed, retrying without session"
      rm -f "$ENHANCE_SESSION_FILE"
      ENHANCE_JSON=$(claude -p \
        --output-format json \
        --agent better-prompt:prompt-enhancement \
        --model "$ENHANCEMENT_MODEL" \
        "Enhance the following prompt. Return ONLY the enhanced prompt text — no explanation, no preamble, no quotes.

Prompt:
$WORKING_PROMPT" 2>&1) || {
        warn "Enhancement stage failed: $ENHANCE_JSON"
        ENHANCE_JSON=""
      }
    else
      warn "Enhancement stage failed: $ENHANCE_JSON"
      ENHANCE_JSON=""
    fi
  }

  if [ -n "$ENHANCE_JSON" ] && command -v jq &>/dev/null; then
    ENHANCED_RESULT=$(printf '%s' "$ENHANCE_JSON" | jq -r '.result // empty' 2>/dev/null || true)
    ENHANCE_SID=$(printf '%s' "$ENHANCE_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)
    [ -n "$ENHANCE_SID" ] && printf '%s' "$ENHANCE_SID" >"$ENHANCE_SESSION_FILE"
  else
    ENHANCED_RESULT="$ENHANCE_JSON"
  fi

  ENHANCED_PROMPT="$ENHANCED_RESULT"
  [ -z "$ENHANCED_PROMPT" ] && ENHANCED_PROMPT="$WORKING_PROMPT"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 6. Audit log
# Appends one NDJSON line per invocation to the configured path.
# Runs before output so the record exists even if the output step fails.
# ═════════════════════════════════════════════════════════════════════════════
if [ "$AUDIT" = "true" ] && command -v jq &>/dev/null; then
  mkdir -p "$(dirname "$AUDIT_LOG")"

  # Record null for a model when its stage was disabled, so the log
  # accurately reflects what actually ran rather than what is configured.
  AUDIT_CORRECTION_MODEL="null"
  AUDIT_ENHANCEMENT_MODEL="null"
  AUDIT_TRANSLATION_MODEL="null"
  [ "$CORRECTION" = "true" ] && AUDIT_CORRECTION_MODEL="\"$CORRECTION_MODEL\""
  [ "$ENHANCEMENT" = "true" ] && AUDIT_ENHANCEMENT_MODEL="\"$ENHANCEMENT_MODEL\""
  [ "$TRANSLATION" = "true" ] && AUDIT_TRANSLATION_MODEL="\"$TRANSLATION_MODEL\""

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

# ═════════════════════════════════════════════════════════════════════════════
# 7. Determine final prompt
# The final prompt is the last enabled stage's output, in order:
#   original → corrected → translated → enhanced
# ═════════════════════════════════════════════════════════════════════════════
FINAL_PROMPT="$ENHANCED_PROMPT"

# ═════════════════════════════════════════════════════════════════════════════
# 7.5 Write content-hash sentinel
# Done here — after FINAL_PROMPT is known — so the stored hash is exact.
# The next UserPromptSubmit invocation computes the same hash from the incoming
# prompt text and bypasses reprocessing on a match.
# ═════════════════════════════════════════════════════════════════════════════
FINAL_HASH=$(_md5 "$FINAL_PROMPT")
if [ -n "$FINAL_HASH" ]; then
  printf '%s' "$FINAL_HASH" >"$SENTINEL"
  debug "Sentinel written: $SENTINEL (hash=$FINAL_HASH)"
else
  warn "Could not compute prompt hash — sentinel not written; rewind loop guard inactive"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 8. Emit hook response
#
# Debug mode: block the original prompt and surface all three pipeline stages
#             via the block reason so nothing reaches Claude.
#
# Normal mode: block the original prompt. Final processed prompt goes to clipboard;
#              Stop hook rewinds and pastes it so Claude receives the improved version.
# ═════════════════════════════════════════════════════════════════════════════
if [ "$DEBUG" = "true" ]; then
  DEBUG_MSG=$(printf '[Better Prompt Debug]\nOriginal:   %s\nCorrected:  %s\nTranslated: %s\nEnhanced:   %s' \
    "$ORIGINAL_PROMPT" "$CORRECTED_PROMPT" "$WORKING_PROMPT" "$ENHANCED_PROMPT")
  ESCAPED_DEBUG=$(json_escape "$DEBUG_MSG")
  printf '{"decision": "block", "reason": %s, "suppressOutput": false}\n' "$ESCAPED_DEBUG"
else
  # Block the original prompt. The final processed prompt is on the clipboard;
  # the Stop hook will rewind and paste it so Claude receives the improved version.
  printf '{"decision": "block", "reason": "Prompt replaced by better-prompt plugin.", "suppressOutput": false}\n'
fi

# Also copy to clipboard so the Stop hook rewind path remains available
# as a fallback for terminals where additionalContext injection is unreliable.
if [ "$_IS_MACOS" = true ]; then
  printf '%s' "$FINAL_PROMPT" | pbcopy 2>/dev/null || true
else
  if command -v xclip &>/dev/null; then
    printf '%s' "$FINAL_PROMPT" | xclip -selection clipboard 2>/dev/null || true
  elif command -v xsel &>/dev/null; then
    printf '%s' "$FINAL_PROMPT" | xsel --clipboard --input 2>/dev/null || true
  else
    warn "No clipboard utility found. Install xclip or xsel."
  fi
fi

debug "Original prompt blocked; final prompt copied to clipboard for rewind"

# Detach stop-hook.sh fully from this process group so it survives
# when Claude Code's hook runner kills enhance.sh on exit.
STOP_LOG="/tmp/better-prompt-stop.log"
CLAUDE_SESSION_ID="$SESSION_ID" \
  nohup bash "${PLUGIN_ROOT}/hooks/scripts/stop-hook.sh" \
  </dev/null >>"$STOP_LOG" 2>&1 &
disown

debug "stop-hook.sh spawned (pid $!), log: $STOP_LOG"
exit 0
