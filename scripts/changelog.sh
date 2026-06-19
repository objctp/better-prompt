#!/usr/bin/env bash
# changelog.sh — manage CHANGELOG.md sections via git-cliff.
#
# Only the top section is ever regenerated; everything below the first
# "## [x.y.z]" release line is preserved verbatim. This avoids both the
# duplicate "## Unreleased" that --prepend would create and the loss of the
# curated entries for old releases that a full regenerate would cause.
#
# Usage:
#   scripts/changelog.sh preview           print the regenerated Unreleased section
#   scripts/changelog.sh unreleased        rewrite the Unreleased section in CHANGELOG.md
#   scripts/changelog.sh release [x.y.z]   cut a release: version section + commit + tag
#                                          (version auto-bumped from commits if omitted)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

FILE="CHANGELOG.md"
HEADER="# Changelog"

usage() {
  echo "usage: ${0##*/} {preview|unreleased|release [x.y.z]}" >&2
  exit 2
}

# Everything from the first "## [version]" line to EOF — preserved verbatim.
preserved_tail() { awk '/^## \[/{f=1} f' "$FILE"; }

# Next version implied by conventional commits since the last tag (e.g. 0.8.0).
bump_version() {
  git cliff --unreleased --bump --strip header |
    sed -n 's/^## \[\([^]]*\)\].*/\1/p' |
    head -n1
}

# Bump "version" in a JSON manifest (idempotent; jq preserves key order/format).
# No-op if the file is absent, so the manifest list can name optional files.
bump_manifest() {
  local file="$1" version="$2" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp)"
  jq --arg v "$version" '.version = $v' "$file" >"$tmp" && mv "$tmp" "$file"
}

# Rewrite the top section. $1 = mode, $2 = explicit version (release only).
write_section() {
  local mode="$1" version="${2:-}" section
  case "$mode" in
  unreleased)
    section="$(git cliff --unreleased --strip header)"
    ;;
  release)
    if [ -n "$version" ]; then
      section="$(git cliff --unreleased --tag "$version" --strip header)"
    else
      section="$(git cliff --unreleased --bump --strip header)"
    fi
    ;;
  esac
  {
    printf '%s\n\n' "$HEADER"
    printf '%s\n\n' "$section"
    preserved_tail
  } >"$FILE.tmp"
  mv "$FILE.tmp" "$FILE"
}

# release [version]: write the version section, commit (hook disabled), tag.
# Committing with the hook off prevents it rewriting the fresh version section
# back into Unreleased; tagging means the next commit regenerates an empty
# Unreleased instead of duplicating the released entries.
do_release() {
  local version="${1:-$(bump_version)}"
  [ -n "$version" ] || {
    echo "could not determine a release version" >&2
    exit 1
  }

  write_section release "$version"

  # Keep every version-bearing manifest in lockstep with the release.
  local manifest
  for manifest in package.json .claude-plugin/plugin.json; do
    bump_manifest "$manifest" "$version"
  done

  BP_CHANGELOG_HOOK=1 git commit -m "chore(release): ${version}" \
    -- "$FILE" package.json .claude-plugin/plugin.json >/dev/null

  git tag -a "$version" -m "Release ${version}" 2>/dev/null || echo "tag ${version} already exists" >&2

  echo "Cut ${version}: ${FILE} updated, committed, and tagged."
  echo "Next: git push --follow-tags, then create the GitHub release"
  echo "    to trigger .github/workflows/publish.yml."
}

[ -f "$FILE" ] || {
  echo "$FILE not found" >&2
  exit 1
}

case "${1:-}" in
preview) git cliff --unreleased --strip header ;;
unreleased) write_section unreleased ;;
release) do_release "${2:-}" ;;
*) usage ;;
esac
