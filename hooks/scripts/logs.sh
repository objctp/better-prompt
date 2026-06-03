#!/usr/bin/env bash
#
# Display/clear better-prompt audit logs via UserPromptExpansion hook.
# Intercepts /better-prompt:logs and executes directly,
# without LLM processing.
#
# Usage: logs.sh < stdin-payload
#
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
CONFIG="${BETTER_PROMPT_CONFIG:-$HOME/.claude/better-prompt.local.md}"
# shellcheck disable=SC2034
readonly PLUGIN_ROOT CONFIG

# shellcheck source=lib/common.sh
source "${PLUGIN_ROOT}/hooks/scripts/lib/common.sh"

###
### :::: Public Functions :::: #########
###

# Resolve the audit log path from CLAUDE_PROJECT_DIR.
logs::audit_path() {
  local project_dir="${CLAUDE_PROJECT_DIR:-.}"
  printf '%s/.claude/better-prompt/audit.json' "$project_dir"
  return 0
}

# Format a single audit entry from a JSON line.
logs::format_entry() {
  local entry="$1"
  local index="$2"

  # Single jq pass: extract all display fields in one invocation (was 6 separate jq calls).
  # Uses unit separator (ASCII 31) as delimiter — safe for natural language text.
  local parsed
  parsed=$(jq -r --arg sep $'\x1f' '
    [
      .date // "unknown",
      .prompt // "",
      .corrected // "",
      .enhanced // "",
      (."mistake-nature" // [] | if type == "array" then join(", ") else . end),
      (.models // {} | to_entries | map(select(.value != null)) | map("\(.key)=\(.value)") | join(", ")),
      (.mistakes // [] | if type == "array" then map("\(.type): \"\(.original)\" -> \"\(.correction)\"") | join("; ") else . end)
    ] | join($sep)
  ' <<<"$entry" 2>/dev/null) || parsed=""

  if [[ -z "$parsed" ]]; then
    printf 'Entry #%s\n%s\n' "$index" "$entry"
    return 0
  fi

  local date prompt corrected enhanced nature models mistakes
  IFS=$'\x1f' read -r date prompt corrected enhanced nature models mistakes <<<"$parsed"

  printf 'Entry #%s\n' "$index"
  printf 'Date:      %s\n' "$date"
  printf 'Prompt:    "%s"\n' "$prompt"
  if [[ -n "$corrected" && "$corrected" != "$prompt" ]]; then
    printf 'Corrected: "%s"\n' "$corrected"
  fi
  if [[ -n "$enhanced" && "$enhanced" != "$corrected" ]]; then
    printf 'Enhanced:  "%s"\n' "$enhanced"
  fi
  if [[ -n "$nature" && "$nature" != "null" && "$nature" != "" ]]; then
    printf 'Mistakes:  %s\n' "$nature"
  fi
  if [[ -n "$mistakes" && "$mistakes" != "null" && "$mistakes" != "" ]]; then
    printf '  %s\n' "$mistakes"
  fi
  if [[ -n "$models" && "$models" != "null" ]]; then
    printf 'Models:    %s\n' "$models"
  fi
  printf '\n'
  return 0
}

# Format multiple entries from an audit file.
# Arguments:
#   $1 - audit file path
#   $2 - number of entries (from tail)
logs::format_entries() {
  local audit_file="$1"
  local count="$2"

  if [[ ! -f "$audit_file" ]] || [[ ! -s "$audit_file" ]]; then
    return 1
  fi

  local lines
  lines=$(tail -n "$count" "$audit_file" 2>/dev/null) || true
  if [[ -z "$lines" ]]; then
    return 1
  fi

  local total
  total=$(wc -l <"$audit_file" 2>/dev/null | tr -d ' ')
  local start=$((total > count ? total - count + 1 : 1))

  local i=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ((++i))
    logs::format_entry "$line" "$((start + i - 1))"
  done <<<"$lines"

  return 0
}

###
### :::: Main :::: #####################
###

main() {
  if ! command -v jq &>/dev/null; then
    exit 0
  fi

  local PAYLOAD ARGS
  PAYLOAD=$(_read_payload)

  if [[ -z "$PAYLOAD" ]]; then
    exit 0
  fi

  ARGS=$(_extract_command_args "$PAYLOAD")
  ARGS="${ARGS%%[[:space:]]}"

  local AUDIT_LOG
  AUDIT_LOG=$(logs::audit_path)

  # Handle --clear
  if [[ "$ARGS" == "--clear" ]]; then
    if [[ ! -f "$AUDIT_LOG" ]]; then
      _format_block_response "No audit log file found -- nothing to clear."
      exit 0
    fi
    rm -f "$AUDIT_LOG"
    _format_block_response "Audit log cleared."
    exit 0
  fi

  # Determine count
  local count=1
  if [[ -n "$ARGS" ]]; then
    if [[ "$ARGS" =~ ^[0-9]+$ ]]; then
      count="$ARGS"
    else
      _format_block_response "Usage: /better-prompt:logs [count|--clear]

  count    Number of recent entries to show (default: 1)
  --clear  Delete the audit log"
      exit 0
    fi
  fi

  # Check file exists
  if [[ ! -f "$AUDIT_LOG" ]]; then
    _format_block_response "No audit log found.

The audit log is created automatically when audit logging is enabled.
Enable it with: /better-prompt:toggle audit on"
    exit 0
  fi

  # Check file is not empty
  if [[ ! -s "$AUDIT_LOG" ]]; then
    _format_block_response "Audit log is empty."
    exit 0
  fi

  # Format and display entries
  local output
  output=$(logs::format_entries "$AUDIT_LOG" "$count") || true

  if [[ -z "$output" ]]; then
    _format_block_response "Audit log is empty."
    exit 0
  fi

  _format_block_response "$output"
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap '_warn "Error at ${BASH_SOURCE[0]##*/}:$LINENO (${FUNCNAME[0]:-main})" >&2; exit 1' ERR
  main "$@"
fi
