#!/bin/bash
# link-plugin-skills.sh
#
# Claude Code discovers skills at skills/<name>/SKILL.md (flat).
# Local plugins may organize skills in category subdirectories
# (e.g. skills/dev/<name>/, skills/workflow/<name>/).
#
# This script reads installed plugin paths, translates host paths to
# container paths using DEV_ROOT, finds nested skill directories,
# and symlinks them into ~/.claude/skills/ for auto-discovery.
#
# Safe: skips skills that already exist (official plugins take precedence).
# Idempotent: symlinks are recreated fresh each container start.

set -euo pipefail

SKILLS_BASE="/home/claude/.claude/skills"
PLUGINS_JSON="/home/claude/.claude/plugins/installed_plugins.json"

[ -f "$PLUGINS_JSON" ] || exit 0
[ -d "$SKILLS_BASE" ] || exit 0

# Translate a host installPath to its container equivalent.
# Uses DEV_ROOT env var (host _dev path) mapped to /mac/_dev mount.
# Falls back to /proc/mounts detection if DEV_ROOT is unset.
translate_path() {
  local host_path="$1"

  if [ -n "${DEV_ROOT:-}" ] && [ -d "/mac/_dev" ]; then
    echo "${host_path/"$DEV_ROOT"//mac/_dev}"
    return
  fi

  # Fallback: detect mount source from /proc/mounts
  if [ -d "/mac/_dev" ]; then
    local mount_src
    mount_src=$(awk '$2 == "/mac/_dev" { print $1; exit }' /proc/mounts 2>/dev/null || true)
    if [ -n "$mount_src" ]; then
      echo "${host_path/"$mount_src"//mac/_dev}"
      return
    fi
  fi

  # Last resort: return unchanged (may not resolve in container)
  echo "$host_path"
}

# Read all installPaths from installed_plugins.json
install_paths=$(python3 -c "
import json, sys
with open('$PLUGINS_JSON') as f:
    d = json.load(f)
for installs in d.get('plugins', {}).values():
    for i in installs:
        p = i.get('installPath', '')
        if p:
            print(p)
" 2>/dev/null)

[ -n "$install_paths" ] || exit 0

linked=0
while IFS= read -r install_path; do
  container_path=$(translate_path "$install_path")
  skills_dir="${container_path}/skills"

  [ -d "$skills_dir" ] || continue

  # Walk: skills/<category>/<name>/SKILL.md
  for category_dir in "$skills_dir"/*/; do
    [ -d "$category_dir" ] || continue
    # Skip if this is already a flat skill (has SKILL.md directly)
    [ -f "${category_dir}SKILL.md" ] && continue

    for skill_dir in "$category_dir"*/; do
      [ -d "$skill_dir" ] || continue
      [ -f "${skill_dir}SKILL.md" ] || continue

      skill_name=$(basename "$skill_dir")
      target="$SKILLS_BASE/$skill_name"

      # Don't overwrite existing skills (official plugins take precedence)
      if [ -e "$target" ] || [ -L "$target" ]; then
        continue
      fi

      ln -sf "$skill_dir" "$target"
      linked=$((linked + 1))
    done
  done
done <<< "$install_paths"

if [ "$linked" -gt 0 ]; then
  chown -R claude:claude "$SKILLS_BASE" 2>/dev/null || true
  echo "Linked $linked nested skill(s) into ~/.claude/skills/"
fi
