#!/usr/bin/env bash
# Copies the code templates into the site, filling the ten placeholders.
# Never overwrites: a file that already exists is listed as MERGE. The run
# writes a filled copy of its template (the same fill as a NEW file) to
# ~/.config/<slug>/merge/<path>, owner-only, and prints that path. MERGE means:
# open the site's file and that filled copy, carry the template's guards into
# the site's file, keep one file (never two copies of a gate or a config), show
# the diff, save on a yes. An existing next, vitest or drizzle config of any
# extension is MERGE too, and so is proxy.ts on a Next 16 site that has its own
# middleware.ts (fold it in, then delete it).
#
#   copy-templates.sh --site <slug> plan|run
#
# Placeholders: __SITE_NAME__ __EMAIL_DOMAINS__ __DOMAIN__ __VERCEL_HOST__ __SRC_ROOT__
# __SESSION_IDLE_MINUTES__ __SESSION_MAX_HOURS__ __ROLE_SOURCE__ __JOIN_MODE__ __ALLOW_GUESTS__
# (escaped by lib.sh fill, so a name with & or quotes cannot break the code).
#
# PASSWORD_LANE=off leaves out scripts/dev-test-user.ts. The sign-in page
# imports src/app/sign-in/password-sign-in-form.tsx, so that file is always
# copied; it renders only where passwordSignInAllowed() is true, which
# ALLOW_PASSWORD_SIGNIN=false (what PASSWORD_LANE=off sets) never is.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
[ "${1:-}" = "--site" ] || die "Usage: copy-templates.sh --site <slug> plan|run"
load_config "${2:-}"; shift 2
MODE="${1:-plan}"
[ "$MODE" = "plan" ] || [ "$MODE" = "run" ] || die "Mode is plan or run."
[ -n "${SITE_DIR:-}" ] && [ -d "$SITE_DIR" ] || die "SITE_DIR is not a folder."
need node
[ -f "$SITE_DIR/package.json" ] || die "No package.json in $SITE_DIR. This skill sets up a Node website."
( cd "$SITE_DIR" && node -e 'JSON.parse(require("fs").readFileSync("package.json","utf8"))' ) >/dev/null 2>&1 \
  || die "package.json in $SITE_DIR cannot be read as JSON. A merge conflict marker or a trailing comma is the usual cause: fix it, then re-run."
: "${SITE_TITLE:?SITE_TITLE missing in config}"
[ -n "$EMAIL_DOMAINS" ] || die "EMAIL_DOMAINS is empty in the config. It names the organisation's email domains (preflight suggests them)."

SRC="$SKILL_DIR/templates"
ROOT_SRC="src"
[ -d "$SITE_DIR/src/app" ] || { [ -d "$SITE_DIR/app" ] && ROOT_SRC="."; }

# The installed version first (a range like "latest" says nothing), then the range.
NEXT_MAJOR="$(cd "$SITE_DIR" && node -e "
let v='';
try { v=require('./node_modules/next/package.json').version } catch {}
if (!v) { const p=require('./package.json'); v=({...p.devDependencies,...p.dependencies}).next||'' }
process.stdout.write((String(v).match(/[0-9]+/)||['0'])[0])" 2>/dev/null || true)"
[ "$NEXT_MAJOR" -gt 0 ] 2>/dev/null || die "Could not read the Next.js version in $SITE_DIR. Install the site's packages first (npm install)."

# write_filled <rel> <out>: the template filled for this site, exactly as a NEW
# file would be written (placeholders, no-redirect vercel.json, Next 15 name).
write_filled() {
  local rel="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  fill "$SRC/$rel" > "$out"
  # A placeholder the fill does not know would ship as text: say so.
  if grep -Eq '__[A-Z][A-Z_]*[A-Z]__' "$out"; then
    note "WARNING: $rel still holds a placeholder after the fill ($(grep -Eo '__[A-Z][A-Z_]*[A-Z]__' "$out" | sort -u | paste -sd' ' -)). Fill it by hand from the config before the build."
  fi
  case "$rel" in
    vercel.json)
      # No .vercel.app host: no canonical-host redirect. Filling the domain in
      # its place would redirect the domain to itself, forever.
      if [ -z "${VERCEL_HOST:-}" ]; then
        node -e "const f=process.argv[1];const j=JSON.parse(require('fs').readFileSync(f,'utf8'));delete j.redirects;require('fs').writeFileSync(f,JSON.stringify(j,null,2)+'\\n')" "$out"
        note "VERCEL_HOST is empty: vercel.json has no canonical-host redirect (control C24 is then N/A)"
      fi ;;
    src/proxy.ts)
      if [ "$NEXT_MAJOR" -lt 16 ]; then
        sed -i.bak -e 's/^export function proxy(/export function middleware(/' "$out" && rm -f "$out.bak"
        # The gate reads the session from the database, which the Edge runtime
        # (Next 15's default for middleware) cannot: Node.js, from 15.5.
        node -e 'const fs=require("fs"),f=process.argv[1];const s=fs.readFileSync(f,"utf8");const t=s.replace(/^export const config = \{$/m,"export const config = {\n  runtime: \"nodejs\",");if(t===s){process.exit(1)}fs.writeFileSync(f,t)' "$out" \
          || note "WARNING: $rel: add runtime: \"nodejs\" as the first line inside its config object by hand (Next 15 runs middleware on the Edge runtime otherwise)"
        note "next $NEXT_MAJOR: written as middleware.ts with export middleware and runtime: \"nodejs\" (Next 15.5 or later)"
      fi ;;
  esac
}

# MERGE copies are filled too, and kept outside the site (owner-only), so no
# unfilled __PLACEHOLDER__ ever reaches the person or the site.
MERGE_DIR="$CONFIG_DIR/merge"

# copy_one <rel> <dest> [old]: [old] is a site file the new one replaces (a
# Next 16 site's own middleware), which makes it MERGE even though dest is new.
copy_one() {
  local rel="$1" dest="$2" old="${3:-}" site_rel filled why="the site has it"
  site_rel="${dest#"$SITE_DIR"/}"
  [ -n "$old" ] && why="the site has its own $old: fold it into $site_rel, then delete $old; Next 16 refuses to build with both"
  if [ -e "$dest" ] || [ -n "$old" ]; then
    filled="$MERGE_DIR/$site_rel"
    # The template's own extension, so a TypeScript copy is never named .mjs.
    [ "${rel##*.}" = "${site_rel##*.}" ] || filled="$MERGE_DIR/${site_rel%.*}.${rel##*.}"
    if [ "$MODE" = "run" ]; then
      (umask 077; mkdir -p "$MERGE_DIR"; write_filled "$rel" "$filled")
      chmod 600 "$filled"
      printf '  MERGE  %s (%s; merge in by hand from the filled copy %s)\n' "$site_rel" "$why" "$filled"
    else
      printf '  MERGE  %s (%s; the run writes a filled copy to merge from: %s)\n' "$site_rel" "$why" "$filled"
    fi
    return 0
  fi
  printf '  NEW    %s\n' "$site_rel"
  [ "$MODE" = "run" ] || return 0
  write_filled "$rel" "$dest"
}

head1 "Code templates into $SITE_DIR"
cd "$SRC"
find . -type f ! -path './examples/*' | sed 's|^\./||' | sort | while read -r rel; do
  dest="$SITE_DIR/$rel"; old=""
  case "$rel" in
    src/*) if [ "$ROOT_SRC" = "." ]; then dest="$SITE_DIR/${rel#src/}"; else dest="$SITE_DIR/$ROOT_SRC/${rel#src/}"; fi ;;
    # Filled (its schema paths name the site's own src root) and written as
    # drizzle.config.ts when the site has none; MERGE when it has one.
    drizzle.config.example.ts)
      dest="$SITE_DIR/drizzle.config.ts"
      for f in drizzle.config.ts drizzle.config.mts drizzle.config.js drizzle.config.mjs; do
        [ -e "$SITE_DIR/$f" ] && { dest="$SITE_DIR/$f"; break; }
      done ;;
    # Next loads next.config.js or .mjs before .ts, so a template written beside
    # the site's own config would never take effect: MERGE into the site's file.
    next.config.ts)
      for f in next.config.js next.config.mjs next.config.cjs next.config.ts next.config.mts; do
        [ -e "$SITE_DIR/$f" ] && { dest="$SITE_DIR/$f"; break; }
      done ;;
    # Vitest loads the first vitest.config.* it finds (.ts before .mts), so a
    # second config beside the site's own would be silently ignored: MERGE into
    # it. A vite.config.* with a test block is the site's test config too.
    vitest.config.mts)
      for f in vitest.config.ts vitest.config.mts vitest.config.cts vitest.config.js vitest.config.mjs vitest.config.cjs; do
        [ -e "$SITE_DIR/$f" ] && { dest="$SITE_DIR/$f"; break; }
      done
      if [ "$dest" = "$SITE_DIR/vitest.config.mts" ] && [ ! -e "$dest" ]; then
        for f in vite.config.ts vite.config.mts vite.config.cts vite.config.js vite.config.mjs vite.config.cjs; do
          [ -e "$SITE_DIR/$f" ] && grep -Eq '(^|[^A-Za-z0-9_])test[[:space:]]*:' "$SITE_DIR/$f" && { dest="$SITE_DIR/$f"; break; }
        done
      fi ;;
  esac
  if [ "$rel" = "src/proxy.ts" ]; then
    if [ "$NEXT_MAJOR" -lt 16 ]; then
      dest="$(dirname "$dest")/middleware.ts"
    elif [ ! -e "$dest" ]; then
      # Next 16 still runs a middleware file, but stops the build when it sits
      # beside proxy.ts: the site's gate is folded into proxy.ts, never kept as two.
      for f in middleware.ts middleware.js; do
        [ -e "$(dirname "$dest")/$f" ] && { old="$(dirname "${dest#"$SITE_DIR"/}")/$f"; old="${old#./}"; break; }
      done
    fi
  fi
  if [ "$rel" = "src/lib/db.ts" ] && [ -e "$dest" ]; then
    note "the site has its own src/lib/db.ts: keep it; it must export getDb() and Database, and include both sign-in schema files"
    continue
  fi
  if [ "$rel" = "src/lib/m365/graph-app-client.ts" ] && [ "$NEEDS_M365_SERVER" != "yes" ]; then continue; fi
  case "$rel" in
    scripts/dev-test-user.ts)
      if [ "$PASSWORD_LANE" = off ]; then note "skipped: $rel (PASSWORD_LANE=off: no test sign-in lane anywhere)"; continue; fi ;;
    src/app/sign-in/password-sign-in-form.tsx)
      [ "$PASSWORD_LANE" = off ] && note "$rel is copied because the sign-in page imports it; with PASSWORD_LANE=off it never renders and the server refuses the lane" ;;
    scripts/seed-people.ts) note "scripts/seed-people.ts seeds the site's people list from $PEOPLE_FILE (written by the group step)" ;;
    scripts/set-person.ts) note "scripts/set-person.ts changes one person later (role, or leaving)" ;;
  esac
  if [ "$rel" = "drizzle/access_append_only.sql" ]; then
    note "drizzle/access_append_only.sql is pasted into the migration from: npx drizzle-kit generate --custom --name access_append_only"
  fi
  copy_one "$rel" "$dest" "$old"
done
# create-next-app ignores .env*, which would keep .env.example (names only, no
# values) out of git. Un-ignore that one file; .env.local stays ignored.
if [ "$MODE" = "run" ] && ( cd "$SITE_DIR" && git rev-parse --git-dir >/dev/null 2>&1 && git check-ignore -q .env.example ); then
  printf '\n# entra-id-auth: the names-only example is committed; real values never are.\n!.env.example\n' >> "$SITE_DIR/.gitignore"
  note ".gitignore: added !.env.example (it was ignored)"
elif [ "$MODE" = "plan" ]; then
  note "if .gitignore ignores .env.example, the run adds !.env.example (names only; .env.local stays ignored)"
fi
if ! in_git_repo "$SITE_DIR"; then note "WARNING: $SITE_DIR $NOT_A_REPO_HINT"
elif ! ( cd "$SITE_DIR" && git check-ignore -q .env.local 2>/dev/null ); then note "WARNING: .env.local is not git-ignored in $SITE_DIR. Add .env*.local to .gitignore before any secret is written."; fi
grep -q '"@/\*"' "$SITE_DIR/tsconfig.json" 2>/dev/null || note "WARNING: tsconfig.json has no \"@/*\" path. Add \"paths\": {\"@/*\": [\"./$ROOT_SRC/*\"]} or every import breaks."
APP_REL="$ROOT_SRC/app"; [ "$ROOT_SRC" = "." ] && APP_REL="app"
note "the protected layout is not copied: create $APP_REL/(app)/layout.tsx from examples/protected-layout.tsx and move every signed-in page under $APP_REL/(app)/ ($APP_REL/page.tsx becomes $APP_REL/(app)/page.tsx and still serves /; move with it anything it imports by a relative path, such as page.module.css). Never put it in the root $APP_REL/layout.tsx: that one also wraps /sign-in, which would then redirect to itself."
note "every page, layout, template and default file under $APP_REL/(app)/ calls requirePagePerson() as its first line (examples/protected-page.tsx). tests/unit/auth/page-checks.test.ts parses each gated file and fails on one that does not start with the awaited check (a comment does not count; each exported route method on its own), as a second layer; the proxy, which reads the person before anything renders, is the gate itself. A layout's redirect alone protects nothing: Next renders the page beside it and sends it in the body of the 307 (verify-site.sh, C26)."
note "examples/route-handler.ts: every exported method of every route handler (GET, POST, PUT, PATCH, DELETE), and every server action, calls requireCurrentPerson() or requireAdministrator() first. The proxy checks the sign-in, never the role. page-checks.test.ts reads route files and every server action a signed-in page uses (the file sits in or below that page's folder, or the page imports it, directly or through other files; it skips a file used only by public pages, such as sign-in/actions.ts, which must then do nothing a stranger may not). An action file no page imports is checked by eye, as is which of the two calls an action needs."
note "drizzle.config.ts: written from the template when the site had none; when it is MERGE, add both sign-in schema files to its schema list."
note "next config: written as next.config.ts when the site had none; when it is MERGE, carry the security headers and poweredByHeader: false into the site's own next.config file (Next reads only one). Until that merge is saved, security-headers.test.ts fails (\"expected undefined to be false\")."
note "vitest config: written as vitest.config.mts when the site had none; when it is MERGE, add the \"@\" alias and the tests/**/*.test.ts include to the site's own config."
[ "$MODE" = "plan" ] && printf '\n(plan only: nothing was copied)\n'
exit 0
