#!/usr/bin/env bash
# Skill shape check: what `claude plugin validate` does not check.
#   - SKILL.md has frontmatter, and its `name` equals the skill's folder name
#   - frontmatter uses only the portable Agent Skills keys
#   - `description` is 1 to 1024 characters
#   - SKILL.md carries no version that differs from .claude-plugin/plugin.json
#   - SKILL.md is under 500 lines
#   - every link into references/ resolves, from SKILL.md and from each
#     reference file
# Exit 0 when clean, 1 on any failure. Runs on macOS (bash 3.2) and Linux.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SKILL_DIR="$ROOT/skills/entra-id-auth"
SKILL_MD="$SKILL_DIR/SKILL.md"
ALLOWED_KEYS="name description license compatibility metadata"

FAIL=0
fail() { printf 'FAIL: %s\n' "$*"; FAIL=1; }

[ -f "$SKILL_MD" ] || { echo "FAIL: $SKILL_MD not found"; exit 1; }
[ "$(head -1 "$SKILL_MD")" = "---" ] || fail "SKILL.md does not start with a --- frontmatter line"

# The frontmatter: the lines between the first and the second "---".
FRONTMATTER="$(awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside {print}' "$SKILL_MD")"
[ -n "$FRONTMATTER" ] || fail "SKILL.md has an empty or unclosed frontmatter block"

# Top-level keys only (nested lines start with a space; comments are skipped).
KEYS="$(printf '%s\n' "$FRONTMATTER" | grep -E '^[A-Za-z0-9_-]+:' | sed 's/:.*//' || true)"
for key in $KEYS; do
  case " $ALLOWED_KEYS " in
    *" $key "*) ;;
    *) fail "frontmatter key '$key' is not portable; allowed: $ALLOWED_KEYS" ;;
  esac
done

strip_quotes() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"; }

NAME="$(printf '%s\n' "$FRONTMATTER" | sed -n 's/^name:[[:space:]]*//p' | head -1 | strip_quotes)"
FOLDER="$(basename "$SKILL_DIR")"
[ -n "$NAME" ] || fail "frontmatter has no name"
[ "$NAME" = "$FOLDER" ] || fail "frontmatter name '$NAME' does not equal the folder name '$FOLDER'"

# description: one line, or a block scalar (| or >) of indented lines.
DESC_FIRST="$(printf '%s\n' "$FRONTMATTER" | sed -n 's/^description:[[:space:]]*//p' | head -1)"
case "$DESC_FIRST" in
  "|"* | ">"*)
    DESC="$(printf '%s\n' "$FRONTMATTER" | awk '/^description:/ {on=1; next} on && /^[^[:space:]]/ {exit} on {sub(/^[[:space:]]+/, ""); printf "%s ", $0}' | sed 's/[[:space:]]*$//')"
    ;;
  *) DESC="$(printf '%s\n' "$DESC_FIRST" | strip_quotes)" ;;
esac
DESC_LEN=${#DESC}
[ "$DESC_LEN" -ge 1 ] || fail "frontmatter description is empty"
[ "$DESC_LEN" -le 1024 ] || fail "frontmatter description is $DESC_LEN characters; the limit is 1024"

# The version lives in .claude-plugin/plugin.json. SKILL.md carries none; if a
# metadata.version is ever added, it must equal plugin.json's.
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
PLUGIN_VERSION="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" | head -1)"
[ -n "$PLUGIN_VERSION" ] || fail ".claude-plugin/plugin.json has no version"
SKILL_VERSION="$(printf '%s\n' "$FRONTMATTER" | awk '/^metadata:/ {on=1; next} on && /^[^[:space:]]/ {exit} on' | sed -n 's/^[[:space:]]*version:[[:space:]]*//p' | head -1 | strip_quotes)"
if [ -n "$SKILL_VERSION" ] && [ "$SKILL_VERSION" != "$PLUGIN_VERSION" ]; then
  fail "SKILL.md metadata.version '$SKILL_VERSION' differs from plugin.json's '$PLUGIN_VERSION'; drop it from SKILL.md or keep the two equal"
fi

LINES="$(wc -l < "$SKILL_MD" | tr -d ' ')"
[ "$LINES" -lt 500 ] || fail "SKILL.md is $LINES lines; it must stay under 500"

# Links into references/: markdown links in SKILL.md and in every reference
# file, plus plain `references/<file>` mentions in SKILL.md. Each is resolved
# from the file that holds it; anchors are dropped; web links are skipped.
LINKS=0
check_target() {
  local from="$1" target="$2" path
  target="${target%%#*}"
  [ -n "$target" ] || return 0
  case "$target" in http://* | https://* | mailto:*) return 0 ;; esac
  path="$(dirname "$from")/$target"
  LINKS=$((LINKS + 1))
  [ -e "$path" ] || fail "${from#"$ROOT"/} links to '$target', which does not exist"
}

FILES="$SKILL_MD"
if [ -d "$SKILL_DIR/references" ]; then
  for f in "$SKILL_DIR"/references/*.md; do
    [ -e "$f" ] && FILES="$FILES
$f"
  done
fi

while IFS= read -r file; do
  [ -n "$file" ] || continue
  while IFS= read -r target; do
    [ -n "$target" ] && check_target "$file" "$target"
  done <<EOF_LINKS
$(grep -oE '\]\([^)[:space:]]+\)' "$file" | sed -e 's/^](//' -e 's/)$//' || true)
EOF_LINKS
done <<EOF_FILES
$FILES
EOF_FILES

while IFS= read -r target; do
  [ -n "$target" ] && check_target "$SKILL_MD" "$target"
done <<EOF_MENTIONS
$(grep -oE 'references/[A-Za-z0-9._/-]+\.md' "$SKILL_MD" | sort -u || true)
EOF_MENTIONS

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo "check-skill: clean (name $NAME, $LINES lines, description $DESC_LEN characters, $LINKS links resolved)."
