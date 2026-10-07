#!/usr/bin/env bash
# snapshot.sh — One shared, read-only review snapshot per commit (ADR-0004,
# addendum D). Reviewers read the snapshot instead of building their own copy.
#
# Usage:
#   ./snapshot.sh PLAN.md [SHA]     create (or reuse) <state>/snapshots/<sha>/ for SHA
#                                   (default: the worktree head) and print
#                                   REVIEW_SNAPSHOT: <path>
#   ./snapshot.sh PLAN.md prune [--keep SHA]
#                                   remove snapshots (checkpoint.sh complete and
#                                   land.sh call this)
#
# The tree is written with `git read-tree` into a private index and
# `git checkout-index -a` — never `git archive`, so export-ignore attributes
# cannot drop files. Submodules are not populated (their gitlink directories
# are empty). APEX_SNAPSHOT_SETUP (e.g. "npm ci && npm run build"), when set,
# runs once inside the new snapshot before it is made read-only; a failing
# setup removes the snapshot (exit 1). Metadata lives beside the tree in
# <state>/snapshots/<sha>.json, never inside it. In a run without a worktree
# the snapshots live under <git-common-dir>/apex-scope-loop-snapshots/<plan>/,
# outside the work tree (the gate's clean-tree check never sees them).
set -euo pipefail

PLAN="${1:?usage: snapshot.sh PLAN.md [SHA] | prune [--keep SHA]}"
shift
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"; PLAN="$(apex_locate_plan "$PLAN")"   # ADR-0004 H
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }

APEX_RESOLVE_MODE=act  # this script acts: a repository mismatch is fatal (never inherited from the env)
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"
[[ -f "$CHECKPOINT" ]] || { echo "ERROR: not initialized — run init.sh first" >&2; exit 2; }
WT="$(read_field worktree_path)"; WT="${WT:-$REPO_ROOT}"
SNAPS="$STATE_DIR/snapshots"
# A run without a worktree keeps its state in the checkout: its snapshots go
# outside the work tree, under the repository's common git dir.
if [[ -z "$(read_field worktree_branch)" ]]; then
  CD="$(apex_common_dir "$WT")"
  [[ -n "$CD" ]] && SNAPS="$CD/apex-scope-loop-snapshots/$PLAN_HASH"
fi

remove_snap() { [[ -e "$1" ]] && { chmod -R u+w "$1" 2>/dev/null || true; rm -rf -- "$1"; }; rm -f -- "$1.json"; }

if [[ "${1:-}" == prune ]]; then
  KEEP=""
  [[ "${2:-}" == "--keep" ]] && KEEP="${3:?--keep needs a SHA}"
  n=0
  for d in "$SNAPS"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"; b="$(basename "$d")"
    [[ "$b" =~ ^[0-9a-f]{40,64}$ ]] || continue
    [[ -n "$KEEP" && "$b" == "$KEEP" ]] && continue
    remove_snap "$d"; n=$((n + 1))
  done
  rm -rf -- "$SNAPS"/.tmp.* 2>/dev/null || true
  echo "SNAPSHOTS_PRUNED: $n"
  exit 0
fi

REV="${1:-HEAD}"
SHA="$(apex_git "$WT" rev-parse -q --verify "${REV}^{commit}" 2>/dev/null)" || { echo "ERROR: $REV is not a commit in $WT" >&2; exit 2; }
DEST="$SNAPS/$SHA"
if [[ -d "$DEST" && -f "$DEST.json" ]]; then
  echo "REVIEW_SNAPSHOT: $DEST"
  echo "SNAPSHOT: reused"
  exit 0
fi
remove_snap "$DEST"
mkdir -p "$SNAPS"
TMP="$(mktemp -d "$SNAPS/.tmp.XXXXXX")"
IDX="$TMP.index"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf -- "$TMP" "$IDX"' EXIT
# A private index (apex_git unsets GIT_INDEX_FILE, so plain git here).
GIT_INDEX_FILE="$IDX" GIT_NO_REPLACE_OBJECTS=1 git -C "$WT" read-tree "$SHA"
GIT_INDEX_FILE="$IDX" GIT_NO_REPLACE_OBJECTS=1 git -C "$WT" checkout-index -a -f --prefix="$TMP/tree/"
mkdir -p "$TMP/tree"
SETUP_RC=""
if [[ -n "${APEX_SNAPSHOT_SETUP:-}" ]]; then
  SETUP_RC=0
  (cd "$TMP/tree" && bash -c "$APEX_SNAPSHOT_SETUP") >"$TMP/setup.log" 2>&1 || SETUP_RC=$?
  if [[ "$SETUP_RC" != 0 ]]; then
    echo "ERROR: APEX_SNAPSHOT_SETUP failed (exit $SETUP_RC) in the snapshot of ${SHA:0:12}:" >&2
    tail -5 "$TMP/setup.log" | sed 's/^/  /' >&2
    exit 1
  fi
fi
chmod -R a-w "$TMP/tree"
mv "$TMP/tree" "$DEST"
python3 -c 'import json,sys; json.dump({"sha": sys.argv[1], "setup": sys.argv[2] or None, "setup_exit": int(sys.argv[3]) if sys.argv[3] else None, "at": sys.argv[4]}, open(sys.argv[5], "w"), indent=2)' \
  "$SHA" "${APEX_SNAPSHOT_SETUP:-}" "$SETUP_RC" "$(date -u +%FT%TZ)" "$DEST.json"
echo "REVIEW_SNAPSHOT: $DEST"
echo "SNAPSHOT: created (read-only${APEX_SNAPSHOT_SETUP:+, setup ran})"
