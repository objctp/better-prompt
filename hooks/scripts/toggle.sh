#!/usr/bin/env bash
#
# Toggle better-prompt settings via UserPromptExpansion hook.
# Intercepts /better-prompt:toggle commands and executes them
# directly, without LLM processing.
#
# Usage: toggle.sh < stdin-payload
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

# Validate that the stage name is toggleable.
# Returns 0 if valid, 1 otherwise.
toggle::validate_stage() {
  local stage="$1"
  local -a allowed=(enabled correction translation enhancement audit verbose)
  local a
  for a in "${allowed[@]}"; do
    [[ "$stage" == "$a" ]] && return 0
  done
  return 1
}

# Determine the new boolean value given an optional argument and current value.
# If arg is "on" or "off", use that. Otherwise flip the current value.
# Prints the new value. Prints empty string on invalid argument.
toggle::resolve_new_value() {
  local current="$1"
  local arg="${2:-}"

  case "$arg" in
  on) printf 'true' ;;
  off) printf 'false' ;;
  "")
    if [[ "$current" == "true" ]]; then
      printf 'false'
    else
      printf 'true'
    fi
    ;;
  *)
    # Invalid argument -- signal error via empty output
    printf ''
    ;;
  esac
  return 0
}

# Format the human-readable confirmation message.
toggle::format_confirm() {
  local stage="$1"
  local new_value="$2"

  if [[ "$stage" == "enabled" ]]; then
    if [[ "$new_value" == "false" ]]; then
      printf 'Plugin is now DISABLED (all stages inactive)'
    else
      printf 'Plugin is now ENABLED'
    fi
  else
    local state
    if [[ "$new_value" == "true" ]]; then state="ON"; else state="OFF"; fi
    printf '%s is now %s' "$stage" "$state"
  fi
  return 0
}

###
### :::: Main :::: #####################
###

main() {
  # Without jq we cannot parse the payload -- let the command fall through
  # to the LLM-based skill.
  if ! command -v jq &>/dev/null; then
    exit 0
  fi

  local PAYLOAD ARGS STAGE VALUE_ARG
  PAYLOAD=$(_read_payload)

  # Empty payload means script was invoked outside a hook context.
  if [[ -z "$PAYLOAD" ]]; then
    exit 0
  fi

  ARGS=$(_extract_command_args "$PAYLOAD")

  # Parse args: first word is stage, optional second word is on/off
  read -r STAGE VALUE_ARG <<<"$ARGS"
  STAGE="${STAGE%%[[:space:]]}"

  # No stage provided -- show usage
  if [[ -z "$STAGE" ]]; then
    _format_block_response "Usage: /better-prompt:toggle <stage> [on|off]

Available stages: enabled, correction, translation, enhancement, audit, verbose"
    exit 0
  fi

  # Validate stage name
  if ! toggle::validate_stage "$STAGE"; then
    _format_block_response "Unknown stage: '$STAGE'

Available stages: enabled, correction, translation, enhancement, audit, verbose"
    exit 0
  fi

  # Read current value
  local current_value
  current_value=$(_config_read_single "$CONFIG" "$STAGE" "")

  # Resolve new value
  local new_value
  new_value=$(toggle::resolve_new_value "$current_value" "$VALUE_ARG")

  # Invalid on/off argument
  if [[ -z "$new_value" ]] && [[ -n "$VALUE_ARG" ]]; then
    _format_block_response "Invalid value: '$VALUE_ARG'. Use 'on' or 'off' (or omit to toggle)."
    exit 0
  fi

  # Value already at target -- no change needed
  if [[ "$new_value" == "$current_value" ]]; then
    local state_label
    if [[ "$new_value" == "true" ]]; then state_label="ON"; else state_label="OFF"; fi
    _format_block_response "$STAGE is already $state_label (no change)"
    exit 0
  fi

  # Config file must exist
  if [[ ! -f "$CONFIG" ]]; then
    _format_block_response "Config file not found: $CONFIG
Try running any prompt first to initialise default settings."
    exit 0
  fi

  # Write new value
  if ! _config_write_single "$CONFIG" "$STAGE" "$new_value"; then
    _format_block_response "Failed to update config file: $CONFIG"
    exit 0
  fi

  # Confirm
  local message
  message=$(toggle::format_confirm "$STAGE" "$new_value")
  _format_block_response "$message"
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap '_warn "Error at ${BASH_SOURCE[0]##*/}:$LINENO (${FUNCNAME[0]:-main})" >&2; exit 1' ERR
  main "$@"
fi
