#!/bin/bash
# Prints the version for the next release.
#
#   scripts/next-version.sh [patch|minor|major]   (default: patch)
#
# Release tags (vX.Y.Z) are the source of truth. The next version bumps the newest tag, unless
# MARKETING_VERSION in the project is already higher, in which case that's used as-is. So to jump
# to 2.0.0, set MARKETING_VERSION to 2.0 and push. With no tags yet, it bumps MARKETING_VERSION.
set -euo pipefail

cd "$(dirname "$0")/.."

BUMP="${1:-patch}"
case "$BUMP" in patch | minor | major) ;; *) echo "usage: $0 [patch|minor|major]" >&2; exit 2 ;; esac

# "1.2" -> "1.2.0"; anything that isn't numeric is rejected.
normalize() {
    local IFS=.
    local parts=($1)
    for p in "${parts[@]}"; do [[ "$p" =~ ^[0-9]+$ ]] || return 1; done
    echo "${parts[0]:-0}.${parts[1]:-0}.${parts[2]:-0}"
}

# Succeeds when version $1 is greater than $2 (both X.Y.Z).
greater() {
    local IFS=.
    local a=($1) b=($2)
    for i in 0 1 2; do
        ((a[i] > b[i])) && return 0
        ((a[i] < b[i])) && return 1
    done
    return 1
}

project=$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' PairMagic.xcodeproj/project.pbxproj | head -1)
project=$(normalize "$project") || { echo "MARKETING_VERSION isn't a plain version number" >&2; exit 1; }

latest=""
for tag in $(git tag --list 'v[0-9]*'); do
    v=$(normalize "${tag#v}") || continue
    if [ -z "$latest" ] || greater "$v" "$latest"; then latest=$v; fi
done

if [ -n "$latest" ] && greater "$project" "$latest"; then
    echo "$project"
    exit 0
fi

IFS=. read -r major minor patch <<<"${latest:-$project}"
case "$BUMP" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
esac
