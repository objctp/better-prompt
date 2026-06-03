#!/usr/bin/env bash
#
# Shared functions for better-prompt plugin scripts.
#
# Provides:
#   OS detection, logging, JSON utilities, file utilities,
#   hook payload helpers, and config parsing.
#
# Usage:
#   source "${PLUGIN_ROOT}/hooks/scripts/lib/common.sh"
#   _detect_os              # sets IS_MACOS
#   declare -A _CFG=()
#   _parse_config           # populates _CFG from $CONFIG
#   _get_setting "key" "default"
#

###
### :::: OS Detection :::: ###############
###

# Detect macOS and set IS_MACOS variable.
# Uses OSTYPE (bash builtin) to avoid spawning uname.
_detect_os() {
  if [[ -z "${IS_MACOS:-}" ]]; then
    if [[ "$OSTYPE" == darwin* ]]; then
      IS_MACOS=true
    else
      IS_MACOS=false
    fi
  fi
}

###
### :::: Logging :::: ####################
###

_warn() {
  printf '[better-prompt] WARNING: %s\n' "$*" >&2
  return 0
}

# Prefix for debug output. Override per-script before sourcing.
# shellcheck disable=SC2034
_DEBUG_PREFIX="${_DEBUG_PREFIX:-[better-prompt]}"

# Buffer for collecting debug messages during pipeline execution.
# Rendered in the verbose block output by enhance::format_response.
_DEBUG_LOG=""

_debug() {
  if [[ "${VERBOSE:-false}" == "true" ]]; then
    printf '%s DEBUG: %s\n' "$_DEBUG_PREFIX" "$*" >&2
    _DEBUG_LOG+="${_DEBUG_LOG:+\\n}  → $*"
  fi
  return 0
}

###
### :::: JSON Utilities :::: #############
###

_json_escape() {
  local input="$1"
  # Prefer jq for correct JSON escaping; avoid redundant command -v since
  # callers already guarantee jq availability.
  printf '%s' "$input" | jq -Rs .
  return 0
}

# Collapses multi-line text into a single-line summary for UI display.
# Shows the first non-empty line trimmed to max_chars, followed by [+N lines]
# when the text has additional lines.
#
# Arguments:
#   $1 - text to truncate
#   $2 - max preview characters (default 80)
_truncate_for_display() {
  local text="$1"
  local max_chars="${2:-80}"

  # Count non-empty lines.
  local line_count
  line_count=$(printf '%s' "$text" | grep -c .) || line_count=0

  if [[ "$line_count" -eq 0 ]]; then
    return 0
  fi

  # First non-empty line (not yet truncated).
  local first_line
  first_line=$(printf '%s' "$text" | awk 'NF{print;exit}')

  local suffix=""
  if [[ ${#first_line} -gt "$max_chars" ]]; then
    first_line="${first_line:0:$((max_chars - 4))}"
    suffix=" ..."
  fi

  if [[ "$line_count" -gt 1 ]]; then
    suffix+=" [+ $((line_count - 1)) lines]"
  fi

  printf '%s%s' "$first_line" "$suffix"
  return 0
}

###
### :::: File Utilities :::: #############
###

# temp + rename prevents partial reads from concurrent processes
_atomic_write() {
  local target="$1" content="$2"
  local tmp
  tmp=$(mktemp "${target}.XXXXXX") || return 1
  printf '%s' "$content" >"$tmp" && mv -f "$tmp" "$target"
  return 0
}

# macOS md5 prints only the digest; GNU md5sum appends the filename
_md5() {
  printf '%s' "$1" | (md5 2>/dev/null || md5sum 2>/dev/null | cut -c1-32)
  return 0
}

###
### :::: Hook Payload Helpers :::: #######
###

# Read JSON payload from stdin. Must run before any subshell consumes stdin.
# Uses read -d '' to avoid spawning cat (builtin-only).
_read_payload() {
  local payload=""
  if [[ ! -t 0 ]]; then
    read -r -d '' payload
  fi
  printf '%s' "$payload"
  return 0
}

# Extract command_args from a hook payload JSON string.
_extract_command_args() {
  local payload="$1"
  jq -r '.command_args // empty' <<<"$payload" 2>/dev/null || true
  return 0
}

# Format a JSON block response with a message.
_format_block_response() {
  local message="$1"
  local escaped
  escaped=$(_json_escape "$message")
  printf '{"decision": "block", "reason": %s}\n' "$escaped"
  return 0
}

###
### :::: Config Functions :::: ###########
###

# Sources YAML frontmatter from a markdown config file into an associative array.
#
# Arguments:
#   $1 - nameref of the associative array to populate
# Requires:
#   CONFIG file path variable
_parse_config() {
  local -n _pc_cfg="$1"
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
    _pc_cfg["$key"]="$val"
  done <"$CONFIG"
  return 0
}

# Print a single setting from _CFG, or a default value.
# Uses ${var-default} (no colon) so empty strings are treated as valid values.
_get_setting() {
  local key="$1"
  local default="$2"
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
    count==1 && index($0, key ":") == 1 {
      sub(key ":[[:space:]]*", ""); sub(/#.*$/,"")
      gsub(/^[[:space:]]+|[[:space:]]+$/,"")
      print; found=1; exit
    }
    count>=2{exit}
    END{if(!found) print def}
  ' "$config_file"
  return 0
}

# Update a single key's value in YAML frontmatter, in-place.
# Preserves inline comments and everything outside the frontmatter.
# Uses atomic temp+mv to prevent partial reads by concurrent processes.
#
# Arguments:
#   $1 - config file path
#   $2 - key name
#   $3 - new value
#
# Returns 0 on success, 1 if the file does not exist.
#
_config_write_single() {
  local config_file="$1"
  local key="$2"
  local new_value="$3"

  if [[ ! -f "$config_file" ]]; then
    return 1
  fi

  local tmp
  tmp=$(mktemp "${config_file}.XXXXXX") || return 1

  awk -v key="$key" -v val="$new_value" '
    /^---$/ { count++; print; next }
    count == 1 && index($0, key ":") == 1 {
      comment = ""
      if (match($0, /#.*/)) {
        comment = substr($0, RSTART)
      }
      print key ": " val (comment ? "  " comment : "")
      written = 1
      next
    }
    { print }
    END {
      # Key not found in frontmatter -- do not add new keys silently.
    }
  ' "$config_file" >"$tmp" && mv -f "$tmp" "$config_file"

  return 0
}
