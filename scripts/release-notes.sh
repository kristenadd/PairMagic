#!/bin/bash
# Prints Markdown release notes listing the commits since the previous release tag.
#
#   scripts/release-notes.sh <new-version> [commit]   (commit defaults to HEAD)
#
# Each commit's subject line becomes a bullet. Release keywords (#minor, #major, [skip ci]) are
# removed from the text, and merge commits are left out.
set -euo pipefail

cd "$(dirname "$0")/.."

[ $# -ge 1 ] || { echo "usage: $0 <new-version> [commit]" >&2; exit 2; }
VERSION="$1" HEAD_REF="${2:-HEAD}"
REPO="${GITHUB_REPOSITORY:-kristenadd/PairMagic}"

# The newest release tag other than this version's own, so this also works for past releases.
previous=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude "v$VERSION" "$HEAD_REF" 2>/dev/null || true)
range="${previous:+$previous..}$HEAD_REF"

changes=$(git log --no-merges --reverse --format='%h%x09%s' "$range" | while IFS=$'\t' read -r sha subject; do
    subject=$(sed -E 's/[[:space:]]*(#minor|#major|\[skip (release|ci)\])//g; s/[[:space:]]+$//' <<<"$subject")
    [ -n "$subject" ] && echo "- $subject ($sha)"
done)

if [ -n "$changes" ]; then
    echo "## What's Changed"
    echo
    echo "$changes"
fi
if [ -n "$previous" ]; then
    [ -n "$changes" ] && echo
    echo "**Full Changelog**: https://github.com/$REPO/compare/$previous...v$VERSION"
fi
