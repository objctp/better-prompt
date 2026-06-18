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

###
### Correction pipeline: multi-line prompt regression
###

# Regression: a multi-line `corrected` field used to make `read` truncate at the
# first newline, leaving CORRECTIONS_JSON empty and crashing write_audit's
# `jq --argjson`. We stub `claude` to return a multi-line result and assert the
# full pipeline emits valid JSON, preserves every line, and writes an audit entry.
function test_should_complete_pipeline_for_multiline_prompt() {
  local stub_bin project_dir
  stub_bin=$(mktemp -d)
  project_dir=$(mktemp -d)

  cat >"$stub_bin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
corrected=$'well then here:\n  """\n  pasted block\n  """\n  can i say Agentic?'
inner=$(jq -nc --arg c "$corrected" '{corrected:$c, language:"en", mistakes:[{type:"spelling",original:"thenn",correction:"then"}]}')
jq -nc --arg r "$inner" '{result:$r, total_cost_usd:0.001, usage:{input_tokens:50,output_tokens:30,cache_creation_input_tokens:0,cache_read_input_tokens:0}}'
STUB
  chmod +x "$stub_bin/claude"
  # No-op clipboard so the test does not clobber the user's clipboard.
  printf '#!/usr/bin/env bash\n' >"$stub_bin/pbcopy"; chmod +x "$stub_bin/pbcopy"

  local prompt payload
  prompt=$'well thenn here:\n  """\n  pasted block\n  """\n  cann i say Agenntic?'
  payload=$(jq -nc --arg p "$prompt" --arg s "accept-multiline" '{prompt:$p, session_id:$s}')

  local out rc
  out=$(printf '%s' "$payload" | env PATH="$stub_bin:$PATH" \
    BETTER_PROMPT_CONFIG="$_CONFIG_FILE" \
    CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
    CLAUDE_PROJECT_DIR="$project_dir" \
    CLAUDE_SESSION_ID="accept-multiline" \
    bash "$PROJECT_ROOT/hooks/scripts/enhance.sh" 2>/dev/null); rc=$?

  assert_equals "0" "$rc"
  echo "$out" | jq -e '.decision == "block" and .enhanced != null' >/dev/null
  assert_successful_code "$?"

  # Every line of the corrected prompt must survive (no read-truncation).
  local enhanced
  enhanced=$(printf '%s' "$out" | jq -r '.enhanced')
  assert_contains "well then here:" "$enhanced"
  assert_contains '"""' "$enhanced"
  assert_contains "pasted block" "$enhanced"
  assert_contains "can i say Agentic?" "$enhanced"

  # The audit entry must be written (this is the step that previously crashed).
  assert_file_exists "$project_dir/.claude/better-prompt/audit.json"
  local mistakes
  mistakes=$(jq -r '.mistakes | length' "$project_dir/.claude/better-prompt/audit.json" 2>/dev/null)
  assert_equals "1" "$mistakes"

  rm -rf "$stub_bin" "$project_dir"
}
