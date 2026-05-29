#!/usr/bin/env bash
# apex-agent-team :: TeamLint (E1)
# Static analysis of a project's subagent / agent-team configuration.
# Flags: dead agents, overlapping responsibilities, missing tool grants, unbounded fan-out.
# Exits non-zero if any HIGH-severity finding is present, so it can gate a pre-run launch.
set -euo pipefail

ROOT="${1:-.}"
if [ ! -d "$ROOT" ]; then
  echo "team-lint ERROR: scan path is not a directory: $ROOT" >&2
  exit 2
fi
ROOT="$(cd "$ROOT" && pwd)"

HIGH=0
MED=0

note_high() { echo "  [HIGH]   $1"; HIGH=$((HIGH + 1)); }
note_med()  { echo "  [MEDIUM] $1"; MED=$((MED + 1)); }

# --- collect agent definition files ---------------------------------------
# agents/**/*.md and .claude/agents/**/*.md anywhere under ROOT.
AGENT_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && AGENT_FILES+=("$f")
done < <(find "$ROOT" -type f -name '*.md' \
           \( -path '*/agents/*' -o -path '*/.claude/agents/*' \) \
           2>/dev/null | sort)

echo "TeamLint :: scanning agent-team config under $ROOT"
echo "TeamLint :: found ${#AGENT_FILES[@]} agent definition file(s)"
echo ""

if [ "${#AGENT_FILES[@]}" -eq 0 ]; then
  echo "No agent definitions found (agents/*.md or .claude/agents/*.md). Nothing to lint."
  echo ""
  echo "team-lint passed: 0 high / 0 medium findings"
  exit 0
fi

# --- helpers ---------------------------------------------------------------
# Read a single frontmatter scalar field's value (first match), lowercased trim.
fm_field() {
  # $1 = file, $2 = field name
  awk -v field="$2" '
    BEGIN { infm=0; seen=0 }
    /^---[[:space:]]*$/ { seen++; if (seen==1) {infm=1; next} else {infm=0} }
    infm==1 {
      line=$0
      if (tolower(line) ~ "^"field"[[:space:]]*:") {
        sub("^[^:]*:[[:space:]]*", "", line)
        print line
        exit
      }
    }
  ' "$1"
}

# Body of the agent file (everything after the closing frontmatter ---).
fm_body() {
  awk '
    BEGIN { fm=0; done=0 }
    /^---[[:space:]]*$/ { fm++; if (fm==2) {done=1; next} ; if (fm==1) next }
    done==1 { print }
  ' "$1"
}

# --- pass 1: parse all agents ---------------------------------------------
NAMES=()
DESCS=()
declare -a NAME_OF_FILE

for f in "${AGENT_FILES[@]}"; do
  name="$(fm_field "$f" name | tr -d '"'"'"'' | awk '{$1=$1};1')"
  desc="$(fm_field "$f" description | tr -d '"'"'"'' | tr 'A-Z' 'a-z')"
  NAMES+=("$name")
  DESCS+=("$desc")
  NAME_OF_FILE+=("$name")
done

# --- pass 2: per-agent checks ---------------------------------------------
for i in "${!AGENT_FILES[@]}"; do
  f="${AGENT_FILES[$i]}"
  name="${NAMES[$i]}"
  rel="${f#$ROOT/}"
  echo "agent: $rel  (name: ${name:-<missing>})"

  tools="$(fm_field "$f" allowed-tools)"
  [ -z "$tools" ] && tools="$(fm_field "$f" tools)"
  tools_lc="$(printf '%s' "$tools" | tr 'A-Z' 'a-z')"
  body_lc="$(fm_body "$f" | tr 'A-Z' 'a-z')"

  # --- missing tool grant (HIGH) ---
  # implied-capability phrase -> required tool token in allowed-tools
  check_grant() {
    # $1 = grep -E pattern of implied phrases ; $2 = tool token ; $3 = human label
    if printf '%s' "$body_lc" | grep -Eq "$1"; then
      if ! printf '%s' "$tools_lc" | grep -Eqw "$2"; then
        note_high "missing tool grant: body implies '$3' but '$2' is not in allowed-tools"
      fi
    fi
  }
  check_grant 'edit the file|modify the file|write the file|patch the file|apply the (edit|change)|create (a |the )?file' 'edit|write' 'file editing'
  check_grant 'run the tests|run the command|execute the|shell out|run (a )?bash|invoke the script' 'bash' 'shell execution'
  check_grant 'read the file|open the file|inspect the file|read the source' 'read' 'file reading'
  check_grant 'search the (web|internet)|web search|fetch (a )?url|fetch the page' 'websearch|webfetch' 'web access'
  check_grant 'grep (for|the)|search the (codebase|repo|files)|find (all )?references' 'grep|glob' 'code search'

  # --- unbounded fan-out (HIGH) ---
  if printf '%s' "$body_lc" | grep -Eq 'agent_spawn|task\(|spawn (multiple|several|many|agents)|in parallel|fan[ -]?out|parallel(ly)? (spawn|launch|dispatch)'; then
    if ! printf '%s' "$body_lc" | grep -Eq 'at most [0-9]+|up to [0-9]+|max(imum)?[ _-]?agents?|maxagents|concurrency|limit (of )?[0-9]+|no more than [0-9]+|cap(ped)? at [0-9]+|[0-9]+ (agents?|workers?) (in parallel|at (a |once|the same))'; then
      note_high "unbounded fan-out: parallel spawn implied with no explicit cap (add 'at most N' / maxAgents / concurrency)"
    fi
  fi

  echo ""
done

# --- dead agent (MEDIUM) ---------------------------------------------------
# An agent name is 'referenced' if it appears in any commands/*.md, skills/**/SKILL.md,
# or *other* agents/*.md file under ROOT.
echo "cross-reference check (dead agents):"
REF_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && REF_FILES+=("$f")
done < <(find "$ROOT" -type f -name '*.md' \
           \( -path '*/commands/*' -o -path '*/skills/*' -o -path '*/agents/*' -o -path '*/.claude/*' \) \
           2>/dev/null | sort)

for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  [ -z "$name" ] && { note_med "agent file ${AGENT_FILES[$i]#$ROOT/} has no 'name:' frontmatter"; continue; }
  self="${AGENT_FILES[$i]}"
  refs=0
  for rf in "${REF_FILES[@]}"; do
    [ "$rf" = "$self" ] && continue
    if grep -Eqw -- "$name" "$rf"; then refs=$((refs + 1)); fi
  done
  if [ "$refs" -eq 0 ]; then
    note_med "dead agent: '$name' is defined but never referenced by any command/skill/agent"
  fi
done
echo ""

# --- overlapping responsibilities (MEDIUM) ---------------------------------
# Near-duplicate descriptions: token Jaccard overlap >= 0.6 on words >3 chars.
echo "overlap check (near-duplicate descriptions):"
overlap() {
  # $1, $2 = lowercased description strings -> prints integer percent overlap
  awk -v a="$1" -v b="$2" '
    BEGIN {
      na=split(a, wa, /[^a-z0-9]+/); nb=split(b, wb, /[^a-z0-9]+/);
      for (i=1;i<=na;i++) if (length(wa[i])>3) A[wa[i]]=1;
      for (i=1;i<=nb;i++) if (length(wb[i])>3) B[wb[i]]=1;
      inter=0; uni=0;
      for (k in A) { uni++; if (k in B) inter++; }
      for (k in B) { if (!(k in A)) uni++; }
      if (uni==0) { print 0; exit }
      printf "%d", (inter*100)/uni;
    }'
}
n="${#NAMES[@]}"
for ((i=0;i<n;i++)); do
  for ((j=i+1;j<n;j++)); do
    da="${DESCS[$i]}"; db="${DESCS[$j]}"
    [ -z "$da" ] && continue
    [ -z "$db" ] && continue
    pct="$(overlap "$da" "$db")"
    if [ "${pct:-0}" -ge 60 ]; then
      note_med "overlapping responsibility: '${NAMES[$i]:-?}' and '${NAMES[$j]:-?}' descriptions overlap ${pct}%"
    fi
  done
done
echo ""

# --- summary ---------------------------------------------------------------
echo "============================================"
echo "TeamLint summary: $HIGH high / $MED medium finding(s)"
if [ "$HIGH" -gt 0 ]; then
  echo "team-lint FAIL: $HIGH high-severity finding(s) — resolve before launching the team."
  exit 1
fi
echo "team-lint passed: $HIGH high / $MED medium findings"
