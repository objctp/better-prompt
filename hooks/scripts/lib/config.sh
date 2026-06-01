#!/usr/bin/env bash
#
# Shared config parsing for better-prompt plugins.
# Sources YAML frontmatter from a markdown config file into the _CFG associative array.
#
# Usage:
#   declare -A _CFG=()
#   CONFIG="/path/to/config.md"
#   _parse_config           # populates _CFG from $CONFIG
#   _get_setting "key" "default"  # prints value or default
#

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

_get_setting() {
  local key="$1"
  local default="$2"
  # Use ${var-default} (no colon) so empty strings are treated as valid values
  # rather than falling back to the default.
  printf '%s' "${_CFG[$key]-$default}"
  return 0
}

# Convenience: read a single setting from config without populating _CFG.
# Arguments:
#   $1 - config file path
#   $2 - key name
#   $3 - default value
_config_read_single() {
  local config_file="$1"
  local key="$2"
  local default="${3:-}"
  if [[ ! -f "$config_file" ]]; then
    printf '%s' "$default"
    return 0
  fi
  awk -v key="$key" -v def="$default" '
    /^---$/{count++; next}
    count==1 && $0 ~ "^"key":"{
      sub("^"key":[[:space:]]*", ""); sub(/#.*$/,"")
      gsub(/^[[:space:]]+|[[:space:]]+$/,"")
      print; found=1; exit
    }
    count>=2{exit}
    END{if(!found) print def}
  ' "$config_file"
  return 0
}
