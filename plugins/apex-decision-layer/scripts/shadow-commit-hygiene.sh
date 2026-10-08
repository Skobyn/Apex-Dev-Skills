#!/usr/bin/env bash
# shadow-commit-hygiene.sh [REV] — ask the seeded commit-hygiene@1 rubric about one commit (default HEAD).
# Shadow only (spec §14 Phase 5): the answer goes to the decision log and one summary line on stderr;
# nothing acts on it, and the script always exits 0. No hook calls it: run it by hand, from a git
# alias, or from a scheduled job. Off (backend_none) until the repository opts in like any rubric.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REV="${1:-HEAD}"
git rev-parse --verify -q "$REV^{commit}" >/dev/null || { echo "shadow-commit-hygiene: no commit $REV" >&2; exit 0; }
STATE="$(git show -s --format='%s%x00%b' "$REV" | python3 -c '
import json, subprocess, sys
subject, _, body = sys.stdin.read().partition("\0")
rev = sys.argv[1]
paths = subprocess.run(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", rev],
                       capture_output=True, text=True).stdout.split()
print(json.dumps({"subject": subject.strip(), "body": body.strip()[:4000], "changed_paths": paths[:200],
                  "changed_files": len(paths)}))' "$REV")"
OUT="$(printf '%s' "$STATE" | "$ROOT/bin/apex-decide" --rubric commit-hygiene@1 --state - --json --no-shadow 2>/dev/null || true)"
printf '%s' "$OUT" | python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(0)
print("commit-hygiene %s: %s" % (sys.argv[1], d.get("verdict") if d.get("scored") else "unscored (%s)" % d.get("reason")), file=sys.stderr)' "$REV" || true
exit 0
