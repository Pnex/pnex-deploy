#!/usr/bin/env bash
# Cuts a PNeX release of this recipe, pinned to the images of that version:
#
#   scripts/release.sh 0.1.0-beta.1            # new release
#   scripts/release.sh 0.1.0-beta.1 --retag    # move an existing tag
#
# 1. release commit: VERSION (docker installer) and helm/pnex/Chart.yaml
#    appVersion (Helm chart) both set to <version>, tagged v<version>;
# 2. back-to-latest commit: main follows the moving `latest` images again.
#
# The images <version> come from pnex-rs (tag v<version>, workflow Images).
# Nothing is pushed: the script prints the push commands. Only tracked files
# are touched (local values such as helm/values-*.yaml stay out of it).
set -euo pipefail

version=${1:-}
retag=0
[[ ${2:-} == --retag ]] && retag=1
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "usage: scripts/release.sh <version> [--retag]   (e.g. 0.1.0-beta.1)" >&2
    exit 1
fi
cd "$(dirname "$0")/.."
chart=helm/pnex/Chart.yaml

[[ $(git branch --show-current) == main ]] || { echo "release from main only" >&2; exit 1; }
if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    echo "uncommitted changes in tracked files: commit or stash them first" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null && ((!retag)); then
    echo "tag v$version exists: pass --retag to move it" >&2
    exit 1
fi

pin() { # $1 = image tag
    printf '%s\n' "$1" >VERSION
    sed -i -E "s/^appVersion: .*/appVersion: \"$1\"/" "$chart"
    grep -q "^appVersion: \"$1\"$" "$chart" || { echo "appVersion not set in $chart" >&2; exit 1; }
}

pin "$version"
git add VERSION "$chart"
git commit -q -m "Release $version: images pinned to $version (installer + Helm chart)"
if ((retag)); then
    git tag -f -a "v$version" -m "PNeX $version"
else
    git tag -a "v$version" -m "PNeX $version"
fi

pin latest
git add VERSION "$chart"
git commit -q -m "Back to latest on main after $version"

echo "v$version -> $(git rev-parse --short "v$version^{commit}"), main back to latest."
if ((retag)); then
    echo "push: git push origin main && git push --force origin v$version"
else
    echo "push: git push origin main && git push origin v$version"
fi
