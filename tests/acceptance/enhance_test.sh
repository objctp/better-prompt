#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function set_up_before_script() {
  # Source common.sh only — acceptance tests run enhance.sh as a subprocess.
  # See .claude/rules/testing.md — "Sourcing Scripts Under Test"
  local _opts
  _opts=$(shopt -po errexit nounset pipefail 2>/dev/null || true)
  source "$PROJECT_ROOT/hooks/scripts/lib/common.sh"
  eval "$_opts"
}

function set_up() {
  _CONFIG_FILE=$(bashunit::temp_file)
  cat >"$_CONFIG_FILE" <<'CFG'
---
enabled: true
correction: true
correction_model: haiku
translation: false
translation_model: haiku
enhancement: false
enhancement_model: sonnet
audit: true
verbose: false
---
CFG
}

function tear_down() {
  rm -f "$_CONFIG_FILE"
}

###
### Child process guard
###

function test_main_passes_through_when_child_process() {
  local result
  result=$(BETTER_PROMPT_CHILD=1 bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  assert_not_contains "block" "$result"
}

###
### Fast-fail gate: empty stdin
###

function test_main_passes_through_on_empty_stdin() {
  local result
  result=$(echo "" | BETTER_PROMPT_CHILD="" BETTER_PROMPT_CONFIG="$_CONFIG_FILE" \
    bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null || true)
  assert_contains "continue" "$result"
  assert_not_contains "block" "$result"
}

###
### Fast-fail gate: disabled config
###

function test_main_passes_through_when_disabled() {
  cat >"$_CONFIG_FILE" <<'CFG'
---
enabled: false
---
CFG
  local result
  result=$(printf '%s' '{"prompt":"hello world","session_id":"abc-123"}' |
    BETTER_PROMPT_CHILD="" BETTER_PROMPT_CONFIG="$_CONFIG_FILE" \
      bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null)
  assert_contains "continue" "$result"
  assert_not_contains "block" "$result"
}

###
### Fast-fail gate: directive prompt
###

function test_main_passes_through_when_directive() {
  local result
  result=$(printf '%s' '{"prompt":"/command","session_id":"abc-123"}' |
    BETTER_PROMPT_CHILD="" BETTER_PROMPT_CONFIG="$_CONFIG_FILE" \
      bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null)
  assert_contains "continue" "$result"
  assert_not_contains "block" "$result"
}
