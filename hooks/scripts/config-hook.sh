#!/usr/bin/env bash
#
# Set better-prompt config settings via UserPromptExpansion hook.
# Intercepts /better-prompt:config <setting> <value> and executes
# directly, without LLM processing. Falls through to the LLM skill
# when no arguments are provided (interactive mode).
#
# Usage: config-hook.sh < stdin-payload
#
set -euo pipefail

# Assign only when unset; tests co-source several of these scripts in one shell.
[[ -v PLUGIN_ROOT ]] || PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
[[ -v CONFIG ]] || CONFIG="${BETTER_PROMPT_CONFIG:-$HOME/.claude/better-prompt.local.md}"
# shellcheck disable=SC2034
readonly PLUGIN_ROOT CONFIG 2>/dev/null || true

# shellcheck source=lib/common.sh
source "${PLUGIN_ROOT}/hooks/scripts/lib/common.sh"

###
### :::: Public Functions :::: #########
###

# Validate that the setting name is recognised.
# Returns 0 if valid, 1 otherwise.
config::validate_setting() {
  local setting="$1"
  local -a allowed=(
    enabled
    correction correction_model
    translation translation_model
    enhancement enhancement_model
    audit verbose
  )
  local a
  for a in "${allowed[@]}"; do
    [[ "$setting" == "$a" ]] && return 0
  done
  return 1
}

# Determine if a setting expects a boolean or model value.
# Prints "boolean" or "model".
config::setting_type() {
  local setting="$1"
  case "$setting" in
  *_model) printf 'model' ;;
  *) printf 'boolean' ;;
  esac
  return 0
}

# Validate a value against its expected type.
# Returns 0 if valid, 1 otherwise.
config::validate_value() {
  local setting="$1"
  local value="$2"
  local type
  type=$(config::setting_type "$setting")

  case "$type" in
  boolean)
    case "$value" in
    true | false | on | off | yes | no) return 0 ;;
    *) return 1 ;;
    esac
    ;;
  model)
    [[ "$value" =~ ^[a-zA-Z0-9._:-]+$ ]] && return 0
    return 1
    ;;
  esac
  return 1
}

# Normalise a value to canonical form (true/false for booleans).
config::normalise_value() {
  local setting="$1"
  local value="$2"
  local type
  type=$(config::setting_type "$setting")

  if [[ "$type" == "boolean" ]]; then
    case "$value" in
    on | yes) printf 'true' ;;
    off | no) printf 'false' ;;
    *) printf '%s' "$value" ;;
    esac
  else
    printf '%s' "$value"
  fi
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

  # No arguments -- fall through to LLM for interactive mode.
  if [[ -z "$ARGS" ]]; then
    exit 0
  fi

  local SETTING VALUE
  read -r SETTING VALUE <<<"$ARGS"
  SETTING="${SETTING%%[[:space:]]}"

  # --help / -h: display usage
  if [[ "$SETTING" == "--help" || "$SETTING" == "-h" ]]; then
    _format_block_response "Set better-prompt plugin configuration.

Usage: /better-prompt:config <setting> <value>
       /better-prompt:config --show
       /better-prompt:config --help

Flags:
  --show   Display current settings and their values
  --help   Show this help message

Settings:
  enabled             boolean   Global on/off switch
  correction          boolean   Grammar and spelling correction
  correction_model    model     Model for correction (default: haiku)
  translation         boolean   Translate non-English prompts
  translation_model   model     Model for translation (default: haiku)
  enhancement         boolean   Prompt enhancement
  enhancement_model   model     Model for enhancement (default: sonnet)
  audit               boolean   Audit trail logging
  verbose             boolean   Show intermediate pipeline steps

Boolean values: true/false, on/off, yes/no
Model values: any valid model name or ID (e.g. haiku, sonnet, opus)

Examples:
  /better-prompt:config verbose true
  /better-prompt:config enhancement_model sonnet
  /better-prompt:config --show
  /better-prompt:config            (interactive mode)"
    exit 0
  fi

  # --show: display current config
  if [[ "$SETTING" == "--show" ]]; then
    if [[ ! -f "$CONFIG" ]]; then
      _format_block_response "Config file not found: $CONFIG
Try running any prompt first to initialise default settings."
      exit 0
    fi

    declare -A _CFG=()
    _parse_config _CFG

    local -a _keys=(enabled correction correction_model translation translation_model enhancement enhancement_model audit verbose)
    local -a _defs=(true true haiku false haiku false sonnet true false)
    local -a _types=(boolean boolean model boolean model boolean model boolean boolean)

    local _output
    printf -v _output '%-22s %-8s %-10s %s\n%-22s %-8s %-10s %s' \
      "SETTING" "TYPE" "DEFAULT" "CURRENT" \
      "-------" "----" "-------" "-------"

    local i _val
    for i in "${!_keys[@]}"; do
      _val=$(_get_setting "${_keys[$i]}" "${_defs[$i]}")
      _output+=$'\n'
      _output+="$(printf '%-22s %-8s %-10s %s' "${_keys[$i]}" "${_types[$i]}" "${_defs[$i]}" "$_val")"
    done

    _format_block_response "$_output"
    exit 0
  fi

  # Missing value
  if [[ -z "$VALUE" ]]; then
    _format_block_response "Usage: /better-prompt:config <setting> <value>

Settings: enabled, correction, correction_model, translation, translation_model, enhancement, enhancement_model, audit, verbose

Boolean values: true/false, on/off, yes/no
Model values: any valid model name or ID (e.g. haiku, sonnet, opus)

Use /better-prompt:config --help for full usage."
    exit 0
  fi

  # Validate setting name
  if ! config::validate_setting "$SETTING"; then
    _format_block_response "Unknown setting: '$SETTING'

Available settings: enabled, correction, correction_model, translation, translation_model, enhancement, enhancement_model, audit, verbose"
    exit 0
  fi

  # Validate value
  if ! config::validate_value "$SETTING" "$VALUE"; then
    local type
    type=$(config::setting_type "$SETTING")
    local hint
    if [[ "$type" == "boolean" ]]; then
      hint="Expected: true/false, on/off, or yes/no"
    else
      hint="Expected: a valid model name or ID (alphanumeric, dot, dash, colon, underscore)"
    fi
    _format_block_response "Invalid value '$VALUE' for $SETTING ($type). $hint"
    exit 0
  fi

  # Normalise value
  local new_value
  new_value=$(config::normalise_value "$SETTING" "$VALUE")

  # Config file must exist
  if [[ ! -f "$CONFIG" ]]; then
    _format_block_response "Config file not found: $CONFIG
Try running any prompt first to initialise default settings."
    exit 0
  fi

  # Write new value
  if ! _config_write_single "$CONFIG" "$SETTING" "$new_value"; then
    _format_block_response "Failed to update config file: $CONFIG"
    exit 0
  fi

  # Confirm
  _format_block_response "$SETTING is now $new_value"
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap '_warn "Error at ${BASH_SOURCE[0]##*/}:$LINENO (${FUNCNAME[0]:-main})" >&2; exit 1' ERR
  main "$@"
fi
