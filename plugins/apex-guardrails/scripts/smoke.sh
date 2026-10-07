#!/usr/bin/env bash
# apex-guardrails structural smoke test
# Verifies the plugin contract from ADR-0001. Exits non-zero on first failure.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "smoke FAIL: $1" >&2; exit 1; }
ok()   { echo "smoke OK:   $1"; }

# 1. plugin.json exists and has required fields
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ -f "$PJ" ] || fail "missing $PJ"
for k in name version description author license keywords; do
  grep -q "\"$k\"" "$PJ" || fail "plugin.json missing key: $k"
done
grep -q "\"apex-guardrails\"" "$PJ" || fail "plugin.json name is not apex-guardrails"
ok "plugin.json has name/version/description/author/license/keywords"

# 2. plugin.json does NOT enumerate skills/commands/agents arrays
for forbidden in '"skills"' '"commands"' '"agents"'; do
  if grep -qE "$forbidden[[:space:]]*:[[:space:]]*\[" "$PJ"; then
    fail "plugin.json enumerates $forbidden array (must be auto-discovered)"
  fi
done
ok "plugin.json does not enumerate skills/commands/agents"

# 3. guardrail SKILL.md has valid unquoted kebab-case name matching its dir
for skill in guardrail; do
  S="$PLUGIN_ROOT/skills/$skill/SKILL.md"
  [ -f "$S" ] || fail "missing skill: $S"
  name_line=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$S")
  [ -n "$name_line" ] || fail "$skill SKILL.md missing name: frontmatter"
  echo "$name_line" | grep -qE "^name:[[:space:]]+$skill[[:space:]]*$" \
    || fail "$skill SKILL.md name: must be kebab-case '$skill' (got: $name_line)"
  ok "$skill SKILL.md frontmatter is valid"
done

# 4. No wildcard tools in any SKILL.md
for s in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  if grep -qE "allowed-tools:.*(\\*|mcp__\\*)" "$s"; then
    fail "$s has wildcard in allowed-tools"
  fi
done
ok "no wildcard tools in skills"

# 5. guardrails-policy command present with valid frontmatter
for cmd in guardrails-policy; do
  C="$PLUGIN_ROOT/commands/$cmd.md"
  [ -f "$C" ] || fail "missing command: $C"
  grep -qE "^name:[[:space:]]+$cmd[[:space:]]*$" "$C" \
    || fail "$cmd command frontmatter missing or invalid name:"
  grep -q "^description:" "$C" || fail "$cmd command missing description"
done
ok "command guardrails-policy present with valid frontmatter"

# 6. hooks/hooks.json exists, is valid JSON, and quotes "${CLAUDE_PLUGIN_ROOT}"
HJ="$PLUGIN_ROOT/hooks/hooks.json"
[ -f "$HJ" ] || fail "missing $HJ"
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HJ" \
    || fail "hooks/hooks.json is not valid JSON"
elif command -v jq >/dev/null 2>&1; then
  jq empty "$HJ" >/dev/null 2>&1 || fail "hooks/hooks.json is not valid JSON"
fi
grep -q "PreToolUse" "$HJ" || fail "hooks/hooks.json declares no PreToolUse matchers"
grep -q "CLAUDE_PLUGIN_ROOT" "$HJ" || fail "hooks/hooks.json does not use \${CLAUDE_PLUGIN_ROOT}"
if grep -E '"command"[[:space:]]*:' "$HJ" | grep -vqF '\"${CLAUDE_PLUGIN_ROOT}/'; then
  fail "hooks/hooks.json has a command whose \${CLAUDE_PLUGIN_ROOT} path is not quoted"
fi
ok "hooks/hooks.json exists, is valid JSON, declares PreToolUse + quoted \"\${CLAUDE_PLUGIN_ROOT}\""

# 7. All three hook scripts present
for h in block-sensitive-paths.sh block-destructive-bash.sh secret-scan.sh; do
  [ -f "$PLUGIN_ROOT/hooks/$h" ] || fail "missing hook script: hooks/$h"
done
ok "all three hook scripts present"

# 8. README has required sections
R="$PLUGIN_ROOT/README.md"
[ -f "$R" ] || fail "missing README.md"
for section in "Compatibility" "Namespace coordination" "Verification" "Architecture Decisions"; do
  grep -q "## $section" "$R" || fail "README missing section: $section"
done
ok "README has Compatibility/Namespace/Verification/ADR sections"

# 9. ADR-0001 exists with Status: Proposed
ADR="$PLUGIN_ROOT/docs/adrs/0001-apex-guardrails-contract.md"
[ -f "$ADR" ] || fail "missing ADR-0001"
grep -qE "^- \*\*Status:\*\* Proposed" "$ADR" || fail "ADR-0001 not in Proposed status"
ok "ADR-0001 exists with Status: Proposed"

# 10. All .sh scripts in hooks/ and scripts/ are executable
non_exec=$(find "$PLUGIN_ROOT/hooks" "$PLUGIN_ROOT/scripts" -name "*.sh" \! -perm -u+x 2>/dev/null || true)
if [ -n "$non_exec" ]; then
  fail "non-executable .sh files found: $non_exec"
fi
ok "all .sh scripts are executable"

# 11. hooks.json is exactly what compile-policy.sh emits for the shipped policy,
#     and a policy without destructive_bash still wires the always-on bypass denial
SMOKE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/apex-guardrails-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_TMP"' EXIT
bash "$PLUGIN_ROOT/scripts/compile-policy.sh" "$PLUGIN_ROOT/resources/policy.example.yaml" "$SMOKE_TMP/hooks.json" >/dev/null \
  || fail "compile-policy.sh failed on the shipped policy"
cmp -s "$SMOKE_TMP/hooks.json" "$HJ" || fail "hooks/hooks.json differs from compile-policy.sh output (recompile, do not hand-edit)"
printf 'version: "1"\nsensitive_paths:\n  - "**/.env"\n' >"$SMOKE_TMP/paths-only.yaml"
bash "$PLUGIN_ROOT/scripts/compile-policy.sh" "$SMOKE_TMP/paths-only.yaml" "$SMOKE_TMP/paths-only.json" >/dev/null \
  || fail "compile-policy.sh failed on a paths-only policy"
grep -qF 'block-destructive-bash.sh\" --bypass-only' "$SMOKE_TMP/paths-only.json" \
  || fail "a policy without destructive_bash dropped the always-on bypass-flag hook"
ok "hooks.json == compile output; bypass-flag hook wired even without destructive_bash"

# 12. block-destructive-bash.sh behaviour: always-on bypass-flag denials, no false
#     denies on text tools, command scoped to tool_input.command (python3 and
#     pure-bash paths). Fixtures are files fed on stdin; nothing here is executed.
HOOK="$PLUGIN_ROOT/hooks/block-destructive-bash.sh"
bash_event() { local c="${1//\\/\\\\}"; c="${c//\"/\\\"}"; c="${c//$'\n'/\\n}"; printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$c"; }
decision() { bash "$HOOK" "${@:2}" <"$1" | grep -oE '"permissionDecision":"[a-z]+"' | cut -d'"' -f4; }
expect() { # expect <allow|deny> <fixture-file> [hook args] [label]
  local got; got="$(decision "$2" "${@:3}")"
  [ "$got" = "$1" ] || fail "block-destructive-bash: expected $1, got '${got:-none}' for $(cat "$2")"
}
n=0
deny_cmds=(
  'claude --dangerously-skip-permissions -p "fix it"'
  'codex exec --dangerously-bypass-approvals-and-sandbox "do it"'
  'gemini --yolo'
  'some-agent --always-approve run'
  'codex --full-auto'
  'FOO=1 sudo -E claude --yolo=true'
  'echo start && claude --dangerously-skip-permissions'
  'bash -c "codex --full-auto"'
  'out=$(gemini --yolo -p hi)'
  $'echo $((1<<n))\nclaude --yolo'
  "tmux new-session -d 'claude --dangerously-skip-permissions'"
  "screen -dmS a bash -c 'codex --yolo'"
  "docker run img sh -c 'codex --yolo'"
  "script -qc 'claude --dangerously-skip-permissions' /dev/null"
  "su -c 'codex --yolo' bob"
  "ssh host 'claude --dangerously-skip-permissions'"
  'sudo -u git claude --yolo'
  'timeout -s KILL 30 codex --full-auto'
  $'echo "<<EOF"\nclaude --yolo\nEOF'
  $'cat <<EOF\n$(claude --yolo)\nEOF'
  $'sh <<\'EOF\'\nclaude --yolo\nEOF'
  $'bash <<EOF\nclaude --yolo\nEOF'
  $'bash -s <<\'EOF\'\ncodex --full-auto\nEOF'
  $'cat <<\'EOF\' | bash\nclaude --yolo\nEOF'
  $'ssh host <<\'EOF\'\nclaude --yolo\nEOF'
  $'gh codespace ssh \'claude --yolo\''
  $'gh codespace ssh -- bash -c \'claude --yolo\''
  $'gh cs ssh -- sh -c \'codex --yolo\''
  $'gh cs ssh -- claude --dangerously-skip-permissions'
  $'gh alias set x \'claude --yolo\''
  $'git rebase -x \'claude --yolo\' main'
  $'git bisect run claude --yolo'
  $'docker exec -i c sh <<EOF\nclaude --yolo\nEOF'
  $'kubectl exec -i pod -- bash <<EOF\nclaude --yolo\nEOF'
  $'sudo docker exec -i c sh <<\'EOF\'\nclaude --yolo\nEOF'
  $'(cat <<EOF) | bash\nclaude --yolo\nEOF'
  $'(cat <<\'EOF\')|bash\nclaude --yolo\nEOF'
  $'{ cat <<\'EOF\'; } | sh\nclaude --yolo\nEOF'
  $'ssh -t host bash <<\'EOF\'\nclaude --yolo\nEOF'
  $'gh pr create --body "$(claude --yolo)"'
  $'git rebase -S --exec=\'claude --yolo\' main'
  $'git rebase -m --exec=\'claude --yolo\' main'
  $'gh codespace ssh -d \'claude --yolo\''
  $'git commit -m -x \'claude --yolo\''
  $'gh pr merge 3 -d \'x --yolo\''
  $'gh pr merge 3 -d -s \'claude --full-auto\''
)
allow_cmds=(
  'grep -rn -- --yolo docs/'
  'echo "--dangerously-skip-permissions is denied by policy"'
  'git commit -m "guardrails: deny --full-auto and --always-approve"'
  'rg --fixed-strings -e --dangerously-bypass-approvals-and-sandbox plugins/'
  'ls -la'
  "git commit -m 'guardrails: deny \`--dangerously-skip-permissions\`'"
  $'gh pr create --body "$(cat <<\'EOF\'\n- guardrails now deny `--yolo`\nEOF\n)"'
  $'cat > notes.md <<\'EOF\'\nNever run `claude --dangerously-skip-permissions`.\nEOF'
  "gh issue comment 5 --body 'see \`codex --full-auto\` docs'"
  'echo $((1<<4))'
  $'cat <<\'EOF\' > notes.md\nclaude --yolo\nEOF'
  $'python3 - <<\'EOF\'\nprint(\'--yolo\')\nEOF'
  "gh pr create --title 'Deny --yolo flag' --body 'avoid --yolo please'"
  $'gh pr create --title \'Deny --yolo\' --body \'avoid --yolo; never run bash -c "claude --yolo"\''
  $'gh pr create -b \'see ssh host "claude --yolo"\''
  $'gh pr create --body=\'note --full-auto\''
  $'gh pr comment 1 --body-file - <<\'EOF\'\nclaude --yolo\nEOF'
  $'gh api -f body=\'hello bash -c foo --yolo\' repos/o/r/issues/1/comments'
  $'glab mr create --description \'drop --always-approve\' --title \'x\''
  $'git commit -m \'run bash -c "x --yolo"\''
  $'git log --grep=\'--full-auto\''
  $'grep bash <<EOF\n--yolo\nEOF'
  $'docker exec -i c sh <<\'EOF\'\nls -la\nEOF'
  $'cat <<\'EOF\' | bash\nls\nEOF'
  $'# pinned: a heredoc to an arbitrary script is data (not a known runner)\n./run.sh <<\'EOF\'\nclaude --yolo\nEOF'
  $'gh pr create --body "$(cat <<\'EOF\'\n- guardrails deny `--yolo`\nEOF\n)"'
  $'git commit -am \'msg: run bash -c "x --yolo"\''
  $'git log -S\'some text --yolo\''
  $'gh pr create -t \'x --yolo\' -b \'y --full-auto\''
  $'gh api -f body=\'a --yolo b\' repos/o/r/issues/1/comments'
  $'gh pr create -t T -b \'- removes --yolo\''
  $'gh pr create --title T --body \'- guardrails now deny --yolo\''
  $'gh pr create --body \'- guardrails now deny --dangerously-skip-permissions\''
  $'git commit -m \'- drop --yolo from docs\''
  $'git commit --message \'- deny --yolo\''
  $'git commit -m \'-- deny --yolo\''
  $'gh pr merge 3 --squash -t \'x --yolo\''
  $'gh repo create o/r -d \'no --yolo here\''
  $'gh gist create -d \'about --full-auto\' f.txt'
  $'gh pr merge 3 -d -b \'merged; see --yolo note\''
  $'gh pr merge 3 -F - -t \'x --full-auto\''
)
for c in "${deny_cmds[@]}"; do n=$((n+1)); bash_event "$c" >"$SMOKE_TMP/d$n.json"; expect deny "$SMOKE_TMP/d$n.json"; expect deny "$SMOKE_TMP/d$n.json" --bypass-only; done
for c in "${allow_cmds[@]}"; do n=$((n+1)); bash_event "$c" >"$SMOKE_TMP/a$n.json"; expect allow "$SMOKE_TMP/a$n.json"; done
# Scoping: a "command" key outside tool_input neither hides nor replaces the real one.
printf '{"command":"ls","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' >"$SMOKE_TMP/decoy-first.json"
printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"extra":{"command":"rm -rf /"}}' >"$SMOKE_TMP/decoy-after.json"
printf '{"tool_name":"Bash","command":"rm -rf /","tool_input":{"description":"list"}}' >"$SMOKE_TMP/no-command.json"
expect deny  "$SMOKE_TMP/decoy-first.json"
expect allow "$SMOKE_TMP/decoy-after.json"
expect allow "$SMOKE_TMP/no-command.json"
bash_event 'rm -rf /' >"$SMOKE_TMP/rmroot.json"
expect deny  "$SMOKE_TMP/rmroot.json"
expect allow "$SMOKE_TMP/rmroot.json" --bypass-only
# The pure-bash fallback (no python3 on PATH) keeps the same verdicts on these cases.
NOPY="$SMOKE_TMP/nopy-bin"; mkdir -p "$NOPY"
for t in cat tr sed grep head awk dirname cut; do
  p="$(command -v "$t")" && ln -s "$p" "$NOPY/$t"
done
BASH_BIN="$(command -v bash)"
nopy() { PATH="$NOPY" "$BASH_BIN" "$HOOK" <"$1" | grep -oE '"permissionDecision":"[a-z]+"' | cut -d'"' -f4; }
for f in d1 d3 d5 d7; do [ "$(nopy "$SMOKE_TMP/$f.json")" = deny ] || fail "no-python fallback did not deny $(cat "$SMOKE_TMP/$f.json")"; done
n_allow_first=$(( ${#deny_cmds[@]} + 1 ))
for i in 0 1 2; do f="a$((n_allow_first + i))"; [ "$(nopy "$SMOKE_TMP/$f.json")" = allow ] || fail "no-python fallback falsely denied $(cat "$SMOKE_TMP/$f.json")"; done
[ "$(nopy "$SMOKE_TMP/decoy-first.json")" = deny ] || fail "no-python fallback read a decoy \"command\" key outside tool_input"
ok "bypass flags always denied (${#deny_cmds[@]} forms incl. launchers, wrapper option values, heredoc/arithmetic edges, heredocs fed to sh/bash/ssh, to a shell argument (docker/kubectl exec) or piped into a shell incl. ( )/{ } groups; gh/git launchers: codespace ssh (-d), alias set, rebase -x/-S/-m --exec, bisect run); single-quoted and quoted-heredoc text, heredocs to non-shells (./run.sh pinned allow), gh/glab/git prose option values (short letters per subcommand) and text tools pass (${#allow_cmds[@]}); command scoped to tool_input.command; pure-bash fallback agrees"

echo ""
echo "smoke passed: 12/12 checks"
