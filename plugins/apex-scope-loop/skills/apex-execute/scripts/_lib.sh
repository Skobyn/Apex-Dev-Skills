# shellcheck shell=bash
# _lib.sh — shared path and state resolution for apex-execute scripts.
# Sourced, never executed.
#
# Two roots, never conflated (ADR-0003):
#   REPO_ROOT   the checkout the caller is working in: `git rev-parse
#               --show-toplevel` from $PWD, else $PWD. Every git operation
#               (worktree add, land's merge) and the checkout-local kill
#               switches use it, exactly as in 0.2.0. The lessons ledger is
#               per plan repository (LESSONS_LEDGER, set by apex_resolve).
#   STATE_BASE  the directory holding plan state dirs, shared by the base
#               checkout, the plan worktree and every linked worktree:
#                 1. $APEX_STATE_ROOT/.dev-plan-state/<repo-id>  (explicit; moves
#                    state only; made absolute; <repo-id> keys the repository
#                    so one root can serve several repos without collisions)
#                 2. <main checkout>/.dev-plan-state    (common git dir is <repo>/.git)
#                 3. <git-common-dir>/apex-scope-loop-state (bare repos, submodules)
#                 4. $REPO_ROOT/.dev-plan-state         (not a git repository)
# Plan identity: in git, the plan's path relative to the toplevel of the
# checkout holding it (physical paths, symlinks resolved), so the same plan
# referenced from the base checkout, from the plan worktree or through a
# symlink resolves to one state dir. Outside git: the plan's absolute
# physical path. A 0.2.0 state dir (absolute-path hash under REPO_ROOT) is
# honoured when no 0.3.0 dir exists yet.

APEX_EXECUTE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The harness reads history as committed: replace refs, grafts and inherited
# repository redirection cannot change what a diff shows.
export GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/nonexistent/apex-scope-loop-no-grafts
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
APEX_SCOPE_LOOP_PLUGIN_ROOT="$(cd "$APEX_EXECUTE_SCRIPTS/../../.." && pwd)"

apex_sha12() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -c1-12; }

# apex_state_base DIR — print the directory that holds plan state dirs for
# the repository containing DIR (the plan's directory).
apex_state_base() {
  local common root
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$common" ]] && common="$(cd "$common" && pwd -P)"
  if [[ -n "${APEX_STATE_ROOT:-}" ]]; then
    mkdir -p "$APEX_STATE_ROOT" && root="$(cd "$APEX_STATE_ROOT" && pwd -P)" || return 1
    printf '%s/.dev-plan-state/%s' "$root" "$(printf '%s' "${common:-$REPO_ROOT}" | apex_sha12)"
    return
  fi
  if [[ -z "$common" ]]; then
    printf '%s/.dev-plan-state' "$REPO_ROOT"
  elif [[ "$(basename "$common")" == ".git" ]]; then
    printf '%s/.dev-plan-state' "$(dirname "$common")"
  else
    printf '%s/apex-scope-loop-state' "$common"
  fi
}

# apex_resolve PLAN — set PLAN_ABS, PLAN_TOP, REPO_ROOT, STATE_BASE,
# PLAN_HASH, STATE_DIR, CHECKPOINT and LESSONS_LEDGER, then run apex_guard (fatal on a
# repository mismatch unless the caller declared APEX_RESOLVE_MODE=read).
apex_resolve() {
  local plan="$1" plan_dir plan_top legacy legacy_dir main_root
  plan_dir="$(cd "$(dirname "$plan")" && pwd -P)"
  PLAN_ABS="$plan_dir/$(basename "$plan")"
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  STATE_BASE="$(apex_state_base "$plan_dir")"
  plan_top="$(git -C "$plan_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$plan_top" ]]; then
    plan_top="$(cd "$plan_top" && pwd -P)"
    PLAN_TOP="$plan_top"
    PLAN_HASH="$(printf '%s' "${PLAN_ABS#"$plan_top"/}" | apex_sha12)"
  else
    PLAN_TOP=""
    PLAN_HASH="$(printf '%s' "$PLAN_ABS" | apex_sha12)"
  fi
  STATE_DIR="$STATE_BASE/$PLAN_HASH"
  # 0.2.0 compatibility: a state dir keyed by the absolute (logical) plan path
  # under the caller's checkout, or, for the same plan referenced from a
  # worktree, the main checkout's copy of that path.
  if [[ ! -d "$STATE_DIR" ]]; then
    legacy="$(printf '%s' "$(cd "$(dirname "$plan")" && pwd)/$(basename "$plan")" | apex_sha12)"
    legacy_dir="$REPO_ROOT/.dev-plan-state/$legacy"
    # Never adopt a state dir from the caller's checkout for another repo's plan.
    [[ "$(apex_common_dir "$REPO_ROOT")" == "$(apex_common_dir "$plan_dir")" ]] || legacy_dir="/nonexistent"
    if [[ ! -f "$legacy_dir/checkpoint.json" && -n "$plan_top" && "$(basename "$STATE_BASE")" == ".dev-plan-state" ]]; then
      main_root="$(dirname "$STATE_BASE")"
      legacy="$(printf '%s' "$main_root/${PLAN_ABS#"$plan_top"/}" | apex_sha12)"
      legacy_dir="$main_root/.dev-plan-state/$legacy"
    fi
    if [[ -f "$legacy_dir/checkpoint.json" ]]; then
      PLAN_HASH="$legacy"
      STATE_DIR="$legacy_dir"
    fi
  fi
  CHECKPOINT="$STATE_DIR/checkpoint.json"
  # The lessons ledger is one per plan repository, whatever the caller or the
  # state layout: the main worktree's tracked copy; for a bare repository
  # (no main worktree) one file in the common git dir; outside git the
  # caller's checkout.
  if [[ -n "${APEX_LESSONS_FILE:-}" ]]; then
    LESSONS_LEDGER="$APEX_LESSONS_FILE"
  elif [[ -n "$plan_top" ]]; then
    local main_wt
    main_wt="$(git -C "$plan_top" worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{p=substr($0,10); getline n; if (n != "bare") print p; exit}')"
    if [[ -n "$main_wt" ]]; then
      LESSONS_LEDGER="$(cd "$main_wt" && pwd -P)/.claude/apex-scope-loop/LESSONS.md"
    else
      LESSONS_LEDGER="$(apex_common_dir "$plan_top")/apex-scope-loop/LESSONS.md"
    fi
  else
    LESSONS_LEDGER="$REPO_ROOT/.claude/apex-scope-loop/LESSONS.md"
  fi
  apex_guard
}

# apex_halt_files — every kill-switch path: checkout-local and shared.
apex_halt_files() {
  printf '%s\n' "$REPO_ROOT/.dev-plan-state/HALT" "$STATE_BASE/HALT" "$STATE_DIR/HALT" "$REPO_ROOT/gibson/HALT" \
    | awk '!seen[$0]++'
}

# apex_floor DIR [REV] — the current task's diff base (ADR-0003, the chain):
# the head the last harness-on `complete` verified, else the run's fork point
# (fork_sha, written by init.sh). The fork point must still be on the base
# branch. When the last verified head is not an ancestor of REV (default HEAD
# in DIR; after a rebase, amend or reset) the floor drops back to the fork
# point (or its merge-base with REV): never to a commit that only REV's own
# history picked. Prints nothing and returns 1 when no floor resolves
# (reason on stderr) — callers refuse.
apex_floor() {
  local dir="$1" rev="${2:-HEAD}" last fork base f
  { IFS= read -r last; IFS= read -r fork; IFS= read -r base; } < <(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))
c = s.get("completes") or []
print(c[-1]["head"] if c else "")
print(s.get("fork_sha") or "")
print(s.get("base_branch") or "")' "$CHECKPOINT" 2>/dev/null)
  [[ -n "$fork" ]] || { echo "apex_floor: no fork point recorded" >&2; return 1; }
  fork="$(git -C "$dir" rev-parse -q --verify "${fork}^{commit}" 2>/dev/null)" \
    || { echo "apex_floor: the fork point is not a commit here" >&2; return 1; }
  if [[ -n "$base" ]] && ! git -C "$dir" merge-base --is-ancestor "$fork" "refs/heads/$base" 2>/dev/null; then
    echo "apex_floor: the fork point ${fork:0:12} is not on $base (the base branch was rewritten, or a merge into it was undone) — start a new run" >&2
    return 1
  fi
  f="$fork"
  if [[ -n "$last" ]] && last="$(git -C "$dir" rev-parse -q --verify "${last}^{commit}" 2>/dev/null)" \
     && git -C "$dir" merge-base --is-ancestor "$last" "$rev" 2>/dev/null; then
    f="$last"
  elif ! git -C "$dir" merge-base --is-ancestor "$fork" "$rev" 2>/dev/null; then
    f="$(git -C "$dir" merge-base "$fork" "$rev" 2>/dev/null)" || { echo "apex_floor: $rev shares no history with the fork point" >&2; return 1; }
  fi
  [[ -n "$f" ]] || return 1
  printf '%s\n' "$f"
}

# read_field KEY — a top-level checkpoint value as text ("" when absent or
# null). Callers read string fields only (worktree_path, worktree_branch,
# base_branch).
read_field() {
  python3 - "$CHECKPOINT" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    v = None
print("" if v is None else v, end="")
PY
}

# apex_common_dir DIR — the physical common git dir of DIR's repository ("" outside git).
apex_common_dir() {
  local c
  c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$c" ]] && (cd "$c" && pwd -P)
  return 0
}

# apex_die MSG — fail with MSG. Scripts that speak the iterate.sh brief
# protocol set APEX_STATUS_PROTOCOL=1 to also get a STATUS: ERROR line.
apex_die() {
  [[ "${APEX_STATUS_PROTOCOL:-0}" == "1" ]] && echo "STATUS: ERROR $1"
  echo "ERROR: $1" >&2
  exit 3
}

# apex_guard — one repository, proven (ADR-0003). State is keyed on the
# plan's repository; git actions run in the caller's checkout and in the
# checkpoint's worktree. Before any script acts, all four must name the same
# repository (physical common git dirs):
#   C  the caller's checkout            P  the plan's checkout
#   K  checkpoint git_common_dir        W  the recorded worktree, if present
# (a 0.2.0 checkpoint has no K; W stands in for it). The recorded worktree
# must also have the recorded branch checked out, and a recorded branch with
# no recorded worktree path is corruption. APEX_RESOLVE_MODE=read (status,
# audit, architecture review) turns a failure into a warning; nothing
# overrides it in act mode, APEX_INIT_FORCE included.
apex_guard() {
  local mode="${APEX_RESOLVE_MODE:-act}" c p k="" w="" wt="" br="" problems=() head
  c="$(apex_common_dir "$REPO_ROOT")"
  p="$( [[ -n "$PLAN_TOP" ]] && apex_common_dir "$PLAN_TOP" || true)"
  if [[ -f "$CHECKPOINT" ]]; then
    k="$(read_field git_common_dir)"
    wt="$(read_field worktree_path)"
    br="$(read_field worktree_branch)"
    [[ -n "$wt" && -d "$wt" ]] && w="$(apex_common_dir "$wt")"
  fi
  if [[ -n "$p" && -z "$c" && "$mode" == "act" ]]; then
    problems+=("the plan is in a git repository but this directory is not; run from a checkout of $p")
  fi
  local name val ref=""
  for name in c p k w; do
    val="${!name}"
    [[ -z "$val" ]] && continue
    if [[ -z "$ref" ]]; then ref="$val"; continue; fi
    if [[ "$val" != "$ref" ]]; then
      problems+=("repository mismatch: caller=${c:--} plan=${p:--} checkpoint=${k:--} worktree=${w:--}")
      break
    fi
  done
  if [[ -n "$br" && -z "$wt" ]]; then
    problems+=("checkpoint records branch '$br' but no worktree path (corrupt checkpoint)")
  elif [[ -n "$br" && -n "$w" ]]; then
    head="$(git -C "$wt" symbolic-ref -q HEAD 2>/dev/null || true)"
    [[ "$head" == "refs/heads/$br" ]] || problems+=("worktree $wt has '${head:-detached HEAD}' checked out, expected refs/heads/$br")
  fi
  [[ ${#problems[@]} -eq 0 ]] && return 0
  if [[ "$mode" == "read" ]]; then
    printf 'WARNING: %s\n' "${problems[@]}" >&2
    return 0
  fi
  apex_die "$(printf '%s; ' "${problems[@]}")refusing to act. Recover: run from a checkout of the plan's repository; check the recorded branch back out in the worktree; if the repository was moved or re-cloned, the old run cannot be resumed — remove $STATE_DIR and re-run init.sh"
}

# apex_dispatch_root — the sibling apex-dispatch plugin, or empty.
apex_dispatch_root() {
  local c
  for c in "${APEX_DISPATCH_ROOT:-}" "$APEX_SCOPE_LOOP_PLUGIN_ROOT/../apex-dispatch"; do
    [[ -n "$c" && -x "$c/scripts/route.sh" ]] && { (cd "$c" && pwd); return; }
  done
  # Plugin cache layout <cache>/<marketplace>/<plugin>/<version>/ (assumed; Phase 0 spike 11 left the marketplace-install layout unverified)
  for c in "$APEX_SCOPE_LOOP_PLUGIN_ROOT"/../../apex-dispatch/*/; do
    [[ -x "$c/scripts/route.sh" ]] && { (cd "$c" && pwd); return; }
  done
  return 0
}

# --- ACTIVE lock (ADR-0003) ---------------------------------------------------
# One active plan or ad-hoc route per repository: $STATE_BASE/ACTIVE/owner.json.
# Every read-check-write of it happens under an exclusive flock on
# $STATE_BASE/.active.lock, so two callers can never both win. An owner whose
# stage is DONE, or whose plan has landed, is reclaimed; anything unreadable
# or partial counts as held (fail closed). The same plan in the same session
# re-acquires freely; the same plan from another session is BUSY.
# APEX_FORCE_UNLOCK=1 reclaims any lock (manual recovery only).
apex_lock_dir() { printf '%s' "$STATE_BASE/ACTIVE"; }

# apex_lock OP [ARGS...] — acquire ID PLAN LINE STAGE KIND | stage ID STAGE |
# release ID | owner. acquire exits 10 when another owner holds the lock; any
# other non-zero exit means the lock itself could not be used (an error, not BUSY).
# stage and release act only for the current owner.
apex_lock() {
  mkdir -p "$STATE_BASE"
  python3 - "$STATE_BASE" "${APEX_FORCE_UNLOCK:-0}" "${CLAUDE_CODE_SESSION_ID:-${APEX_SESSION_ID:-}}" "$@" <<'PY'
import datetime, fcntl, json, os, re, shutil, sys
base, force, session, op, *args = sys.argv[1:]
d = os.path.join(base, "ACTIVE")
owner_path = os.path.join(d, "owner.json")
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def read_owner():
    """None = no lock; {} = held but unreadable (fail closed); else the owner."""
    try:
        o = json.load(open(owner_path))
    except FileNotFoundError:
        return None if not os.path.isdir(d) else {}
    except Exception:
        return {}
    return o if isinstance(o, dict) and o else {}

def write_owner(o):
    os.makedirs(d, exist_ok=True)
    tmp = owner_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(o, fh, indent=2)
    os.replace(tmp, owner_path)

def stale(o):
    if o.get("stage") == "DONE":
        return True
    oid = str(o.get("id", ""))
    if not re.fullmatch(r"[0-9a-f]{12}", oid):
        return False             # never resolve a path from an unexpected id
    try:
        return bool(json.load(open(os.path.join(base, str(o.get("id")), "checkpoint.json"))).get("landed"))
    except Exception:
        return False

try:
    lk = open(os.path.join(base, ".active.lock"), "a+")
except OSError as e:
    print(f"apex_lock: {e}", file=sys.stderr)
    sys.exit(3)
with lk:
    fcntl.flock(lk, fcntl.LOCK_EX)
    o = read_owner()
    if op == "owner":
        if not o:
            print("none" if o is None else "unreadable owner (held)")
        else:
            print(f"{o.get('kind','plan')} {o.get('id','?')} line {o.get('line_no','?')} stage {o.get('stage','?')} ({o.get('plan') or o.get('label','')})")
    elif op == "acquire":
        oid, plan, line, stage, kind = args
        if o is not None and force != "1":
            # Held by another plan, or by this plan in another session
            # (spec §5.3 D: plan_hash + session_id), unless stale.
            # Sessions must match exactly: a caller without a session id (a
            # shell or cron run) is a different session from one that has one.
            other_session = (o.get("session_id") or "") != (session or "")
            if o == {} or ((o.get("id") != oid or other_session) and not stale(o)):
                sys.exit(10)   # BUSY (an uncaught error exits 1: never mistaken for BUSY)
        same = bool(o) and o.get("id") == oid and str(o.get("line_no")) == line
        n = {"kind": kind, "id": oid, "line_no": int(line) if line.isdigit() else line, "stage": stage,
             "session_id": session, "started_at": o.get("started_at") if same and o.get("started_at") else now,
             "updated_at": now}
        n["plan" if kind == "plan" else "label"] = plan
        write_owner(n)
    elif op == "stage":
        if o and o.get("id") == args[0]:
            o["stage"], o["updated_at"] = args[1], now
            write_owner(o)
    elif op == "release":
        if o and o.get("id") == args[0]:
            shutil.rmtree(d, ignore_errors=True)
    else:
        sys.exit(2)
PY
}

apex_lock_acquire() { apex_lock acquire "$1" "$2" "$3" "$4" "${5:-plan}"; }
apex_lock_owner()   { apex_lock owner 2>/dev/null || echo "unknown"; }
apex_lock_stage()   { apex_lock stage "$1" "$2"; }
apex_lock_release() { apex_lock release "$1"; }
