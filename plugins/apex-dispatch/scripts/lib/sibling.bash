# sibling.bash — find a sibling plugin of this marketplace (sourced; bash 3.2 safe).
# The same rule as scripts/lib/sibling.py: a marketplace checkout keeps siblings at
# <root>/../<name>; the Claude Code plugin cache keeps <root>/../../<name>/<version>/,
# often several versions at once. The highest version (from each candidate's
# .claude-plugin/plugin.json) wins, never the first match of a glob.

# _apex_plugin_version DIR -> X.Y.Z or nothing
_apex_plugin_version() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' \
    "$1/.claude-plugin/plugin.json" 2>/dev/null | head -n 1
}

# _apex_version_key X.Y.Z -> a zero-padded string that sorts like the version
_apex_version_key() {
  local IFS=.
  # shellcheck disable=SC2086
  set -- $1
  printf '%06d%06d%06d' "${1:-0}" "${2:-0}" "${3:-0}"
}

# apex_sibling ROOT NAME [ENV_VAR] -> prints the chosen sibling directory (or nothing).
# ENV_VAR (for example APEX_SCOPE_LOOP_ROOT) wins when it names a plugin directory.
apex_sibling() {
  local root="$1" name="$2" envvar="${3:-}" c v k best="" bestk=""
  if [[ -n "$envvar" ]]; then
    eval "c=\${$envvar:-}"
    if [[ -n "$c" && -n "$(_apex_plugin_version "$c")" ]]; then
      (cd "$c" && pwd -P)
      return 0
    fi
  fi
  for c in "$root/../$name" "$root"/../../"$name"/*/; do
    c="${c%/}"
    v="$(_apex_plugin_version "$c")"
    [[ -n "$v" ]] || continue
    k="$(_apex_version_key "$v")"
    if [[ -z "$bestk" || "$k" > "$bestk" ]]; then
      bestk="$k"
      best="$c"
    fi
  done
  [[ -n "$best" ]] && (cd "$best" && pwd -P)
  return 0
}

# apex_scope_loop_scripts ROOT -> apex-scope-loop's skills/apex-execute/scripts (or nothing)
apex_scope_loop_scripts() {
  local d
  d="$(apex_sibling "$1" apex-scope-loop APEX_SCOPE_LOOP_ROOT)"
  [[ -n "$d" && -f "$d/skills/apex-execute/scripts/_lib.sh" ]] && printf '%s\n' "$d/skills/apex-execute/scripts"
  return 0
}
