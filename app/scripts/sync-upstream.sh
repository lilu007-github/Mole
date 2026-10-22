#!/bin/bash
# Bring tw93/Mole's latest main into this fork, then verify and rebuild Burrow.
# Usage: app/scripts/sync-upstream.sh [--push]
#
# 1. fetch upstream and show what is new
# 2. fast-forward the fork's main to upstream/main (main carries no own work)
# 3. merge upstream/main into the current branch (Burrow lives in app/ only,
#    so conflicts should not happen; on one the merge is aborted)
# 4. run app/scripts/run-checks.sh and rebuild Burrow.app with the new CLI
# --push also pushes main and the current branch to origin.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

PUSH=false
[[ "${1:-}" == "--push" ]] && PUSH=true

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Uncommitted changes; commit or stash them first." >&2
    exit 1
fi
git remote get-url upstream > /dev/null 2>&1 ||
    git remote add upstream https://github.com/tw93/Mole.git

BRANCH="$(git branch --show-current)"
version_at() { git show "$1:mole" | sed -n 's/^VERSION="\(.*\)"$/\1/p'; }

git fetch --quiet upstream
git fetch --quiet origin
OLD_VERSION="$(version_at HEAD)"
NEW_VERSION="$(version_at upstream/main)"
BEHIND="$(git rev-list --count HEAD..upstream/main)"

if [[ "$BEHIND" -eq 0 ]]; then
    echo "Already up to date with upstream (Mole $OLD_VERSION)."
    exit 0
fi

echo "Upstream has $BEHIND new commit(s): Mole $OLD_VERSION -> $NEW_VERSION"
git log --oneline --no-merges HEAD..upstream/main | head -30
echo ""

# The fork's main mirrors upstream; refuse to move it if it ever diverged.
if git merge-base --is-ancestor origin/main upstream/main; then
    git branch -f main upstream/main 2> /dev/null || git update-ref refs/heads/main upstream/main
else
    echo "warning: origin/main has commits upstream does not; leaving main alone." >&2
fi

if [[ "$BRANCH" != "main" ]]; then
    if ! git merge --no-edit upstream/main; then
        git merge --abort
        echo "Merge conflict; aborted. Resolve by hand: git merge upstream/main" >&2
        exit 1
    fi
fi

echo ""
echo "Running Burrow checks..."
"$REPO_DIR/app/scripts/run-checks.sh"

echo ""
"$REPO_DIR/app/build-app.sh"

if [[ "$PUSH" == "true" ]]; then
    git push --quiet origin main
    [[ "$BRANCH" != "main" ]] && git push --quiet origin "$BRANCH"
    echo "Pushed main and $BRANCH to origin."
else
    echo "Not pushed. Review, then: git push origin main $BRANCH"
fi
