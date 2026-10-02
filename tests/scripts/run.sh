#!/usr/bin/env bash
# Runs every script in skills/entra-id-auth/scripts in plan mode (the mode
# that never writes) against the fake az, vercel and gh in tests/scripts/stubs/,
# a throwaway copy of tests/scripts/fixtures/fresh-site, and the filled config
# in tests/scripts/fixtures/entra-site.env. Nothing here calls a real
# Microsoft tenant, Vercel project or GitHub repository.
#
#   bash tests/scripts/run.sh
#
# It checks that:
#   - every script parses (bash -n; node --check for read-env.cjs)
#   - each script's plan output says what the design says, per scenario
#     (both ASSIGNMENT_MODE and ROLE_SOURCE values, P1 and no P1, security
#     defaults on, guests, owners, previews, the password lane, databases)
#   - bad answers stop before anything is read or written
#   - no stub was called with a write verb, nothing was written into the site
#     or the config folder, and no secret-looking value was printed
#   - SETUP.md's jq line reads the user-scope record of installed_plugins.json
#   - SETUP.md's clone block pulls only from this repository, never a fork
# Exits non-zero on any failure. Runs on macOS (bash 3.2) and Linux.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPTS="$ROOT/skills/entra-id-auth/scripts"
STUBS="$HERE/stubs"
FIXTURES="$HERE/fixtures"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/entra-id-auth-scripts-test.XXXXXX")"
SRV_PID=""
cleanup() { [ -z "$SRV_PID" ] || kill "$SRV_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

FAILS=0; PASSES=0; SKIPS=0; CASE=""; LAST_LOG=""
OUT="$WORK/out"; ALL="$WORK/all-output.log"
mkdir -p "$OUT"; : > "$ALL"
pass() { PASSES=$((PASSES+1)); }
fail() { FAILS=$((FAILS+1)); printf 'FAIL [%s] %s\n' "$CASE" "$*"; }
skip() { SKIPS=$((SKIPS+1)); printf 'skip [%s] %s\n' "$CASE" "$*"; }

# run_case <name> <0|nonzero|any> -- <command...>: runs it, keeps its output
# for expect/expect_not, and checks the exit code.
run_case() {
  local want="$2" n rc log
  CASE="$1"; shift 2
  [ "${1:-}" = "--" ] && shift
  n=$(( $(find "$OUT" -type f | wc -l) + 1 ))
  log="$OUT/$n.log"
  ( "$@" ) > "$log" 2>&1
  rc=$?
  { printf '\n===== %s (exit %s)\n' "$CASE" "$rc"; cat "$log"; } >> "$ALL"
  LAST_LOG="$log"
  case "$want" in
    0) if [ "$rc" -eq 0 ]; then pass; else fail "exit $rc, expected 0. Last lines:"; tail -5 "$log" | sed 's/^/      /'; fi ;;
    nonzero) if [ "$rc" -ne 0 ]; then pass; else fail "exit 0, expected a refusal"; fi ;;
    any) pass ;;
  esac
}
expect() { if grep -qF -- "$1" "$LAST_LOG"; then pass; else fail "expected to see: $1"; fi; }
expect_not() { if grep -qF -- "$1" "$LAST_LOG"; then fail "expected NOT to see: $1"; else pass; fi; }

export PATH="$STUBS:$PATH"
export STUB_FORBID_WRITES=1
export AZ_STUB_LOG="$WORK/az.log" VERCEL_STUB_LOG="$WORK/vercel.log" GH_STUB_LOG="$WORK/gh.log"
: > "$AZ_STUB_LOG"; : > "$VERCEL_STUB_LOG"; : > "$GH_STUB_LOG"
unset MODE AZ_STUB_P1 AZ_STUB_SECDEF AZ_STUB_GROUP AZ_STUB_ROLES AZ_STUB_DOMAINS AZ_STUB_CA AZ_STUB_MEMBERS_DIR AZ_STUB_PAGE_SIZE AZ_STUB_NEXTLINK_FAIL AZ_STUB_GUEST_READ_FAIL AZ_STUB_APP_FOUND AZ_STUB_SHAPE_DIR VERCEL_STUB_DB GH_STUB_VISIBILITY VERCEL_STUB_PROJECT_DOMAINS
export HOME="$WORK/home"
mkdir -p "$HOME/.config"

# ---------------------------------------------------------------------------
echo "## Every script parses"
CASE="bash -n"
for f in "$SCRIPTS"/*.sh "$HERE/run.sh" "$STUBS"/az "$STUBS"/vercel "$STUBS"/gh; do
  if bash -n "$f" 2>"$WORK/syntax.err"; then pass; else fail "$f does not parse: $(head -1 "$WORK/syntax.err")"; fi
done
if command -v node >/dev/null 2>&1; then
  CASE="node --check"
  if node --check "$SCRIPTS/read-env.cjs" 2>/dev/null; then pass; else fail "read-env.cjs does not parse"; fi
fi

# ---------------------------------------------------------------------------
# The site: a throwaway git repo copied from the fixture, linked to a made-up
# Vercel project, so every "wrote nothing" check has a clean baseline.
SITE="$WORK/site/contoso-example"
mkdir -p "$SITE"
cp -R "$FIXTURES/fresh-site/." "$SITE/"
mkdir -p "$SITE/.vercel"
printf '{"projectId":"prj_contoso_example","orgId":"team_contoso_example","projectName":"contoso-example"}\n' > "$SITE/.vercel/project.json"
git_q() { git -C "$1" -c user.email=tests@example.com -c user.name="scripts test" "${@:2}" >/dev/null 2>&1; }
git_q "$SITE" -c init.defaultBranch=main init -q
git_q "$SITE" add -A
git_q "$SITE" commit -q --no-verify -m fixture

SLUG=contoso-example
CONFIG_DIR="$HOME/.config/$SLUG"
mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
# Canary secrets: plan mode must never print a secret file's value.
CANARY="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
for f in better-auth-secret-prod cron-secret-prod entra-client-secret-prod entra-client-secret-dev database-url-prod; do
  (umask 077; printf 'canary-%s' "$CANARY" > "$CONFIG_DIR/$f")
done

# write_config [KEY=value...]: the fixture config, then each change (a later
# line wins). The state file is emptied, as for a site with nothing made yet.
write_config() {
  sed "s|__SITE_DIR__|$SITE|" "$FIXTURES/entra-site.env" > "$CONFIG_DIR/entra-site.env"
  local kv
  for kv in "$@"; do printf '%s\n' "$kv" >> "$CONFIG_DIR/entra-site.env"; done
  chmod 600 "$CONFIG_DIR/entra-site.env"
  : > "$CONFIG_DIR/entra-state.env"
}
# A made-up id built at run time (no id is written in this file).
fake_guid() { printf '%08d-0000-4000-8000-%012d' "$1" "$1"; }

cd "$SITE" || exit 1

# ---------------------------------------------------------------------------
echo "## detect-site.sh"
NODE_OK=no
NV="$(node -p process.versions.node 2>/dev/null || echo 0.0.0)"
NMAJ="${NV%%.*}"; NMIN="$(printf '%s' "$NV" | cut -d. -f2)"
if { [ "$NMAJ" -eq 22 ] && [ "$NMIN" -ge 12 ]; } || [ "$NMAJ" -eq 24 ] || [ "$NMAJ" -ge 26 ]; then NODE_OK=yes; fi

# site_variant <name> <node code editing package.json as p>: a copy of the site.
site_variant() {
  local d="$WORK/variants/$1"
  mkdir -p "$d"; cp -R "$SITE/." "$d/"
  (cd "$d" && node -e "const fs=require('fs');const p=JSON.parse(fs.readFileSync('package.json','utf8'));$2;fs.writeFileSync('package.json',JSON.stringify(p,null,2))")
  printf '%s' "$d"
}
if [ "$NODE_OK" = yes ]; then
  run_case "detect: fresh Next 16 site" 0 -- bash "$SCRIPTS/detect-site.sh" "$SITE"
  expect "ADAPT:"; expect "install better-auth, pinned exactly: npm i --save-exact better-auth@1.7.6"; expect "linked Vercel project: contoso-example"; expect "team team_contoso_example"
  d="$(site_variant next15 'p.dependencies.next="^15.5.0"')"
  run_case "detect: Next 15" 0 -- bash "$SCRIPTS/detect-site.sh" "$d"
  expect "next 15: the gate is written as middleware.ts"
  d="$(site_variant next15-early 'p.dependencies.next="15.3.0"')"
  run_case "detect: Next 15.0 to 15.4 says to upgrade first" any -- bash "$SCRIPTS/detect-site.sh" "$d"
  expect "next 15.3.0: upgrade to 15.5 or later first"
  d="$(site_variant next-mjs 'p.name="next-mjs"')"; printf 'export default {};\n' > "$d/next.config.mjs"
  run_case "detect: names the site's own next config, and none when nothing is found" 0 -- bash "$SCRIPTS/detect-site.sh" "$d"
  expect "next config file: next.config.mjs"; expect "- postgres driver: none"; expect "- other sign-in libraries: none"
  d="$(site_variant next14 'p.dependencies.next="14.2.0"')"
  run_case "detect: Next 14 stops" nonzero -- bash "$SCRIPTS/detect-site.sh" "$d"
  expect "STOP: next 14.2.0 is 14 or older"
  d="$(site_variant pages 'p.name="pages-only"')"; rm -rf "$d/src/app"; mkdir -p "$d/src/pages"; : > "$d/src/pages/index.tsx"
  run_case "detect: Pages Router only stops" nonzero -- bash "$SCRIPTS/detect-site.sh" "$d"
  expect "Pages Router only"
  d="$(site_variant ba-old 'p.dependencies["better-auth"]="^1.6.0"')"
  run_case "detect: better-auth outside the range" 0 -- bash "$SCRIPTS/detect-site.sh" "$d"
  expect "is not a tested version (1.7.6 or 1.7.5)"
  d="$(site_variant ba-pinned 'p.dependencies["better-auth"]="1.7.6"')"
  run_case "detect: better-auth pinned exactly" 0 -- bash "$SCRIPTS/detect-site.sh" "$d"
  expect_not "is a range"; expect_not "not a tested version"
  d="$(site_variant ba-range 'p.dependencies["better-auth"]=">=1.7.5 <1.8"')"
  run_case "detect: better-auth range" 0 -- bash "$SCRIPTS/detect-site.sh" "$d"
  expect "is a range, so a new install can take an untested version"
  d="$(site_variant ba-caret 'p.dependencies["better-auth"]="^1.7.6"')"
  run_case "detect: better-auth caret" 0 -- bash "$SCRIPTS/detect-site.sh" "$d"
  expect "is a range, so a new install can take an untested version"
  d="$(site_variant ba-new 'p.dependencies["better-auth"]="1.7.7"')"
  run_case "detect: better-auth past the tested versions" 0 -- bash "$SCRIPTS/detect-site.sh" "$d"
  expect "better-auth 1.7.7 is not a tested version"
  d="$(site_variant other-auth 'p.dependencies["next-auth"]="^5.0.0"')"
  run_case "detect: another sign-in library stops" nonzero -- bash "$SCRIPTS/detect-site.sh" "$d"
  expect "another sign-in library is installed"
else
  run_case "detect: unsupported node stops" nonzero -- bash "$SCRIPTS/detect-site.sh" "$SITE"
  expect "The tests need Node 22"
  skip "node $NV is not 22.12+, 24 or 26+: the other detect cases need a supported node"
fi

# ---------------------------------------------------------------------------
echo "## preflight.sh"
run_case "preflight: P1, no security defaults, private repo" 0 -- bash "$SCRIPTS/preflight.sh"
expect "Local Postgres (the local proof creates, migrates and drops a database on this machine)"
expect "TENANT_ID=00000000-0000-0000-0000-000000000000"; expect "EMAIL_DOMAINS=contoso.com"
expect "ASSIGNMENT_MODE=group"; expect "REQUIRE_MFA=yes"; expect "RECORD_IN_REPO=yes"
expect "VERCEL_PROJECT=contoso-example"; expect "VERCEL_SCOPE=team_contoso_example"; expect "DB_SOURCE=neon"
expect "MISSING. Least role: Cloud Application Administrator"; expect "groups (group, admin-group): you can"
expect "Suggested answers for the interview"

run_case "preflight: no P1, security defaults on, public repo, a database" 0 -- \
  env AZ_STUB_P1=no AZ_STUB_SECDEF=on GH_STUB_VISIBILITY=PUBLIC VERCEL_STUB_DB=yes bash "$SCRIPTS/preflight.sh"
expect "ASSIGNMENT_MODE=direct"; expect "Entra ID P1 or P2: NO"; expect "security defaults: ON"
expect "REQUIRE_MFA=no"; expect "RECORD_IN_REPO=no"; expect "DB_SOURCE=existing"

# Q4 and Q5 read the linked project's own domains, never the team's list: the
# team holds portal.contoso.com (domains ls), the project only its .vercel.app host.
run_case "preflight: a team domain the project does not have" 0 -- bash "$SCRIPTS/preflight.sh"
expect "domains on this project (production): contoso-example.vercel.app"
expect "for Q4: this project has no custom domain that serves yet"; expect_not "DOMAIN=portal.contoso.com"
expect "domains in the team (not all on this project):"
expect "VERCEL_HOST=contoso-example.vercel.app   # the project's production .vercel.app host, read from the project"
CASE="preflight reads the project's domains, scoped to the linked team"
if grep -qF "vercel api /v9/projects/prj_contoso_example/domains --scope team_contoso_example" "$VERCEL_STUB_LOG"; then pass; else fail "no scoped read of the project's own domains"; fi
run_case "preflight: one custom domain on the project" 0 -- env VERCEL_STUB_PROJECT_DOMAINS="portal.contoso.com contoso-example.vercel.app" bash "$SCRIPTS/preflight.sh"
expect "DOMAIN=portal.contoso.com   # the one custom domain on this project (Q4; Q5: already on the project)"
run_case "preflight: the project's domains cannot be read" 0 -- env VERCEL_STUB_PROJECT_DOMAINS=unreadable bash "$SCRIPTS/preflight.sh"
expect "domains on this project: could not be read"; expect "a guess: the usual production .vercel.app host"
run_case "preflight: the project has more domains than one page" 0 -- env VERCEL_STUB_PROJECT_DOMAINS=paged bash "$SCRIPTS/preflight.sh"
expect "domains on this project: could not be read in full"; expect_not "domains on this project (production)"
run_case "preflight: the one custom domain is attached but not verified" 0 -- env VERCEL_STUB_PROJECT_DOMAINS="portal.contoso.com!unverified contoso-example.vercel.app" bash "$SCRIPTS/preflight.sh"
expect "domains on this project (production): contoso-example.vercel.app; also: portal.contoso.com (unverified)"
expect "for Q4: this project has no custom domain that serves yet (attached, DNS not verified yet: portal.contoso.com)"; expect_not "DOMAIN=portal.contoso.com"
run_case "preflight: the only custom domain is on a custom environment" 0 -- env VERCEL_STUB_PROJECT_DOMAINS="staging.contoso.com!env contoso-example.vercel.app" bash "$SCRIPTS/preflight.sh"
expect "also: staging.contoso.com (custom environment)"; expect_not "DOMAIN=staging.contoso.com"
run_case "preflight: an empty domain list says none" 0 -- env VERCEL_STUB_PROJECT_DOMAINS="" bash "$SCRIPTS/preflight.sh"
expect "domains on this project (production): none"
run_case "preflight: a wildcard domain is not the sign-in address" 0 -- env VERCEL_STUB_PROJECT_DOMAINS="*.contoso.com contoso-example.vercel.app" bash "$SCRIPTS/preflight.sh"
expect "a wildcard domain is on it: ask for the exact host the site signs in on"; expect_not "DOMAIN=*.contoso.com"
# A DOMAIN left in the shell's environment is never the site's address; the config's is compared in lower case.
run_case "preflight: DOMAIN in the environment is ignored without --site" 0 -- env DOMAIN=other.example.org VERCEL_STUB_PROJECT_DOMAINS="portal.contoso.com contoso-example.vercel.app" bash "$SCRIPTS/preflight.sh"
expect "DOMAIN=portal.contoso.com   # the one custom domain on this project"; expect_not "other.example.org"
# A folder with no .vercel/project.json: Q4 and Q5 are said to be asked, never skipped.
NOLINK="$WORK/not-linked-site"; mkdir -p "$NOLINK"
run_case "preflight: a folder not linked to a Vercel project" 0 -- bash "$SCRIPTS/preflight.sh" --dir "$NOLINK"
expect "projects you can see (the choices for Q17):"; expect "contoso-example"
expect "for Q4 and Q5: this folder is not linked to a Vercel project, so the project's domains were not read. Ask Q17 first"; expect_not "domains on this project (production)"
# Q17 answered: the project's domains are read by its name, in the named team.
run_case "preflight: an unlinked folder with the project Q17 named" 0 -- bash "$SCRIPTS/preflight.sh" --dir "$NOLINK" --vercel-project contoso-example --vercel-scope team_contoso_example
expect "reading the project named for Q17: contoso-example (team team_contoso_example)"
expect "domains on this project (production): contoso-example.vercel.app"; expect "for Q4: this project has no custom domain that serves yet"
CASE="preflight reads the named project's domains by name, in the named team"
if grep -qF "vercel api /v9/projects/contoso-example/domains --scope team_contoso_example" "$VERCEL_STUB_LOG"; then pass; else fail "no read of the named project's domains"; fi
run_case "preflight: a project name Q17 got wrong is not blamed on the CLI" 0 -- bash "$SCRIPTS/preflight.sh" --dir "$NOLINK" --vercel-project typo-name --vercel-scope team_contoso_example
expect "for Q17: no project named typo-name in team team_contoso_example was found"; expect_not "may be too old"; expect_not "VERCEL_HOST=typo-name"
run_case "preflight: --vercel-project must be a project name" nonzero -- bash "$SCRIPTS/preflight.sh" --dir "$NOLINK" --vercel-project 'a b;c'
expect "--vercel-project is a Vercel project name"

run_case "preflight: licences unreadable" 0 -- env AZ_STUB_P1=unknown bash "$SCRIPTS/preflight.sh"
expect "Entra ID P1 or P2: unknown"
run_case "preflight: a tenant with only its onmicrosoft.com domain" 0 -- env AZ_STUB_DOMAINS=onmicrosoft bash "$SCRIPTS/preflight.sh"
expect "EMAIL_DOMAINS=contoso.onmicrosoft.com"; expect "found: contoso.onmicrosoft.com (the tenant has no other domain)"

write_config
run_case "preflight --site: names in the tenant" 0 -- bash "$SCRIPTS/preflight.sh" --site "$SLUG"
expect "Names already in the tenant"; expect "sign-in group \"Contoso Example\": 0 found"
expect "for Q5: portal.contoso.com is not on this project yet: ask Q5 (step 5.2 adds it)"
run_case "preflight --site: the domain already on the project" 0 -- env VERCEL_STUB_PROJECT_DOMAINS="portal.contoso.com contoso-example.vercel.app" bash "$SCRIPTS/preflight.sh" --site "$SLUG"
expect "for Q5: portal.contoso.com is already on the project (skip adding it)"
run_case "preflight --site: the domain attached but not verified" 0 -- env VERCEL_STUB_PROJECT_DOMAINS="portal.contoso.com!unverified contoso-example.vercel.app" bash "$SCRIPTS/preflight.sh" --site "$SLUG"
expect "for Q5: portal.contoso.com is on the project but Vercel has not verified its DNS"; expect_not "is already on the project (skip adding it)"
run_case "preflight --site: the domain is a redirect on the project" 0 -- env VERCEL_STUB_PROJECT_DOMAINS="portal.contoso.com!redirect contoso-example.vercel.app" bash "$SCRIPTS/preflight.sh" --site "$SLUG"
expect "for Q5: portal.contoso.com is on the project as a redirect domain"
run_case "preflight --site: the domain is on a custom environment" 0 -- env VERCEL_STUB_PROJECT_DOMAINS="portal.contoso.com!env contoso-example.vercel.app" bash "$SCRIPTS/preflight.sh" --site "$SLUG"
expect "for Q5: portal.contoso.com is on the project as a custom environment domain"
run_case "preflight --site: a group with the name exists" 0 -- env AZ_STUB_GROUP=ours bash "$SCRIPTS/preflight.sh" --site "$SLUG"
expect "sign-in group \"Contoso Example\": 1 found, 1 carrying the marker entra-id-auth:portal.contoso.com"

# ---------------------------------------------------------------------------
echo "## tenant-setup.sh (plan)"
TS="$SCRIPTS/tenant-setup.sh"

write_config
run_case "tenant: group mode, site roles, P1, MFA yes" 0 -- bash "$TS" --site "$SLUG" plan
expect "needs (least role, from Microsoft's list): Groups Administrator"; expect "az ad group create"; expect "entra-id-auth:portal.contoso.com"
expect "roster: 3 people (1 administrator(s))"; expect "writes (at run): $CONFIG_DIR/people.json"
expect "appRoleAssignmentRequired=true"; expect "Assign the group, and only the group"
expect "list): Cloud Application Administrator"; expect "list): Application Developer"
expect '"value": 10'; expect "sign-in frequency 10 hours"; expect "list): Conditional Access Administrator"
expect "not needed: ASSIGNMENT_MODE is group"; expect "skipped: ROLE_SOURCE is site"
expect "(plan only: nothing was changed)"
expect_not "--app-roles"; expect_not "STOP at run"; expect_not "__SESSION_MAX_HOURS__"

run_case "tenant: one step, app prod" 0 -- bash "$TS" --site "$SLUG" plan app prod
expect "App registration \"Contoso Example\" (prod)"; expect "https://portal.contoso.com/api/auth/callback/microsoft"
run_case "tenant: record goes outside the repo" 0 -- bash "$TS" --site "$SLUG" plan record
expect "$CONFIG_DIR/entra-record.md"; expect "RECORD_IN_REPO=no"
write_config RECORD_IN_REPO=yes
run_case "tenant: record in the repo on a yes" 0 -- bash "$TS" --site "$SLUG" plan record
expect "$SITE/docs/auth/entra-record.md"
write_config
run_case "tenant: teardown prints only" 0 -- bash "$TS" --site "$SLUG" plan teardown
expect "Teardown: the delete commands, printed only"
run_case "tenant: teardown never runs" nonzero -- bash "$TS" --site "$SLUG" run teardown
expect "teardown only prints"
run_case "tenant: run needs one step" nonzero -- bash "$TS" --site "$SLUG" run
expect "Run one step at a time"

write_config ROLE_SOURCE=entra "EXTRA_ADMINS='second.admin@contoso.com'"
run_case "tenant: group mode, Entra roles, P1" 0 -- bash "$TS" --site "$SLUG" plan
expect "Administrators group (ROLE_SOURCE=entra)"; expect "contoso-example-admins"; expect "entra-id-auth:portal.contoso.com:administrators"
expect "--app-roles"; expect '"value":"administrator"'; expect "The administrators group gets the Administrator app role"
expect "roster: 4 people (2 administrator(s))"

write_config
run_case "tenant: group mode without P1 stops at sp" 0 -- env AZ_STUB_P1=no bash "$TS" --site "$SLUG" plan
expect "STOP at run: This tenant has no Entra ID P1 or P2"; expect "ASSIGNMENT_MODE=direct"
expect "STOP at run: Conditional Access needs Entra ID P1"

write_config ASSIGNMENT_MODE=direct ROLE_SOURCE=entra REQUIRE_MFA=no
run_case "tenant: direct mode, Entra roles, no P1" 0 -- env AZ_STUB_P1=no bash "$TS" --site "$SLUG" plan
expect "each roster member assigned directly"; expect "One roster member, default access"
expect "One administrator gets the Administrator app role"
expect "a change to the sign-in group or the administrators group reaches the app only when sync-assignments runs again"
expect "Direct assignments made equal to the roster (ASSIGNMENT_MODE=direct)"
expect "skipped, MFA is not required"
expect_not "no Entra ID P1 or P2, and Microsoft assigns a group"
# A full plan on the path recommended without P1 reports no STOP that the run
# would never meet: the groups and apps it makes earlier are planned from the roster.
expect_not "STOP at run"
expect "the sign-in group is made earlier in this plan (known after the group step runs); planned from the roster: 3 people"
expect "the administrators group is made earlier in this plan (known after the admin-group step runs); planned from the roster: 1 administrator(s)"
expect "prod: the enterprise app is made earlier in this plan (known after the sp step runs). sign-in (default access): roster 3; the sp step assigns these 3 people and gives 1 administrator(s) the Administrator role, so a sync straight after it: add 0, remove 0."
run_case "tenant: direct mode, one step, sync-assignments" 0 -- env AZ_STUB_P1=no bash "$TS" --site "$SLUG" plan sync-assignments
expect "No GROUP_ID recorded"

write_config ASSIGNMENT_MODE=direct ROLE_SOURCE=site
run_case "tenant: direct mode, site roles, P1" 0 -- bash "$TS" --site "$SLUG" plan
expect "each roster member assigned directly"; expect_not "--app-roles"
expect_not "STOP at run"; expect "roster 3; the sp step assigns these 3 people, so a sync straight after it: add 0, remove 0."

write_config
run_case "tenant: security defaults on refuse the MFA policy" 0 -- env AZ_STUB_SECDEF=on bash "$TS" --site "$SLUG" plan ca
expect "STOP at run: Security defaults are on in this tenant"

run_case "tenant: MFA policy with the licence list unreadable" 0 -- env AZ_STUB_P1=unknown bash "$TS" --site "$SLUG" plan ca
expect "WARNING: the licence list could not be read. Conditional Access needs Entra ID P1 or P2"

write_config REQUIRE_MFA=no
run_case "tenant: MFA no" 0 -- bash "$TS" --site "$SLUG" plan ca
expect "skipped, MFA is not required"

write_config
run_case "tenant: a same-named group that is not ours" 0 -- env AZ_STUB_GROUP=foreign bash "$TS" --site "$SLUG" plan group
expect "STOP at run: A group named \"Contoso Example\" exists"
write_config ADOPT_EXISTING_APPS=yes
run_case "tenant: adopting it on a yes" 0 -- env AZ_STUB_GROUP=foreign bash "$TS" --site "$SLUG" plan group
expect "its description is REPLACED"; expect "az ad group update"
write_config
run_case "tenant: our own group is reused" 0 -- env AZ_STUB_GROUP=ours bash "$TS" --site "$SLUG" plan group
expect "made by this skill for https://portal.contoso.com"; expect_not "az ad group create"
write_config "GROUP_ID=$(fake_guid 1)" LIST_GROUP_MEMBERS=all MEMBERS=
run_case "tenant: a group picked by id" 0 -- bash "$TS" --site "$SLUG" plan group
expect "Using the sign-in group picked by id"; expect "0 nested group(s)"; expect_not "az ad group update"; expect_not "az ad group create"
expect "no member and no owner is added to it"; expect_not "az ad group member add"; expect_not "az ad group owner add"
expect "STOP at run: 1 person(s) named in the config"; expect "LIST_GROUP_MEMBERS=all"
expect "from the picked group (LIST_GROUP_MEMBERS=all)"
write_config "GROUP_ID=$(fake_guid 1)" MEMBERS=
run_case "tenant: a picked group needs Q7" 0 -- bash "$TS" --site "$SLUG" plan group
expect "STOP at run: Q7 is not answered for a picked group"
write_config "GROUP_ID=$(fake_guid 1)" LIST_GROUP_MEMBERS=admins MEMBERS=
run_case "tenant: a picked group, administrators only" 0 -- bash "$TS" --site "$SLUG" plan group
expect "the site refuses every other member of this group"
write_config "GROUP_ID=$(fake_guid 1)" "ADMIN_GROUP_ID=$(fake_guid 3)" LIST_GROUP_MEMBERS=all ROLE_SOURCE=entra MEMBERS=
run_case "tenant: a picked administrators group" 0 -- bash "$TS" --site "$SLUG" plan admin-group
expect "Using the administrators group picked by id"; expect "no member and no owner is added to it"
expect_not "az ad group member add"; expect_not "az ad group owner add"
write_config
run_case "tenant: the MFA policy's scope is said" 0 -- bash "$TS" --site "$SLUG" plan ca
expect "scope: only this site's own app registrations and its sign-in group"

write_config PREVIEW_MODE=stable-host PREVIEW_HOST=contoso-example-git-preview-contoso-team.vercel.app
run_case "tenant: a stable preview host" 0 -- bash "$TS" --site "$SLUG" plan
expect "App registration \"Contoso Example (preview)\" (preview)"
expect "https://contoso-example-git-preview-contoso-team.vercel.app/api/auth/callback/microsoft"

write_config NEEDS_M365_SERVER=yes "MAILBOXES='orders@contoso.com'"
run_case "tenant: the server reader" 0 -- bash "$TS" --site "$SLUG" plan
expect "Server-side Microsoft 365"; expect "PowerShell 7"; expect "list): Exchange Administrator"

write_config "MEMBERS='missing.person@contoso.com,sam@contoso.com'"
run_case "tenant: an address that does not resolve" 0 -- bash "$TS" --site "$SLUG" plan group
expect "STOP at run: In the roster"; expect "entries 1 were not found"
write_config "MEMBERS='guest.user@contoso.com'"
run_case "tenant: a guest, not allowed" 0 -- bash "$TS" --site "$SLUG" plan group
expect "are guests, and ALLOW_GUESTS is no"
write_config "MEMBERS='guest.user@contoso.com'" ALLOW_GUESTS=yes
run_case "tenant: a guest, allowed" 0 -- bash "$TS" --site "$SLUG" plan group
expect_not "STOP at run"
write_config "MEMBERS='disabled.user@contoso.com'"
run_case "tenant: a disabled account" 0 -- bash "$TS" --site "$SLUG" plan group
expect "are disabled accounts"

write_config "OWNERS='admin@contoso.com,ADMIN@contoso.com'"
run_case "tenant: the same owner twice, ignoring case" 0 -- bash "$TS" --site "$SLUG" plan group
expect "OWNERS names 1 different owner(s)"

# Groups that hold people (the stub's AZ_STUB_MEMBERS_DIR), read two users a
# page so every list takes several pages (@odata.nextLink).
MEMBERS_DIR="$WORK/members"; mkdir -p "$MEMBERS_DIR"
uid() { az ad user show --id "$1" --query id -o tsv; }
# member_row <address> <enabled> <userType>: one user line for a group file.
member_row() { printf '%s\t%s\t%s\t%s\t%s\n' "$(uid "$1")" "$2" "$3" "$1" "${1%%@*}"; }
G1="$(fake_guid 1)"; G3="$(fake_guid 3)"
G2="$(fake_guid 2)"
{ member_row owner@contoso.com true Member; member_row kiosk@fabrikam.com true Member
  member_row gone@contoso.com false Member; member_row pat@contoso.com true Member
  member_row lee@contoso.com true Member; } > "$MEMBERS_DIR/$G1"
{ cat "$MEMBERS_DIR/$G1"; member_row visitor@fabrikam.com true Guest; } > "$MEMBERS_DIR/$G2"
export AZ_STUB_MEMBERS_DIR="$MEMBERS_DIR" AZ_STUB_PAGE_SIZE=2
# Q7's count: preflight --group counts a picked group the way the setup lists it.
run_case "preflight --group: a picked group counted as the setup lists it" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G2"
expect "3 enabled people on the email domains"; expect "left off unless guests are allowed (Q8): 1 enabled member(s) off those domains"
expect "never listed: 1 disabled account(s); 0 nested group(s)"; expect "guests in the group (enabled or not): 1"
expect 'for Q6, say: "This group holds 1 guest(s). With guests not allowed (recommended), it cannot be used: allow guests (Q8 yes, asked now), remove them from the group, or let the setup make a new group."'
expect 'for Q7 (only if guests are allowed, Q8 yes), the count: "5 enabled people will go on the list, 1 guest(s) and 1 off your domains among them"'
expect "counted against every verified domain except *.onmicrosoft.com"
run_case "preflight --group --domains: counted against Q2's answer" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G1" --domains fabrikam.com
expect "1 enabled person on the email domains (fabrikam.com)"; expect_not "counted against every verified domain"
expect 'for Q7, the count: "1 enabled person will go on the list (3 off your domains are left off unless Q8 is yes)"'; expect_not "for Q6, say"
# A clean group on one domain: the Q7 line carries no bracket about 0 people.
G13="$(fake_guid 13)"
{ member_row owner@contoso.com true Member; member_row pat@contoso.com true Member; } > "$MEMBERS_DIR/$G13"
run_case "preflight --group: all on the domains, no guests" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G13" --domains contoso.com
expect 'for Q7, the count: "2 enabled people will go on the list"'; expect_not "off your domains are left off"; expect_not "for Q6, say"
CASE="preflight --group reads every page"
if grep -qF "$G2/members/microsoft.graph.user?\$skiptoken=3" "$AZ_STUB_LOG"; then pass; else fail "preflight --group did not follow @odata.nextLink"; fi
run_case "preflight --group: only a group id" nonzero -- bash "$SCRIPTS/preflight.sh" --group not-a-group
expect "--group is a group's object id"
expect "az ad group list --display-name"
run_case "preflight --admin-group: only a group id" nonzero -- bash "$SCRIPTS/preflight.sh" --admin-group "Contoso Admins"
expect "--admin-group is a group's object id"; expect "az ad group list --display-name"
run_case "preflight: the sign-in and administrators groups are the same" nonzero -- bash "$SCRIPTS/preflight.sh" --group "$G13" --admin-group "$G13"
expect "--group and --admin-group are the same group"
run_case "preflight --admins: only addresses" nonzero -- bash "$SCRIPTS/preflight.sh" --group "$G13" --admins "owner@contoso.com,not an address"
expect "--admins is a comma list of work addresses"
# A picked group's type and nested groups (the stub's AZ_STUB_SHAPE_DIR), said
# at Q6 and Q11 the way the group step later refuses them.
SHAPE_DIR="$WORK/shapes"; mkdir -p "$SHAPE_DIR"; export AZ_STUB_SHAPE_DIR="$SHAPE_DIR"
TYPE_LINE='This group is a Microsoft 365, mail-enabled or dynamic group. It cannot be used: pick a security group, or let the setup make a new group.'
for shape in "m365:true true 1" "mail-enabled:true true 0" "dynamic:true false 1" "not security-enabled:false false 0"; do
  what="${shape%%:*}"; G20="$(fake_guid 20)"
  cp "$MEMBERS_DIR/$G13" "$MEMBERS_DIR/$G20"; printf 'shape %s\n' "${shape#*:}" > "$SHAPE_DIR/$G20"
  run_case "preflight --group: a $what group is refused at Q6" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G20" --domains contoso.com
  expect "for Q6, say: \"$TYPE_LINE\""
  write_config "GROUP_ID=$G20" LIST_GROUP_MEMBERS=all MEMBERS=
  run_case "tenant: the group step refuses the same $what group" 0 -- bash "$TS" --site "$SLUG" plan group
  expect "STOP at run: The sign-in group $G20 is not usable as it is"
done
printf 'shape fail\n' > "$SHAPE_DIR/$G20"
run_case "preflight --group: a group whose type cannot be read" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G20" --domains contoso.com
expect "its type could not be read"
expect 'for Q6, say: "This group is a Microsoft 365, mail-enabled or dynamic group (or it could not be checked). It cannot be used'
G21="$(fake_guid 21)"; cp "$MEMBERS_DIR/$G13" "$MEMBERS_DIR/$G21"; printf 'nested 2\n' > "$SHAPE_DIR/$G21"
run_case "preflight --group: a group holding nested groups" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G21" --domains contoso.com
expect "nested groups: 2"
expect 'for Q6, say: "This group holds other groups inside it. It cannot be used as it is: add those people directly, or let the setup make a new group."'
expect_not "$TYPE_LINE"
write_config "GROUP_ID=$G21" LIST_GROUP_MEMBERS=all MEMBERS=
run_case "tenant: the group step refuses the same nested groups" 0 -- bash "$TS" --site "$SLUG" plan group
expect "2 nested group(s)"; expect "it holds nested groups"
printf 'nested fail\n' > "$SHAPE_DIR/$G21"
run_case "preflight --group: nested groups that cannot be read" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G21" --domains contoso.com
expect 'for Q6, say: "This group holds other groups inside it (or they could not be checked). It cannot be used as it is'
run_case "tenant: the group step says the same nested groups could not be checked" 0 -- bash "$TS" --site "$SLUG" plan group
expect "whether it holds nested groups could not be checked"
# The administrators must already be in a picked group ($G13 holds owner and pat).
run_case "preflight --group --admins: an administrator not in the group" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G13" --domains contoso.com --admins owner@contoso.com,lee@contoso.com
expect "administrators checked: 2; in this group: 1; not in it: 1"
expect 'for Q6, say: "1 administrator is not in this group yet: add them to it yourself, or let the setup make a new group."'
run_case "preflight --group --admins: a clean group, the administrator in it" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G13" --domains contoso.com --admins owner@contoso.com
expect "security-enabled true; mail-enabled false"; expect "in this group: 1; not in it: 0"
expect_not "for Q6, say"; expect 'for Q7, the count: "2 enabled people will go on the list"'
run_case "preflight --group --admins: an address not in the tenant" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G13" --admins missing.person@contoso.com
expect "1 administrator address(es) were not found in this tenant"
run_case "preflight --group: no administrators given" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G13"
expect "the administrators were not given (--admins)"
# Q11: the administrators group gets the same checks, headed for Q11, and no Q7 line.
run_case "preflight --admin-group: an administrator not in it" 0 -- bash "$SCRIPTS/preflight.sh" --admin-group "$G13" --domains contoso.com --admins owner@contoso.com,lee@contoso.com
expect "The picked administrators group (Q11)"
expect 'for Q11, say: "1 administrator is not in this group yet: add them to it yourself, or let the setup make a new group."'
run_case "preflight --admin-group: two administrators not in it" 0 -- bash "$SCRIPTS/preflight.sh" --admin-group "$G13" --domains contoso.com --admins owner@contoso.com,lee@contoso.com,sam@contoso.com
expect 'for Q11, say: "2 administrators are not in this group yet'; expect_not "1 administrator is"
expect_not "for Q7"; expect_not "for Q6"
run_case "preflight --admin-group: a group whose type cannot be read" 0 -- bash "$SCRIPTS/preflight.sh" --admin-group "$G20" --admins owner@contoso.com
expect 'for Q11, say: "This group is a Microsoft 365, mail-enabled or dynamic group (or it could not be checked).'
printf 'shape true true 1\n' > "$SHAPE_DIR/$G20"; cp "$MEMBERS_DIR/$G2" "$MEMBERS_DIR/$G20"
run_case "preflight --admin-group: a Microsoft 365 group holding a guest" 0 -- bash "$SCRIPTS/preflight.sh" --admin-group "$G20" --admins owner@contoso.com
expect "for Q11, say: \"$TYPE_LINE\""
expect 'for Q11 (only when Q8 is no), say: "This group holds 1 guest(s).'; expect_not "for Q7"
run_case "preflight --admin-group: a clean administrators group" 0 -- bash "$SCRIPTS/preflight.sh" --admin-group "$G13" --admins owner@contoso.com
expect "in this group: 1; not in it: 0"; expect_not "for Q11"; expect_not "for Q7"
# With --site, a picked administrators group and the config's administrators are used.
write_config "GROUP_ID=$G13" "ADMIN_GROUP_ID=$G20" ROLE_SOURCE=entra LIST_GROUP_MEMBERS=all MEMBERS= "EXTRA_ADMINS=lee@contoso.com"
run_case "preflight --site: both picked groups, the config's administrators" 0 -- bash "$SCRIPTS/preflight.sh" --site "$SLUG"
expect "administrators checked: 2"
expect 'for Q6, say: "1 administrator is not in this group yet'
expect "for Q11, say: \"$TYPE_LINE\""
unset AZ_STUB_SHAPE_DIR
write_config "GROUP_ID=$G1" LIST_GROUP_MEMBERS=all MEMBERS=
AZ_LINES="$(wc -l < "$AZ_STUB_LOG")"
run_case "tenant: a picked group that already holds the administrator, every page read" 0 -- bash "$TS" --site "$SLUG" plan group
expect "members already: 1; missing: 0"; expect_not "STOP at run"
expect "from the picked group (LIST_GROUP_MEMBERS=all): 2 more enabled user(s)"
expect "1 group member(s) off EMAIL_DOMAINS (contoso.com) were left off the site's list (ALLOW_GUESTS=no)"
expect "roster: 3 people (1 administrator(s))"; expect "people.json (owner-only): 3 people, 1 administrator(s)"
expect "5 member(s), 0 guest(s), 0 nested group(s)"; expect_not "999 or more"
CASE="the third page of the group was read"
if tail -n +"$((AZ_LINES+1))" "$AZ_STUB_LOG" | grep -qF "$G1/members/microsoft.graph.user?\$skiptoken=3"; then pass; else fail "graph_list did not follow @odata.nextLink to page 3"; fi
write_config "GROUP_ID=$G2" LIST_GROUP_MEMBERS=all MEMBERS=
run_case "tenant: a picked group holding a guest, guests not allowed" 0 -- bash "$TS" --site "$SLUG" plan group
expect "it holds guests and ALLOW_GUESTS is no"; expect "2 more enabled user(s)"
run_case "tenant: a picked group whose guest count cannot be read" 0 -- env AZ_STUB_GUEST_READ_FAIL=1 bash "$TS" --site "$SLUG" plan group
expect "? guest(s)"; expect "STOP at run: The sign-in group $G2 could not be checked in full: whether it holds guests could not be checked"
expect_not "it holds guests and ALLOW_GUESTS is no"
# The Q6 sentence and the group step agree on a group whose only guest is disabled.
G8="$(fake_guid 8)"
{ cat "$MEMBERS_DIR/$G1"; member_row visitor@fabrikam.com false Guest; } > "$MEMBERS_DIR/$G8"
run_case "preflight --group: a disabled guest is still a guest" 0 -- bash "$SCRIPTS/preflight.sh" --group "$G8"
expect 'for Q6, say: "This group holds 1 guest(s).'
write_config "GROUP_ID=$G8" LIST_GROUP_MEMBERS=all MEMBERS=
run_case "tenant: the group step refuses the same group" 0 -- bash "$TS" --site "$SLUG" plan group
expect "it holds guests and ALLOW_GUESTS is no (1 guest(s), enabled or not"
write_config "GROUP_ID=$G2" LIST_GROUP_MEMBERS=all MEMBERS= ALLOW_GUESTS=yes
run_case "tenant: a picked group with guests allowed keeps the guest" 0 -- bash "$TS" --site "$SLUG" plan group
expect "from the picked group (LIST_GROUP_MEMBERS=all): 4 more enabled user(s)"
expect "WARNING: 2 address(es) are not on EMAIL_DOMAINS (contoso.com); ALLOW_GUESTS=yes, so seed with scripts/seed-people.ts --allow-other-domains"
expect "roster: 5 people (1 administrator(s))"; expect_not "were left off the site's list"
# The recount after the summary reads Q8 from the config, and agrees with the group step.
run_case "preflight --site: ALLOW_GUESTS=yes counts as the group step lists" 0 -- bash "$SCRIPTS/preflight.sh" --site "$SLUG"
expect 'for Q7 (ALLOW_GUESTS=yes in the config), the count: "5 enabled people will go on the list, 1 guest(s) and 1 off your domains among them"'
expect_not "left off unless Q8 is yes"
expect_not "This group holds 1 guest(s)"
write_config "GROUP_ID=$G1" LIST_GROUP_MEMBERS=all MEMBERS=
run_case "tenant: a picked group the admin is not in" 0 -- env AZ_STUB_MEMBERS_DIR="$WORK/none" bash "$TS" --site "$SLUG" plan group
expect "members already: 0; missing: 1"; expect "STOP at run: 1 person(s) named in the config"
G9="$(fake_guid 9)"
{ member_row owner@contoso.com true Member; member_row pat@contoso.com true Member; echo '!fail'; } > "$MEMBERS_DIR/$G9"
write_config "GROUP_ID=$G9" LIST_GROUP_MEMBERS=all MEMBERS=
run_case "tenant: a group whose second page cannot be read" 0 -- bash "$TS" --site "$SLUG" plan group
expect "STOP at run: The members of the picked group $G9 could not be read"
write_config "GROUP_ID=$G9" ASSIGNMENT_MODE=direct
run_case "tenant: sync never works from a partial list" 0 -- bash "$TS" --site "$SLUG" plan sync-assignments
expect "could not be read in full, so no assignment is changed"
# A failed read of a page's next link (a throttle) is a failure, never the
# last page: the rows of page 1 are not the whole group.
write_config "GROUP_ID=$G1" ASSIGNMENT_MODE=direct
run_case "tenant: sync stops when a next link cannot be read" 0 -- env AZ_STUB_NEXTLINK_FAIL=1 bash "$TS" --site "$SLUG" plan sync-assignments
expect "The members of the sign-in group $G1 could not be read in full, so no assignment is changed"
write_config "GROUP_ID=$G1" LIST_GROUP_MEMBERS=all MEMBERS=
run_case "tenant: the roster stops when a next link cannot be read" 0 -- env AZ_STUB_NEXTLINK_FAIL=1 bash "$TS" --site "$SLUG" plan group
expect "STOP at run: The members of the picked group $G1 could not be read"
expect_not "roster: 3 people"
write_config "GROUP_ID=$G1" ASSIGNMENT_MODE=direct
printf 'APP_ID_prod=%s\nSP_ID_prod=%s\n' "$(fake_guid 41)" "$(fake_guid 42)" > "$CONFIG_DIR/entra-state.env"
run_case "verify-tenant: a partial roster is UNVERIFIED, never a false FAIL" any -- env AZ_STUB_NEXTLINK_FAIL=1 AZ_STUB_APP_FOUND=yes bash "$SCRIPTS/verify-tenant.sh" --site "$SLUG"
expect "| M5 | Direct assignments equal the roster | prod | UNVERIFIED | the sign-in group's members could not be read in full |"
expect_not "missing 0, extra"
run_case "verify-tenant: the full roster is compared when every page reads" any -- env AZ_STUB_APP_FOUND=yes bash "$SCRIPTS/verify-tenant.sh" --site "$SLUG"
expect "| M5 | Direct assignments equal the roster | prod | FAIL | missing 4, extra 0, groups assigned 0; run the sync-assignments step |"
: > "$CONFIG_DIR/entra-state.env"

# ROLE_SOURCE=entra: the administrators group is a door of its own.
{ member_row owner@contoso.com true Member; member_row stray@contoso.com true Member; } > "$MEMBERS_DIR/$G3"
write_config ROLE_SOURCE=entra
run_case "tenant: the MFA policy names both groups (entra)" 0 -- bash "$TS" --site "$SLUG" plan ca
expect '"includeGroups": ["<GROUP_ID>", "<ADMIN_GROUP_ID>"]'; expect "its sign-in group and administrators group"
write_config ROLE_SOURCE=entra "GROUP_ID=$G1" "ADMIN_GROUP_ID=$G3"
run_case "tenant: the MFA policy names both group ids (entra)" 0 -- bash "$TS" --site "$SLUG" plan ca
expect "\"includeGroups\": [\"$G1\", \"$G3\"]"
write_config "GROUP_ID=$G1"
run_case "tenant: the MFA policy names the sign-in group only (site roles)" 0 -- bash "$TS" --site "$SLUG" plan ca
expect "\"includeGroups\": [\"$G1\"]"; expect_not "$G3"
write_config ROLE_SOURCE=entra "GROUP_ID=$G1" "ADMIN_GROUP_ID=$G3"
run_case "tenant: an administrator outside the sign-in group stops sp" 0 -- bash "$TS" --site "$SLUG" plan sp prod
expect "administrators-group members who are not in the sign-in group: 1"
expect "STOP at run: 1 member(s) of Contoso Example Administrators are not in Contoso Example"
write_config ROLE_SOURCE=entra ASSIGNMENT_MODE=direct "GROUP_ID=$G1" "ADMIN_GROUP_ID=$G3"
run_case "tenant: sync gives no Administrator role outside the sign-in group" 0 -- bash "$TS" --site "$SLUG" plan sync-assignments
expect "WARNING: 1 member(s) of Contoso Example Administrators are not in Contoso Example: they get no Administrator role"
run_case "verify-tenant: an administrator outside the sign-in group" any -- env AZ_STUB_CA=sign-in-only bash "$SCRIPTS/verify-tenant.sh" --site "$SLUG"
expect "1 member(s) of the administrators group are not in the sign-in group (a second door"
expect "the policy does not name the administrators group"
member_row stray@contoso.com true Member >> "$MEMBERS_DIR/$G1"
run_case "tenant: every administrator inside the sign-in group" 0 -- bash "$TS" --site "$SLUG" plan sp prod
expect "administrators-group members who are not in the sign-in group: 0"; expect_not "are not in Contoso Example"
run_case "verify-tenant: administrators inside, policy names both" any -- env AZ_STUB_CA=both bash "$SCRIPTS/verify-tenant.sh" --site "$SLUG"
expect "2 administrator(s), all in the sign-in group"; expect_not "does not name the administrators group"
unset AZ_STUB_MEMBERS_DIR AZ_STUB_PAGE_SIZE

# Bad answers stop before any read or write.
refused() { write_config "$@"; run_case "config refused: $*" nonzero -- bash "$TS" --site "$SLUG" plan group; }
refused EMAIL_DOMAIN=contoso.com;                     expect "EMAIL_DOMAIN is now EMAIL_DOMAINS"
refused LIST_GROUP_MEMBERS=some;                      expect "LIST_GROUP_MEMBERS must be one of: all admins"
refused PREVIEW_PASSWORD_LANE=true;                   expect "PREVIEW_PASSWORD_LANE is now PASSWORD_LANE"
refused SESSION_IDLE_MINUTES=480 SESSION_MAX_HOURS=8; expect "must be shorter than SESSION_MAX_HOURS"
refused SESSION_MAX_HOURS=30;                         expect "SESSION_MAX_HOURS must be a whole number from 1 to 24"
refused SESSION_IDLE_MINUTES=5;                       expect "SESSION_IDLE_MINUTES must be a whole number from 15 to 480"
refused SESSION_ANSWERED_BY=;                         expect "SESSION_ANSWERED_BY is empty"
refused "SESSION_ANSWERED_BY='<name>, <YYYY-MM-DD>'"; expect "Replace any <placeholder>"
refused MFA_ANSWERED_BY=;                             expect "MFA_ANSWERED_BY is empty"
refused ASSIGNMENT_MODE=groups;                       expect "ASSIGNMENT_MODE must be one of: group direct"
refused ROLE_SOURCE=ldap;                             expect "ROLE_SOURCE must be one of: site entra"
refused ALLOW_GUESTS=maybe;                           expect "ALLOW_GUESTS must be one of: yes no"
refused JOIN_MODE=open;                               expect "JOIN_MODE must be one of: listed group"
refused PREVIEW_MODE=stable-host;                     expect "PREVIEW_HOST must name the one stable branch host"
refused PREVIEW_HOST=contoso-example-git-x.vercel.app; expect "PREVIEW_HOST is set but PREVIEW_MODE is test-lane"
refused PASSWORD_LANE=off;                            expect "PREVIEW_MODE=test-lane means previews sign in with the test lane"
refused DB_SOURCE=sqlite;                             expect "DB_SOURCE must be one of: existing neon other"
refused RECORD_IN_REPO=maybe;                         expect "RECORD_IN_REPO must be one of: yes no"
refused "EMAIL_DOMAINS='contoso.com,not a domain'";   expect "EMAIL_DOMAINS must be bare domains"
refused FIRST_ADMIN=first@example.com;                expect "is not on EMAIL_DOMAINS"
refused "MEMBERS='alex@contoso.com,kiosk@fabrikam.com'"; expect "A member's address (kiosk@fabrikam.com, in MEMBERS) is not on EMAIL_DOMAINS"
write_config "MEMBERS='alex@contoso.com,kiosk@fabrikam.com'" ALLOW_GUESTS=yes
run_case "tenant: an off-domain member is allowed with guests" 0 -- bash "$TS" --site "$SLUG" plan group
expect_not "in MEMBERS) is not on EMAIL_DOMAINS"
refused "ADMIN_GROUP_ID=$(fake_guid 2)" "GROUP_ID=$(fake_guid 2)"; expect "GROUP_ID and ADMIN_GROUP_ID are the same group"
refused VERCEL_HOST=portal.contoso.com;               expect "VERCEL_HOST must be the .vercel.app host"
# No custom domain: DOMAIN is the .vercel.app host and VERCEL_HOST stays empty.
refused DOMAIN=contoso-example.vercel.app VERCEL_HOST=contoso-example.vercel.app; expect "so VERCEL_HOST stays empty: set VERCEL_HOST= in"
write_config DOMAIN=contoso-example.vercel.app VERCEL_HOST=
run_case "tenant: no custom domain, VERCEL_HOST empty" 0 -- bash "$TS" --site "$SLUG" plan group
expect_not "STOP"
run_case "preflight --site: no custom domain suggests VERCEL_HOST empty" 0 -- bash "$SCRIPTS/preflight.sh" --site "$SLUG"
expect "DOMAIN is the .vercel.app host itself: no canonical-host redirect (Q4)"
refused EMAIL_DOMAINS=;                              expect "EMAIL_DOMAINS is empty"

# ---------------------------------------------------------------------------
echo "## vercel-env.sh (plan)"
VE="$SCRIPTS/vercel-env.sh"
# every_vercel_line_scoped: each vercel command the plan shows names the team.
every_vercel_line_scoped() {
  local bad
  bad="$(grep -E '^  \$ .*vercel (env|link|domains|integration)' "$LAST_LOG" | grep -v -- '--scope contoso-team' || true)"
  if [ -z "$bad" ]; then pass; else fail "a vercel command without --scope: $(printf '%s' "$bad" | head -1)"; fi
}
write_config
run_case "vercel: test lane, existing database" 0 -- bash "$VE" --site "$SLUG" plan
expect "already linked to contoso-example"; expect "vercel domains add portal.contoso.com contoso-example"
expect "DATABASE_URL"; expect "'https://portal.contoso.com' | vercel env add BETTER_AUTH_URL production"
expect "'false' | vercel env add ALLOW_PASSWORD_SIGNIN production"
expect "'true' | vercel env add ALLOW_PASSWORD_SIGNIN preview"
expect "(VERCEL_BRANCH_URL), never VERCEL_URL"; expect "ALLOW_PASSWORD_SIGNIN=true (PASSWORD_LANE=local+preview)"
expect "(plan only: nothing was written)"
every_vercel_line_scoped

# A fresh site that is not linked yet: said once, as the plan's own first step, not as a warning.
mv "$SITE/.vercel/project.json" "$WORK/project.json.kept"
run_case "vercel: a site not linked yet" 0 -- bash "$VE" --site "$SLUG" plan
mv "$WORK/project.json.kept" "$SITE/.vercel/project.json"
expect "not linked to a Vercel project yet: the link target (the first step of a full plan) links it to contoso-example"
expect_not "is linked to"
CASE="the not-linked line is said once"
if [ "$(grep -c "not linked to a Vercel project yet" "$LAST_LOG")" = 1 ]; then pass; else fail "the not-linked line was said more than once"; fi

write_config DB_SOURCE=neon
run_case "vercel: Neon from a scratch folder" 0 -- bash "$VE" --site "$SLUG" plan database
expect "vercel integration add neon --name contoso-example-db -e production --no-env-pull --scope contoso-team"
expect_not "-e preview"; expect "Preview needs its own database with no production rows"
expect "Never a Neon branch per preview made from production's branch"
expect "database-url-preview)\" npx drizzle-kit migrate"
expect "<a new empty scratch folder outside the site>"
every_vercel_line_scoped

write_config DB_SOURCE=other
run_case "vercel: the person's own database URL" 0 -- bash "$VE" --site "$SLUG" plan database
expect "vercel env add DATABASE_URL production --sensitive"; expect "database-url-preview"

write_config PASSWORD_LANE=local PREVIEW_MODE=none
run_case "vercel: local lane only, no previews" 0 -- bash "$VE" --site "$SLUG" plan
expect "'false' | vercel env add ALLOW_PASSWORD_SIGNIN preview"; expect "PREVIEW_MODE=none: previews get no sign-in"
expect "ALLOW_PASSWORD_SIGNIN=true (PASSWORD_LANE=local)"

write_config PASSWORD_LANE=off PREVIEW_MODE=none
run_case "vercel: no test lane anywhere" 0 -- bash "$VE" --site "$SLUG" plan local
expect "ALLOW_PASSWORD_SIGNIN=false (PASSWORD_LANE=off)"

write_config PREVIEW_MODE=stable-host PREVIEW_HOST=contoso-example-git-preview-contoso-team.vercel.app
run_case "vercel: a stable preview host" 0 -- bash "$VE" --site "$SLUG" plan preview
expect "'https://contoso-example-git-preview-contoso-team.vercel.app' | vercel env add BETTER_AUTH_URL preview"
expect "vercel env add MICROSOFT_ENTRA_CLIENT_SECRET preview --sensitive"

write_config VERCEL_SCOPE=
run_case "vercel: a personal account, no scope" 0 -- bash "$VE" --site "$SLUG" plan prod
expect_not "--scope"

run_case "vercel: run needs one target" nonzero -- bash "$VE" --site "$SLUG" run
expect "Run one target at a time"

# ---------------------------------------------------------------------------
echo "## copy-templates.sh (plan) and the fill"
write_config
run_case "copy: plan" 0 -- bash "$SCRIPTS/copy-templates.sh" --site "$SLUG" plan
expect "NEW    src/lib/auth/settings.ts"; expect "NEW    scripts/dev-test-user.ts"
expect "(plan only: nothing was copied)"
write_config PASSWORD_LANE=off PREVIEW_MODE=none
run_case "copy: PASSWORD_LANE=off skips the test lane" 0 -- bash "$SCRIPTS/copy-templates.sh" --site "$SLUG" plan
expect "skipped: scripts/dev-test-user.ts"; expect "NEW    src/app/sign-in/password-sign-in-form.tsx"
expect_not "NEW    scripts/dev-test-user.ts"

# write_config_at <slug> <site dir> [KEY=value...]: a second site's config, for
# a throwaway copy of the site that a run may write into.
write_config_at() {
  local slug="$1" dir="$2" kv; shift 2
  mkdir -p "$HOME/.config/$slug"; chmod 700 "$HOME/.config/$slug"
  sed -e "s|__SITE_DIR__|$dir|" -e "s|^SITE=.*|SITE=$slug|" "$FIXTURES/entra-site.env" > "$HOME/.config/$slug/entra-site.env"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$HOME/.config/$slug/entra-site.env"; done
  chmod 600 "$HOME/.config/$slug/entra-site.env"; : > "$HOME/.config/$slug/entra-state.env"
}
d="$(site_variant copy-mjs 'p.name="copy-mjs"')"; printf 'export default {};\n' > "$d/next.config.mjs"
write_config_at copy-mjs "$d"
run_case "copy: a site's own next.config.mjs is MERGE, never a second config" 0 -- bash "$SCRIPTS/copy-templates.sh" --site copy-mjs plan
expect "MERGE  next.config.mjs"; expect_not "NEW    next.config.ts"
d="$(site_variant copy-run 'p.name="copy-run"')"
write_config_at copy-run "$d"
run_case "copy: the plan for a run" 0 -- bash "$SCRIPTS/copy-templates.sh" --site copy-run plan
PLANNED="$(sed -n 's/^  NEW    //p' "$LAST_LOG")"
run_case "copy: run on a throwaway copy of the site" 0 -- bash "$SCRIPTS/copy-templates.sh" --site copy-run run
expect_not "still holds a placeholder"; expect "requirePagePerson()"
CASE="copy run: every planned file is written, with no placeholder left"
missing=""; left=""
for f in $PLANNED; do
  if [ ! -f "$d/$f" ]; then missing="$missing $f"
  elif grep -Eq '__[A-Z][A-Z_]*[A-Z]__' "$d/$f"; then left="$left $f"; fi
done
if [ -n "$PLANNED" ] && [ -z "$missing$left" ]; then pass; else fail "planned: $(printf '%s' "$PLANNED" | grep -c .); missing:${missing:- none}; placeholders in:${left:- none}"; fi
d="$(site_variant copy-next15 'p.dependencies.next="^15.5.0"')"
write_config_at copy-next15 "$d"
run_case "copy: Next 15 writes middleware.ts on the Node.js runtime" 0 -- bash "$SCRIPTS/copy-templates.sh" --site copy-next15 run
expect 'written as middleware.ts with export middleware and runtime: "nodejs"'
CASE="copy run: Next 15 middleware"
if [ ! -e "$d/src/proxy.ts" ] && grep -q '^export function middleware(' "$d/src/middleware.ts" 2>/dev/null \
  && grep -q 'runtime: "nodejs"' "$d/src/middleware.ts"; then pass; else fail "src/middleware.ts needs export function middleware and runtime: \"nodejs\", and no proxy.ts"; fi

# people.json: write_people (tenant-setup.sh) run on its own with a made-up
# roster, parsed back with node: quotes and backslashes in names, roles.
sed -n '/^roster_ids() {/,/^}/p;/^write_people() {/,/^}/p' "$SCRIPTS/tenant-setup.sh" > "$WORK/people-fns.sh"
mkdir -p "$WORK/people"
cat > "$WORK/people-driver.sh" <<'EOF'
set -euo pipefail
# shellcheck source=/dev/null
. "$1/lib.sh"
# shellcheck source=/dev/null
. "$2"
MODE=run; CONFIG_DIR="$3"; PEOPLE_FILE="$3/people.json"; T=$'\t'
ROSTER="$4${T}owner@contoso.com${T}First \"Admin\" O'Brien${T}administrator${T}listed
$5${T}pat@contoso.com${T}Pat \\ Back${T}member${T}group
"
write_people
node -e '
const fs=require("fs"),[f,a,b]=process.argv.slice(1);
const j=JSON.parse(fs.readFileSync(f,"utf8"));
const ok=j.length===2&&j[0].oid===a&&j[0].role==="administrator"&&j[0].name==="First \"Admin\" O'"'"'Brien"
  &&j[1].oid===b&&j[1].email==="pat@contoso.com"&&j[1].name==="Pat \\ Back"&&j[1].role==="member"
  &&(fs.statSync(f).mode&0o777)===0o600;
console.log(ok?"people.json ok":"people.json WRONG: "+JSON.stringify(j));' "$PEOPLE_FILE" "$4" "$5"
EOF
run_case "tenant: people.json holds the roster as valid JSON" 0 -- bash "$WORK/people-driver.sh" "$SCRIPTS" "$WORK/people-fns.sh" "$WORK/people" "$(fake_guid 51)" "$(fake_guid 52)"
expect "people.json ok"; expect "2 people, 1 administrator(s)"

write_config ROLE_SOURCE=entra JOIN_MODE=group "EMAIL_DOMAINS='contoso.com,Contoso.co.uk'"
FILL_IN="$WORK/fill-in.txt"
printf '%s\n' '"__SITE_NAME__" "__EMAIL_DOMAINS__" "__DOMAIN__" "__VERCEL_HOST__" "./__SRC_ROOT__/lib"' \
  '"__SESSION_IDLE_MINUTES__" "__SESSION_MAX_HOURS__" "__ROLE_SOURCE__" "__JOIN_MODE__"' > "$FILL_IN"
# shellcheck disable=SC2016  # the inner script expands its own arguments
run_case "lib.sh fill: every placeholder" 0 -- bash -c '. "$1/lib.sh"; load_config "$2"; ROOT_SRC=src; fill "$3"' _ "$SCRIPTS" "$SLUG" "$FILL_IN"
expect '"Contoso Example" "contoso.com,contoso.co.uk" "portal.contoso.com" "contoso-example.vercel.app" "./src/lib"'
expect '"45" "10" "entra" "group"'
expect_not "__"

# ---------------------------------------------------------------------------
echo "## verify-tenant.sh and verify-site.sh (read only)"
write_config
run_case "verify-tenant: reads only" any -- bash "$SCRIPTS/verify-tenant.sh" --site "$SLUG"
expect "| # | Control | Where | Result | Evidence |"; expect "C17"; expect "PASS (decided)"
write_config ROLE_SOURCE=site
run_case "verify-site: a refused local port" any -- bash "$SCRIPTS/verify-site.sh" portal.contoso.com --no-post --base http://127.0.0.1:9
expect "| # | Check | Result | Evidence |"

# C25 and C26 against a made-up local site (node, 127.0.0.1, a free port):
# every page answers a 307 to /sign-in; in "leak" mode the 307 to a request
# with a session cookie carries the page, as a layout-only gate does.
SRV_MODE="$WORK/srv-mode"; SRV_PORT="$WORK/srv-port"; echo clean > "$SRV_MODE"
node -e '
const http=require("http"),fs=require("fs"),[mode,portFile]=process.argv.slice(1);
const s=http.createServer((q,r)=>{
  const u=q.url;
  if(u==="/sign-in"||u.startsWith("/sign-in?")){r.writeHead(200,{"content-type":"text/html"});r.end("<p>Sign in</p>");return;}
  if(u.startsWith("/api/")){r.writeHead(401);r.end();return;}
  const leak=fs.readFileSync(mode,"utf8").trim()==="leak"&&/session_token=/.test(q.headers.cookie||"");
  r.writeHead(307,{location:"/sign-in?next="+encodeURIComponent(u)});
  r.end(leak?"<html><body>ENTRA-PROBE-MARKER signed-in page</body></html>":"");
});
s.listen(0,"127.0.0.1",()=>fs.writeFileSync(portFile,String(s.address().port)));' "$SRV_MODE" "$SRV_PORT" &
SRV_PID=$!
i=0; while [ ! -s "$SRV_PORT" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
if [ -s "$SRV_PORT" ]; then
  VB="http://127.0.0.1:$(cat "$SRV_PORT")"
  VS=(bash "$SCRIPTS/verify-site.sh" portal.contoso.com --no-post --base "$VB")
  run_case "verify-site: a gate that refuses before any page renders" any -- "${VS[@]}"
  expect "| C26 | A made-up better-auth.session_token on / serves no page | PASS |"
  expect "| C26 | A made-up __Secure-better-auth.session_token on / with a page-to-page request serves no page | PASS |"
  echo leak > "$SRV_MODE"
  run_case "verify-site: a 307 that carries the page is a FAIL" any -- "${VS[@]}"
  expect "| C26 | A made-up better-auth.session_token on / serves no page | FAIL | 307 $VB/sign-in?next=%2F, but the body carries rendered page content"
  expect "| C26 | A made-up better-auth.session_token on / with a page-to-page request serves no page | FAIL |"
  run_case "verify-site: --marker names the page" any -- "${VS[@]}" --marker ENTRA-PROBE-MARKER
  expect "but the body holds the page marker"
  echo clean > "$SRV_MODE"
  run_case "verify-site: a public / without --probe" any -- "${VS[@]}" --public /
  expect "| C25 | A signed-out visit to / goes to /sign-in | N/A |"; expect "| C26 | A signed-in page is probed | FAIL |"
  run_case "verify-site: a public / with --probe" any -- "${VS[@]}" --public / --probe /dashboard
  expect "| C26 | A made-up better-auth.session_token on /dashboard serves no page | PASS |"; expect_not "| C26 | A signed-in page is probed"
  run_case "verify-site: --probe on a public path is refused" nonzero -- "${VS[@]}" --public /about --probe /about
  expect "--probe /about is a public path on this site"
  mkdir -p "$WORK/pub-site/src/lib/auth"
  printf 'export const PUBLIC_PATHS = ["/sign-in", "/api/auth", "/"] as const;\n' > "$WORK/pub-site/src/lib/auth/settings.ts"
  # shellcheck disable=SC2016  # the inner script expands its own arguments
  run_case "verify-site: PUBLIC_PATHS read from the site's settings" any -- bash -c 'cd "$1" && shift && "$@"' _ "$WORK/pub-site" "${VS[@]}"
  expect "Public paths read from src/lib/auth/settings.ts: /sign-in /api/auth /"; expect "| C25 | A signed-out visit to / goes to /sign-in | N/A |"
  { kill "$SRV_PID"; wait "$SRV_PID"; } 2>/dev/null || true; SRV_PID=""
else
  CASE="verify-site against a made-up local site"; fail "the made-up local site did not start"
fi

# ---------------------------------------------------------------------------
echo "## Nothing was written, and nothing secret was printed"
CASE="no write verb reached a stub"
w="$(grep -h '^WRITE-ATTEMPT' "$AZ_STUB_LOG" "$VERCEL_STUB_LOG" "$GH_STUB_LOG" || true)"
if [ -z "$w" ]; then pass; else fail "$(printf '%s\n' "$w" | head -3)"; fi
CASE="the stubs were used"
if [ -s "$AZ_STUB_LOG" ] && [ -s "$VERCEL_STUB_LOG" ] && [ -s "$GH_STUB_LOG" ]; then pass; else fail "a stub log is empty: the scripts did not reach the fake CLIs"; fi
# SETUP.md step 4's "Not Claude Code?" block pulls only from this repository.
# git is wrapped so a pull or clone of the real URL is recorded, never run.
CASE="SETUP.md's clone block is found"
clone_block="$(awk '/^\*\*Not Claude Code\?\*\*/{f=1} f&&/^```bash/{g=1;next} g&&/^```/{exit} g' "$ROOT/SETUP.md")"
if [ -z "$clone_block" ]; then fail "no bash block after **Not Claude Code?** in SETUP.md"; else
  pass
  CH="$WORK/clone-home"; mkdir -p "$CH"
  # shellcheck disable=SC2016  # expanded by the inner bash, not here
  gitw='git() { case "$1 $3" in "clone "*|"-C pull") echo "GIT-CALLED: $*"; return 0 ;; esac; command git "$@"; }; export -f git'
  git init -q --bare "$WORK/fork.git"
  git clone -q "$WORK/fork.git" "$WORK/fork-work" 2>/dev/null
  git -C "$WORK/fork-work" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m one
  git -C "$WORK/fork-work" push -q origin HEAD 2>/dev/null
  git clone -q "$WORK/fork.git" "$CH/entra-id-auth" 2>/dev/null
  git -C "$WORK/fork-work" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m two
  git -C "$WORK/fork-work" push -q origin HEAD 2>/dev/null
  before="$(git -C "$CH/entra-id-auth" rev-parse HEAD)"
  run_case "SETUP.md clone block: a fork is refused, nothing pulled" nonzero -- env HOME="$CH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -c "$clone_block"
  expect "FOREIGN: $WORK/fork.git"
  CASE="SETUP.md clone block: the fork's clone is where it was"
  if [ "$(git -C "$CH/entra-id-auth" rev-parse HEAD)" = "$before" ]; then pass; else fail "the block pulled from a fork"; fi
  # This repository's URL, as the block's own clone line gives it (owner/name).
  repo_url="$(printf '%s\n' "$clone_block" | sed -n 's|.*git clone \(https://github.com/[^ ]*\) .*|\1|p')"
  [ -n "$repo_url" ] || fail "no git clone line in the block"
  repo_path="${repo_url#https://github.com/}"
  for u in "$repo_url.git" "git@github.com:$repo_path" "ssh://git@github.com/$repo_path"; do
    git -C "$CH/entra-id-auth" remote set-url origin "$u"
    run_case "SETUP.md clone block: this repository ($u) is pulled" 0 -- env HOME="$CH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -c "$gitw; $clone_block"
    expect "GIT-CALLED: -C $CH/entra-id-auth pull --ff-only"; expect_not "FOREIGN"
  done
  # A global url.<x>.insteadOf rewrite (a mirror, a token URL) must not turn this repository into a
  # FOREIGN one, and must never print the rewritten URL: the block reads the origin as stored.
  git config -f "$CH/gitconfig" 'url.https://user:secret-token@mirror.example.invalid/.insteadOf' "https://github.com/"
  git -C "$CH/entra-id-auth" remote set-url origin "$repo_url"
  run_case "SETUP.md clone block: an insteadOf rewrite does not make this repository foreign" 0 -- env HOME="$CH" GIT_CONFIG_GLOBAL="$CH/gitconfig" GIT_CONFIG_NOSYSTEM=1 bash -c "$gitw; $clone_block"
  expect "GIT-CALLED: -C $CH/entra-id-auth pull --ff-only"; expect_not "FOREIGN"; expect_not "secret-token"
  AT="@" # kept out of the URL text below, which would read as an email address
  # A token in the stored origin is neither a reason to call this repository foreign nor printed.
  git -C "$CH/entra-id-auth" remote set-url origin "https://x-access-token:secret-token${AT}github.com/$repo_path"
  run_case "SETUP.md clone block: a token in the origin is stripped, this repository is pulled" 0 -- env HOME="$CH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -c "$gitw; $clone_block"
  expect "GIT-CALLED: -C $CH/entra-id-auth pull --ff-only"; expect_not "FOREIGN"; expect_not "secret-token"
  git -C "$CH/entra-id-auth" remote set-url origin "https://x-access-token:secret-token${AT}github.com/someone-else/fork"
  run_case "SETUP.md clone block: a foreign origin with a token is refused without printing the token" nonzero -- env HOME="$CH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -c "$gitw; $clone_block"
  expect "FOREIGN: https://github.com/someone-else/fork"; expect_not "secret-token"
  # The owner in another letter case, and a trailing slash, are this repository too.
  git -C "$CH/entra-id-auth" remote set-url origin "https://github.com/$(printf '%s' "$repo_path" | tr '[:lower:]' '[:upper:]')/"
  run_case "SETUP.md clone block: the owner in capitals and a trailing slash are pulled" 0 -- env HOME="$CH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -c "$gitw; $clone_block"
  expect "GIT-CALLED: -C $CH/entra-id-auth pull --ff-only"; expect_not "FOREIGN"
  # A folder that is not a git clone gets its own words, never a raw git error.
  rm -rf "$CH/entra-id-auth"; mkdir -p "$CH/entra-id-auth"; : > "$CH/entra-id-auth/notes.txt"
  run_case "SETUP.md clone block: a folder that is not a clone is refused" nonzero -- env HOME="$CH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -c "$gitw; $clone_block"
  expect "NOT-A-REPO: $CH/entra-id-auth"; expect_not "GIT-CALLED"
  rm -rf "$CH/entra-id-auth"
  run_case "SETUP.md clone block: no folder yet, cloned" 0 -- env HOME="$CH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -c "$gitw; $clone_block"
  expect "GIT-CALLED: clone $repo_url $CH/entra-id-auth"
fi

# SETUP.md's no-binary branch reads installed_plugins.json with one jq line.
# Run that exact line against a record shaped the way Claude Code writes it:
# each plugin id maps to a list of install records, one per scope.
CASE="SETUP.md reads the user-scope install record"
jq_line="$(grep -E "^ *jq -r '\[\.plugins\[" "$ROOT/SETUP.md" | head -1 | sed 's/^ *//')"
if [ -z "$jq_line" ]; then
  fail "no jq line for installed_plugins.json found in SETUP.md"
elif ! command -v jq >/dev/null 2>&1; then
  skip "jq is not installed"
else
  run_case "SETUP.md reads the user-scope install record" 0 -- env CLAUDE_CONFIG_DIR="$FIXTURES/claude-config" bash -c "$jq_line"
  expect "1.0.6"; expect "/srv/example/.claude/plugins/cache/entra-id-auth/entra-id-auth/1.0.6"
  expect_not "0.9.0"; expect_not "Cannot index"
fi

CASE="the site folder is unchanged"
st="$(git -C "$SITE" status --porcelain 2>&1)"
if [ -z "$st" ]; then pass; else fail "plan mode changed the site: $(printf '%s' "$st" | head -3 | tr '\n' ' ')"; fi
CASE="the config folder holds only what the test put there"
extra=""
for f in "$CONFIG_DIR"/* "$CONFIG_DIR"/.[!.]*; do
  [ -e "$f" ] || continue
  case "${f##*/}" in
    entra-site.env|entra-state.env|better-auth-secret-prod|cron-secret-prod|entra-client-secret-prod|entra-client-secret-dev|database-url-prod) ;;
    *) extra="$extra ${f##*/}" ;;
  esac
done
if [ -z "$extra" ]; then pass; else fail "plan mode wrote:$extra"; fi
CASE="the state file stays empty in plan mode"
if [ ! -s "$CONFIG_DIR/entra-state.env" ]; then pass; else fail "entra-state.env was written"; fi
CASE="no secret value was printed"
if grep -qF "$CANARY" "$ALL"; then fail "a canary secret's value appears in the output"; else pass; fi
CASE="nothing secret-looking was printed"
sus="$(grep -nE -- '-----BEGIN [A-Z ]*PRIVATE KEY|[A-Za-z0-9_~.-]{3}[0-9]Q~[A-Za-z0-9_~.-]{30,}|[A-Za-z0-9+]{40,}={1,2}' "$ALL" | head -3 || true)"
if [ -z "$sus" ]; then pass; else fail "$sus"; fi

echo
printf 'passed %s, failed %s, skipped %s\n' "$PASSES" "$FAILS" "$SKIPS"
if [ "$FAILS" -ne 0 ]; then
  echo "Full output of every case: kept at $WORK.kept"
  cp -R "$WORK" "$WORK.kept" 2>/dev/null || true
  exit 1
fi
echo "All scripts ran in plan mode against the stubs: no real Microsoft, Vercel or GitHub call, nothing written."
