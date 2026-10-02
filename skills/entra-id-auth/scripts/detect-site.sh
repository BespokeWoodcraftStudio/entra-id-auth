#!/usr/bin/env bash
# Read only. Looks at a website's folder and says what it is built with, so
# the skill knows whether the templates fit as they are.
#
#   detect-site.sh <site-folder>
#
# Prints one line per fact and a verdict: FITS, ADAPT (what differs) or STOP.
# Exits 0 on FITS or ADAPT, 1 on any STOP. A STOP is about the code only: the
# tenant half and the control checklist still apply to any site.
set -euo pipefail
# Every precondition below stops with its own STOP line and exit 1: never a
# crash, never a silent exit.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
stop() { printf 'STOP: %s\n' "$*"; exit 1; }
STILL="The tenant half (groups, apps, consent, MFA) and references/controls.md still apply; references/adapting.md says what carries over."

DIR="${1:-.}"
[ -d "$DIR" ] || stop "no folder $DIR."
cd "$DIR" || stop "cannot open the folder $DIR."
[ -f package.json ] || stop "no package.json in $DIR. This skill sets up a Node website. $STILL"
command -v node >/dev/null 2>&1 || stop "Node is not installed (no node on PATH). $NODE_NEED $NODE_FIX"
# A file named node is not proof that Node runs: a version manager's shim with
# no version chosen (nvm, asdf, volta, mise) is on PATH and exits non-zero.
NODE_V="$(node -p process.versions.node 2>/dev/null)" || NODE_V=""
printf '%s' "$NODE_V" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || stop "node is on PATH ($(command -v node)) but does not run: a version manager (nvm, asdf, volta, mise) with no version chosen, or a broken install. $NODE_NEED $NODE_FIX"
# Parsed once here, so a broken file stops with its reason instead of killing
# every later read of it.
PKG_ERR="$(node -e 'try{const p=JSON.parse(require("fs").readFileSync("package.json","utf8"));if(!p||typeof p!=="object"||Array.isArray(p))throw new Error("it is not a JSON object")}catch(e){process.stdout.write(String(e.message).split("\n")[0]);process.exit(1)}' 2>/dev/null)" \
  || stop "package.json in $(pwd) cannot be read as JSON (${PKG_ERR:-unreadable}). A merge conflict marker or a trailing comma is the usual cause: fix it, then re-run."

# dep <name>: the range package.json gives it, or nothing. Never fails: the
# file parsed above.
dep() { node -e 'const p=JSON.parse(require("fs").readFileSync("package.json","utf8"));const v={...p.dependencies,...p.devDependencies}[process.argv[1]];process.stdout.write(typeof v==="string"?v:"")' "$1" 2>/dev/null || true; }
# installed <name>: the version in node_modules, or nothing.
installed() { node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync("node_modules/"+process.argv[1]+"/package.json","utf8")).version||""))}catch{}' "$1" 2>/dev/null || true; }
# first_version <text>: the first x.y.z (or x.y, or x) in a version or range.
first_version() { printf '%s' "$1" | grep -Eo '[0-9]+(\.[0-9]+){0,2}' | head -1 || true; }

NEXT="$(dep next)"; BA="$(dep better-auth)"; DRIZZLE="$(dep drizzle-orm)"; KIT="$(dep drizzle-kit)"
PGJS="$(dep postgres)"; PGNODE="$(dep pg)"; NEON="$(dep @neondatabase/serverless)"; PRISMA="$(dep prisma)$(dep @prisma/client)"
NEXTAUTH="$(dep next-auth)"; AUTHJS="$(dep @auth/core)"; CLERK="$(dep @clerk/nextjs)"; MSAL="$(dep @azure/msal-browser)$(dep @azure/msal-node)$(dep @azure/msal-react)"
ZOD="$(dep zod)"; VITEST="$(dep vitest)"

APPDIR=""
[ -d src/app ] && APPDIR="src/app"
[ -z "$APPDIR" ] && [ -d app ] && APPDIR="app"
PAGES=""
if [ -d src/pages ] || [ -d pages ]; then PAGES="yes"; fi
GATE=""
for f in src/proxy.ts src/middleware.ts proxy.ts middleware.ts src/middleware.js middleware.js; do [ -f "$f" ] && GATE="$GATE $f"; done

# The linked Vercel project, by name and team (the id alone says little).
VPROJ="not linked"
if [ -f .vercel/project.json ]; then
  VPROJ="$(node -e '
try {
  const j = JSON.parse(require("fs").readFileSync(".vercel/project.json", "utf8"));
  const name = j.projectName ? String(j.projectName) : "(name not recorded; vercel project ls shows it)";
  const team = j.orgId ? String(j.orgId) : "unknown";
  process.stdout.write(name + " (id " + String(j.projectId || "none") + "), team " + team + (String(j.orgId || "").startsWith("team_") ? "" : " (a personal account)"));
} catch { process.stdout.write(".vercel/project.json is not valid JSON"); }' 2>/dev/null || true)"
fi

echo "## The website"
echo "- folder: $(pwd)"
echo "- next: ${NEXT:-none}$( v="$(installed next)"; [ -n "$v" ] && printf ' (installed %s)' "$v")"
if [ -n "$APPDIR" ]; then ROUTER="App Router in $APPDIR${PAGES:+ (a pages folder also exists)}"
elif [ -n "$PAGES" ]; then ROUTER="Pages Router only"
else ROUTER="none found"; fi
echo "- router: $ROUTER"
echo "- better-auth: ${BA:-none}$( v="$(installed better-auth)"; [ -n "$v" ] && printf ' (installed %s)' "$v")"
echo "- drizzle-orm: ${DRIZZLE:-none}; drizzle-kit: ${KIT:-none}"
DRIVERS="${PGJS:+postgres $PGJS}${PGNODE:+ pg $PGNODE}${NEON:+ neon-serverless $NEON}${PRISMA:+ prisma}"
OTHER_AUTH="${NEXTAUTH:+next-auth $NEXTAUTH }${AUTHJS:+@auth/core $AUTHJS }${CLERK:+clerk $CLERK }${MSAL:+msal }"
echo "- postgres driver: ${DRIVERS:-none}"
echo "- other sign-in libraries: ${OTHER_AUTH:-none}"
echo "- zod: ${ZOD:-none}; vitest: ${VITEST:-none}"
echo "- node: $NODE_V"
echo "- request gate file:${GATE:- none}"
NEXT_CONFIG=""
for f in next.config.js next.config.mjs next.config.cjs next.config.ts next.config.mts; do [ -f "$f" ] && NEXT_CONFIG="$NEXT_CONFIG $f"; done
echo "- next config file:${NEXT_CONFIG:- none}"
echo "- vercel.json: $([ -f vercel.json ] && echo yes || echo no)"
echo "- linked Vercel project: $VPROJ"
echo "- tsconfig @/ alias: $(grep -q '"@/\*"' tsconfig.json 2>/dev/null && echo yes || echo no)"
if ! command -v git >/dev/null 2>&1; then
  echo "- .env.local ignored by git: git is not installed, so nothing keeps .env.local out of commits. Install git with the system's package manager, then re-run."
elif git rev-parse --git-dir >/dev/null 2>&1; then
  echo "- .env.local ignored by git: $(git check-ignore -q .env.local 2>/dev/null && echo yes || echo NO)"
else
  echo "- .env.local ignored by git: NOT A GIT REPOSITORY yet. Set git user.name and user.email, run git init (and a first commit), then re-run."
fi
echo "- existing sign-in routes: $(ls -d "${APPDIR:-src/app}/api/auth" 2>/dev/null || echo none)"

echo
echo "## Verdict"
[ -n "$NEXT" ] || stop "no next in package.json (dependencies or devDependencies): not a Next.js site, so the code templates do not apply. $STILL"
[ -n "$APPDIR" ] || stop "next $NEXT, but no app/ or src/app/ folder: a Pages Router only site. The gate, layout and sign-in page are App Router code, so the code is not copied. $STILL"
# vitest 5 asks for node ^22.12.0 || ^24.0.0 || >=26.0.0; Next 16 alone would take 20.9.
NODE_MAJOR="${NODE_V%%.*}"; NODE_MINOR="${NODE_V#*.}"; NODE_MINOR="${NODE_MINOR%%.*}"
if ! { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -ge 12 ]; } && [ "$NODE_MAJOR" -ne 24 ] && [ "$NODE_MAJOR" -lt 26 ]; then
  stop "Node $NODE_V at $(command -v node): $NODE_NEED $NODE_FIX"
fi
# The installed version first (a range like "latest" says nothing), then the
# first number in the range (">=15 <17", "npm:next@^16").
NEXT_V="$(installed next)"; [ -n "$NEXT_V" ] || NEXT_V="$(first_version "$NEXT")"
MAJOR="${NEXT_V%%.*}"
printf '%s' "$MAJOR" | grep -Eq '^[0-9]+$' && [ "$MAJOR" -gt 0 ] \
  || stop "could not read the Next.js version (package.json says \"$NEXT\" and node_modules/next has none). Install the site's packages first (npm install), then re-run."
[ "$MAJOR" -le 14 ] && stop "next $NEXT_V is 14 or older. The CSP nonce and the async request APIs differ too much to carry by hand: upgrade to Next 16 first. $STILL"
[ -n "$NEXTAUTH$AUTHJS$CLERK$MSAL" ] && stop "another sign-in library is installed (${NEXTAUTH:+next-auth }${AUTHJS:+@auth/core }${CLERK:+clerk }${MSAL:+msal}). Two sign-in systems never run side by side: the site's sessions and users move to Better Auth, and the person plans that move first. $STILL"

ISSUES=()
if [ "$MAJOR" -eq 15 ]; then
  ISSUES+=("next 15: the gate is written as middleware.ts with export middleware and runtime \"nodejs\" (copy-templates.sh does it). Not tested; Next 15 maintenance ends about 2026-10-21, so Next 16 is the path")
  MINOR="$(printf '%s' "$NEXT_V" | cut -s -d. -f2)"
  if ! printf '%s' "$MINOR" | grep -Eq '^[0-9]+$' || [ "$MINOR" -lt 5 ]; then
    ISSUES+=("next $NEXT_V: upgrade to 15.5 or later first (npm i next@^15.5, or Next 16): the gate reads the session on the Node.js runtime, which middleware has only from 15.5, and next typegen (the local proof) first shipped in 15.5")
  fi
fi
[ "$MAJOR" -ge 17 ] && ISSUES+=("next $NEXT_V is newer than the tested 16.x: run every test and the local proof before going live")
# better-auth: pinned to an exact tested version. Parts of the templates lean on
# Better Auth internals checked only against 1.7.5 and 1.7.6 (the after-hook
# return shape, the account token write), so a range could install an untested
# patch with no warning. A new version is taken on purpose, after the tests.
BA_INSTALL='npm i --save-exact better-auth@1.7.6'
if [ -z "$BA" ]; then
  ISSUES+=("install better-auth, pinned exactly: $BA_INSTALL (the templates are tested on 1.7.6 and 1.7.5 only)")
else
  BA_V="$(installed better-auth)"; [ -n "$BA_V" ] || BA_V="$(first_version "$BA")"
  case "$BA_V" in
    1.7.5|1.7.6)
      case "$BA" in
        1.7.5|1.7.6) ;;
        *) ISSUES+=("better-auth \"$BA\" is a range, so a new install can take an untested version: pin it exactly, $BA_INSTALL") ;;
      esac ;;
    *) ISSUES+=("better-auth ${BA_V:-$BA} is not a tested version (1.7.6 or 1.7.5): $BA_INSTALL, then re-run the tests") ;;
  esac
fi
[ -n "$PRISMA" ] && ISSUES+=("Prisma, not Drizzle: the schema files become Prisma models; the logic stays (references/adapting.md). Not tested")
[ -z "$DRIZZLE" ] && [ -z "$PRISMA" ] && ISSUES+=("no ORM yet: install drizzle-orm (^0.45.2), drizzle-kit and postgres")
[ -n "$NEON" ] && [ -z "$PGJS" ] && ISSUES+=("Neon serverless driver: keep it, adapt src/lib/db.ts; the rest is driver-neutral")
[ "$APPDIR" = "app" ] && ISSUES+=("no src folder: nothing to do by hand; copy-templates.sh writes templates/src/* at the project root")
[ -n "$PAGES" ] && ISSUES+=("a pages folder exists beside the App Router: the proxy gates both, but the page check reads only $APPDIR, so a pages/ file has the proxy alone; new pages go in $APPDIR")
[ -n "$GATE" ] && ISSUES+=("a request gate already exists ($GATE); merge, never keep two")
[ -n "$NEXT_CONFIG" ] && [ "$NEXT_CONFIG" != " next.config.ts" ] && ISSUES+=("the site has its own next config (${NEXT_CONFIG# }): copy-templates.sh lists next.config.ts as MERGE into it; carry the security headers and poweredByHeader: false in, and keep one config (Next reads only one)")
EXISTING_BA="$(grep -rl "betterAuth(" src lib app 2>/dev/null | grep -v node_modules | head -3 | tr "\n" " " || true)"
[ -n "$EXISTING_BA" ] && ISSUES+=("a Better Auth instance already exists ($EXISTING_BA); merge the options into it, never run two")
if [ "${#ISSUES[@]}" -eq 0 ]; then
  echo "FITS: the templates copy as they are."
else
  echo "ADAPT:"
  for i in "${ISSUES[@]}"; do echo "- $i"; done
fi
