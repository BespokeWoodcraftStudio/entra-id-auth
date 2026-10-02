#!/usr/bin/env bash
# Settings and secrets on Vercel and in .env.local, plus the project link, the
# domain and the database, each its own target.
#
#   vercel-env.sh --site <slug> plan           every command and variable, nothing written
#   vercel-env.sh --site <slug> run link       link the site's folder to VERCEL_PROJECT
#   vercel-env.sh --site <slug> run domain     add DOMAIN to the project
#   vercel-env.sh --site <slug> run database   per DB_SOURCE (Neon from a scratch folder)
#   vercel-env.sh --site <slug> run prod       production variables
#   vercel-env.sh --site <slug> run preview    preview variables (their own secrets)
#   vercel-env.sh --site <slug> run local      .env.local in the site folder
#
# Every value goes in on stdin from a file. Nothing secret is put on a command
# line, printed or committed. Secrets are made with openssl into the owner-only
# ~/.config/<site>/. Every Vercel call carries --scope VERCEL_SCOPE when set.
# BETTER_AUTH_URL is always set explicitly where an address is fixed, and
# never built from VERCEL_URL.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
need vercel openssl node

[ "${1:-}" = "--site" ] || die "Usage: vercel-env.sh --site <slug> plan|run [link|domain|database|prod|preview|local]"
load_config "${2:-}"; shift 2
MODE="${1:-plan}"; TARGET="${2:-all}"
[ "$MODE" = "plan" ] || [ "$MODE" = "run" ] || die "Mode is plan or run."
[ "$MODE" = "run" ] && [ "$TARGET" = "all" ] && die "Run one target at a time (link, domain, database, prod, preview or local), after a yes for that target."
[ -n "${SITE_DIR:-}" ] || die "SITE_DIR is not set in the config."
[ -n "${VERCEL_PROJECT:-}" ] || die "VERCEL_PROJECT is not set in the config."

VSCOPE=()
[ -z "$VERCEL_SCOPE" ] || VSCOPE=(--scope "$VERCEL_SCOPE")
SCOPE_TXT="${VERCEL_SCOPE:+ --scope $VERCEL_SCOPE}"

# vc <args...>: the Vercel CLI with the site's scope, shown first, run only in run mode.
vc() { run_cmd "$VC_WHY" -- vercel "$@" ${VSCOPE[@]+"${VSCOPE[@]}"}; }

# linked_field <key>: a field of the site's .vercel/project.json, or nothing.
linked_field() {
  local pj="$SITE_DIR/.vercel/project.json"
  [ -f "$pj" ] || return 0
  node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]]||""))}catch{}' "$pj" "$1" 2>/dev/null || true
}

# The folder must be linked to THIS site's Vercel project (and team, when the
# scope is a team id). `vercel env add --force` overwrites; run in a folder
# linked to another project it would replace that live site's secrets.
LINK_NOTED=""
check_linked_project() {
  local linked org
  linked="$(linked_field projectName)"; org="$(linked_field orgId)"
  if [ "$linked" = "$VERCEL_PROJECT" ]; then
    case "$VERCEL_SCOPE" in
      team_*) [ "$org" = "$VERCEL_SCOPE" ] || { [ "$MODE" = "plan" ] && note "WARNING: the link names team ${org:-none}, not $VERCEL_SCOPE. A run refuses."; [ "$MODE" = "plan" ] || die "$SITE_DIR is linked to team ${org:-none}, not $VERCEL_SCOPE. Nothing was written."; } ;;
    esac
    note "linked Vercel project: $linked (matches the config)"
    return 0
  fi
  if [ "$MODE" = "plan" ]; then
    # Not linked at all is the usual state of a fresh site: the link target
    # (the first step of a full plan) links it. Said once, not per section.
    if [ -z "$linked" ]; then
      [ -n "$LINK_NOTED" ] || note "not linked to a Vercel project yet: the link target (the first step of a full plan) links it to $VERCEL_PROJECT; until then a run of this target refuses."
      LINK_NOTED=1
    else
      note "WARNING: $SITE_DIR is linked to '$linked', not $VERCEL_PROJECT. A run refuses until the link target runs (a write, on a yes)."
    fi
    return 0
  fi
  [ -n "$linked" ] || die "$SITE_DIR is not linked to Vercel project $VERCEL_PROJECT. Run the link target first: vercel-env.sh --site $SITE run link (a write; on a yes)."
  die "$SITE_DIR is linked to Vercel project $linked, not $VERCEL_PROJECT. Nothing was written."
}

# need_value <name> <value>: a run never writes a placeholder to Vercel.
need_value() {
  [ "$MODE" = "run" ] || return 0
  [ -n "$2" ] || die "$1 is not recorded yet. Run the tenant step that makes it first."
}

# make_secret <name>: 48 random bytes, base64, into an owner-only file, once.
make_secret() {
  local f="$CONFIG_DIR/$1"
  if [ -s "$f" ]; then note "$1 exists (kept)"; return 0; fi
  printf '  $ openssl rand -base64 48 > %s   (owner-only, never printed)\n' "$f"
  [ "$MODE" = "run" ] && (umask 077; openssl rand -base64 48 | tr -d '\n' > "$f")
  return 0
}

# put <NAME> <target> <config|sensitive> <file-or-"=value">: a value that is
# not secret may be shown ("=value"); a secret comes from its file, unseen.
put() {
  local name="$1" target="$2" kind="$3" src="$4" file flag
  flag="--no-sensitive"; [ "$kind" = "sensitive" ] && flag="--sensitive"
  if [ "${src:0:1}" = "=" ]; then
    file="$(mktemp)"; chmod 600 "$file"; printf '%s' "${src:1}" > "$file"
    printf "  \$ printf '%%s' '%s' | vercel env add %s %s %s --force --yes --cwd %s%s\n" "${src:1}" "$name" "$target" "$flag" "$SITE_DIR" "$SCOPE_TXT"
  else
    file="$src"
    printf '  $ vercel env add %s %s %s --force --yes --cwd %s%s < %s   (value never printed)\n' "$name" "$target" "$flag" "$SITE_DIR" "$SCOPE_TXT" "$file"
  fi
  if [ "$MODE" = "run" ]; then
    [ -s "$file" ] || [ "${src:0:1}" = "=" ] || die "$file is missing or empty."
    vercel env add "$name" "$target" "$flag" --force --yes --cwd "$SITE_DIR" ${VSCOPE[@]+"${VSCOPE[@]}"} < "$file" >/dev/null
    note "$name set on $target ($kind)"
  fi
  [ "${src:0:1}" = "=" ] && rm -f "$file"
  return 0
}

link() {
  head1 "Link the site's folder to the Vercel project"
  local linked
  linked="$(linked_field projectName)"
  if [ "$linked" = "$VERCEL_PROJECT" ]; then note "already linked to $VERCEL_PROJECT"; return 0; fi
  VC_WHY="Every later command writes to exactly this project${VERCEL_SCOPE:+ in team $VERCEL_SCOPE}. Writes .vercel/ in the site (git-ignored by Vercel's own entry)."
  vc link --yes --project "$VERCEL_PROJECT" --cwd "$SITE_DIR"
}

domain() {
  head1 "The production address on the project"
  VC_WHY="The site must answer at https://$DOMAIN: the redirect URI, the cookie and the trusted origin name it exactly. Vercel then shows the DNS record to add, if any."
  vc domains add "$DOMAIN" "$VERCEL_PROJECT"
}

# preview_db: Preview gets its own database with no production rows, from the
# owner-only file the person writes; never production's URL, never a Neon
# branch copied from production's branch (control C38).
preview_db() {
  if [ -s "$CONFIG_DIR/database-url-preview" ]; then put DATABASE_URL preview sensitive "$CONFIG_DIR/database-url-preview"
  else note "Preview needs its own database with no production rows: the person creates it empty (a second Neon database or project, or their own), writes its URL into $CONFIG_DIR/database-url-preview (owner-only; the agent never reads it), then reruns this target."; fi
  note "The preview database starts empty and has no tables: migrate it from the site's folder, now and after every schema change, with: DATABASE_URL=\"\$(cat $CONFIG_DIR/database-url-preview)\" npx drizzle-kit migrate   (the URL is never printed). Until then every preview sign-in fails (relation \"session\" does not exist)."
  note "Never a Neon branch per preview made from production's branch: a branch is a copy of its parent, so every preview would hold production's people, sign-in log (emails, IP addresses) and Better Auth's account rows."
}

database() {
  head1 "Database (DB_SOURCE=$DB_SOURCE)"
  case "$DB_SOURCE" in
    existing)
      local names
      names="$(vercel env ls production --cwd "$SITE_DIR" ${VSCOPE[@]+"${VSCOPE[@]}"} 2>/dev/null | awk '$1 ~ /^[A-Z][A-Z0-9_]*$/ {print $1}' | sort -u || true)"
      if printf '%s\n' "$names" | grep -qx DATABASE_URL; then note "DATABASE_URL is already on the project for production (names only were read); kept."
      else note "WARNING: no DATABASE_URL on the project for production (names only were read). Choose DB_SOURCE=neon, or other with your own URL."; fi
      names="$(vercel env ls preview --cwd "$SITE_DIR" ${VSCOPE[@]+"${VSCOPE[@]}"} 2>/dev/null | awk '$1 ~ /^[A-Z][A-Z0-9_]*$/ {print $1}' | sort -u || true)"
      if printf '%s\n' "$names" | grep -qx DATABASE_URL; then
        note "WARNING: Preview already has a DATABASE_URL (names only were read). An existing integration may feed it production's database or a branch of it (Neon's branch per preview does). Check its source in the project's Environment Variables (control C38); if it is production's or a copy, remove it from Preview and give Preview its own database (below)."
      fi ;;
    neon)
      local scratch="<a new empty scratch folder outside the site>"
      [ "$MODE" = "run" ] && scratch="$(mktemp -d "${TMPDIR:-/tmp}/entra-id-auth-neon.XXXXXX")"
      note "Run from a scratch folder outside the site: the CLI may write files into the folder it runs in."
      VC_WHY="The scratch folder is linked to the same project, so the integration connects to it and nothing lands in the site's folder."
      vc link --yes --project "$VERCEL_PROJECT" --cwd "$scratch"
      printf '  $ (cd %s && vercel integration add neon --name %s -e production --no-env-pull%s)\n' "$scratch" "$SITE-db" "$SCOPE_TXT"
      printf '    why: %s\n' "A Neon Postgres (free plan available) on the Vercel Marketplace, for production only. It adds DATABASE_URL, DATABASE_URL_UNPOOLED and POSTGRES_URL. Preview is left out on purpose: it gets its own empty database (below). The first time, the person accepts the Marketplace terms themselves."
      if [ "$MODE" = "run" ]; then
        ( cd "$scratch" && vercel integration add neon --name "$SITE-db" -e production --no-env-pull ${VSCOPE[@]+"${VSCOPE[@]}"} )
        rm -rf "$scratch"
      fi ;;
    other)
      if [ -s "$CONFIG_DIR/database-url-prod" ]; then put DATABASE_URL production sensitive "$CONFIG_DIR/database-url-prod"
      else note "DB_SOURCE=other: the person writes their production URL into $CONFIG_DIR/database-url-prod (owner-only; the agent never reads it), then this target sends it."; fi ;;
  esac
  preview_db
}

prod() {
  head1 "Production"
  check_linked_project
  need_value TENANT_ID "${TENANT_ID:-}"; need_value APP_ID_prod "${APP_ID_prod:-}"; need_value SECRET_END_prod "${SECRET_END_prod:-}"
  if [ "$NEEDS_M365_SERVER" = "yes" ]; then
    need_value READER_APP_ID "${READER_APP_ID:-}"; need_value READER_CERT_END "${READER_CERT_END:-}"; need_value MAILBOXES "${MAILBOXES:-}"
  fi
  make_secret better-auth-secret-prod
  make_secret cron-secret-prod
  put MICROSOFT_ENTRA_TENANT_ID production config "=${TENANT_ID:-<TENANT_ID>}"
  put MICROSOFT_ENTRA_CLIENT_ID production config "=${APP_ID_prod:-<APP_ID_prod>}"
  put MICROSOFT_ENTRA_CLIENT_SECRET production sensitive "$CONFIG_DIR/entra-client-secret-prod"
  put MICROSOFT_ENTRA_CLIENT_SECRET_EXPIRES production config "=${SECRET_END_prod:-<SECRET_END_prod>}"
  put BETTER_AUTH_SECRET production sensitive "$CONFIG_DIR/better-auth-secret-prod"
  put BETTER_AUTH_URL production config "=https://$DOMAIN"
  put AUTH_TRUSTED_ORIGINS production config "=https://$DOMAIN${VERCEL_HOST:+,https://$VERCEL_HOST}"
  put NEXT_PUBLIC_APP_URL production config "=https://$DOMAIN"
  put CRON_SECRET production sensitive "$CONFIG_DIR/cron-secret-prod"
  put ALLOW_PASSWORD_SIGNIN production config "=false"
  if [ "$NEEDS_M365_SERVER" = "yes" ]; then
    put M365_READER_TENANT_ID production config "=${TENANT_ID:-<TENANT_ID>}"
    put M365_READER_CLIENT_ID production config "=${READER_APP_ID:-<READER_APP_ID>}"
    put M365_READER_CERTIFICATE_PEM production sensitive "$CONFIG_DIR/reader.pem"
    put M365_READER_CERTIFICATE_EXPIRES production config "=${READER_CERT_END:-<READER_CERT_END>}"
    put M365_READER_MAILBOXES production config "=${MAILBOXES:-}"
  fi
  note "why: the Entra secret, the Better Auth secret, CRON_SECRET and the reader key are Sensitive, so nobody can pull them back (control C37). The test sign-in lane is off in production, whatever PASSWORD_LANE says."
}

preview() {
  head1 "Preview (PREVIEW_MODE=$PREVIEW_MODE; its own secrets, never the production Entra secret, control C38)"
  check_linked_project
  local lane=false
  [ "$PASSWORD_LANE" = local+preview ] && lane=true
  [ "$PREVIEW_MODE" = none ] && lane=false
  if [ "$PREVIEW_MODE" = stable-host ]; then
    need_value TENANT_ID "${TENANT_ID:-}"; need_value APP_ID_preview "${APP_ID_preview:-}"; need_value SECRET_END_preview "${SECRET_END_preview:-}"
  fi
  make_secret better-auth-secret-preview
  make_secret cron-secret-preview
  put BETTER_AUTH_SECRET preview sensitive "$CONFIG_DIR/better-auth-secret-preview"
  put CRON_SECRET preview sensitive "$CONFIG_DIR/cron-secret-preview"
  put ALLOW_PASSWORD_SIGNIN preview config "=$lane"
  case "$PREVIEW_MODE" in
    stable-host)
      put MICROSOFT_ENTRA_TENANT_ID preview config "=${TENANT_ID:-<TENANT_ID>}"
      put MICROSOFT_ENTRA_CLIENT_ID preview config "=${APP_ID_preview:-<APP_ID_preview>}"
      put MICROSOFT_ENTRA_CLIENT_SECRET preview sensitive "$CONFIG_DIR/entra-client-secret-preview"
      put MICROSOFT_ENTRA_CLIENT_SECRET_EXPIRES preview config "=${SECRET_END_preview:-<SECRET_END_preview>}"
      put BETTER_AUTH_URL preview config "=https://$PREVIEW_HOST"
      put AUTH_TRUSTED_ORIGINS preview config "=https://$PREVIEW_HOST"
      put NEXT_PUBLIC_APP_URL preview config "=https://$PREVIEW_HOST"
      note "Microsoft sign-in works on https://$PREVIEW_HOST only (its own registration). Other previews have no working Microsoft sign-in (test lane: $lane)." ;;
    test-lane)
      note "No preview registration: previews have no Microsoft sign-in and use the test password lane (.invalid accounts only)."
      note "The lane is empty until a .invalid test account exists in the preview's own database; this target makes none (references/secrets-and-settings.md says how one is made)."
      note "BETTER_AUTH_URL is not set for previews: each preview's address changes per branch, so no fixed value exists. The code takes the branch address Vercel gives (VERCEL_BRANCH_URL), never VERCEL_URL." ;;
    none)
      note "PREVIEW_MODE=none: previews get no sign-in at all (the test lane is off there). Keep them behind Vercel Authentication (Standard Protection)." ;;
  esac
  note "Previews: keep Vercel Authentication on Standard Protection (every deployment except the production domains)."
}

local_env() {
  head1 ".env.local in $SITE_DIR (never committed)"
  local f="$SITE_DIR/.env.local" db="${LOCAL_DATABASE_URL:-postgres://localhost:5432/$SITE}" lane=false
  [ "$PASSWORD_LANE" = off ] || lane=true
  in_git_repo "$SITE_DIR" || die "$SITE_DIR $NOT_A_REPO_HINT"
  ( cd "$SITE_DIR" && git check-ignore -q .env.local ) || die ".env.local is not ignored by git in $SITE_DIR. Add .env*.local to .gitignore first."
  make_secret better-auth-secret-dev
  make_secret cron-secret-dev
  note "adds only missing keys to $f; values come from the files above and the dev registration"
  note "ALLOW_PASSWORD_SIGNIN=$lane (PASSWORD_LANE=$PASSWORD_LANE); BETTER_AUTH_URL and NEXT_PUBLIC_APP_URL: http://localhost:$LOCAL_PORT"
  # A DATABASE_URL already in .env.local is kept, so it is checked like
  # LOCAL_DATABASE_URL: this machine only. .env.local is read the way Next.js
  # reads it (dotenv: the last line wins), and every DATABASE_URL line in it
  # must pass. Its value is never printed.
  local kept_n=0 bad="" v why
  if [ -f "$f" ]; then
    while IFS= read -r v; do
      kept_n=$((kept_n + 1))
      is_local_db "$v" || { [ -n "$bad" ] || bad="$(db_refusal "$v")"; }
    done < <(node "$SKILL_DIR/scripts/read-env.cjs" "$f" DATABASE_URL)
  fi
  if [ -n "$bad" ]; then
    why="DATABASE_URL in .env.local $bad"
    [ "$kept_n" -gt 1 ] && why="$why (it is set on $kept_n lines; Next.js uses the last, and each must be local)"
    [ "$MODE" = "plan" ] && { note "STOP at run: $why. Point it at a local Postgres (for example postgres://localhost:5432/$SITE) or delete the line, so the local migrate and the scripts never write to that database."; }
    [ "$MODE" = "plan" ] || die "$why. Point it at a local Postgres (for example postgres://localhost:5432/$SITE) or delete the line, then rerun. Nothing was written to .env.local."
  elif [ "$kept_n" -gt 0 ]; then
    note "DATABASE_URL: already in .env.local and on this machine (kept)"
    [ "$kept_n" -gt 1 ] && note "DATABASE_URL is set on $kept_n lines, all local; Next.js uses the last. Keep one."
  elif [ -n "${LOCAL_DATABASE_URL:-}" ]; then note "DATABASE_URL: LOCAL_DATABASE_URL from the config (a Postgres on this machine; never production)"
  else note "DATABASE_URL: postgres://localhost:5432/$SITE (the default; set LOCAL_DATABASE_URL to change it; never production)"; fi
  # A kept BETTER_AUTH_URL or NEXT_PUBLIC_APP_URL on another port makes the
  # local check FAIL M3 (the callback names that port). Said here, before the build.
  local k u
  for k in BETTER_AUTH_URL NEXT_PUBLIC_APP_URL; do
    u="$( [ -f "$f" ] && node "$SKILL_DIR/scripts/read-env.cjs" "$f" "$k" | tail -1 || true)"
    [ -z "$u" ] || [ "$u" = "http://localhost:$LOCAL_PORT" ] \
      || note "WARNING: $k in .env.local is kept and is not http://localhost:$LOCAL_PORT (LOCAL_PORT). Change it to that, or set LOCAL_PORT to its port, or the local check FAILs M3."
  done
  [ -z "$bad" ] || return 0
  [ "$MODE" = "run" ] || return 0
  [ -s "$CONFIG_DIR/entra-client-secret-dev" ] || die "No dev client secret yet. Run: tenant-setup.sh --site $SITE run secret dev"
  (umask 077; touch "$f")
  chmod 600 "$f"
  # A last line with no line end would run into the first key added.
  if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then printf '\n' >> "$f"; fi
  # A key is present when dotenv would read it (also `export KEY=` or ` KEY =`).
  has() { node "$SKILL_DIR/scripts/read-env.cjs" "$f" --keys | grep -qx "$1"; }
  add() { has "$1" || printf '%s=%s\n' "$1" "$2" >> "$f"; }
  # add_secret <KEY> <file>: the value goes from its file into .env.local, unseen.
  add_secret() { { printf '%s=' "$1"; cat "$2"; printf '\n'; } >> "$f"; }
  add MICROSOFT_ENTRA_TENANT_ID "${TENANT_ID:?run tenant-setup first}"
  add MICROSOFT_ENTRA_CLIENT_ID "${APP_ID_dev:?run the dev app step first}"
  has MICROSOFT_ENTRA_CLIENT_SECRET || add_secret MICROSOFT_ENTRA_CLIENT_SECRET "$CONFIG_DIR/entra-client-secret-dev"
  add MICROSOFT_ENTRA_CLIENT_SECRET_EXPIRES "${SECRET_END_dev:-}"
  has BETTER_AUTH_SECRET || add_secret BETTER_AUTH_SECRET "$CONFIG_DIR/better-auth-secret-dev"
  has CRON_SECRET || add_secret CRON_SECRET "$CONFIG_DIR/cron-secret-dev"
  add BETTER_AUTH_URL "http://localhost:$LOCAL_PORT"
  add NEXT_PUBLIC_APP_URL "http://localhost:$LOCAL_PORT"
  add ALLOW_PASSWORD_SIGNIN "$lane"
  add DATABASE_URL "$db"
  note "written: $f (values not shown)"
}

VC_WHY=""
case "$TARGET" in
  all) link; domain; database; prod; preview; local_env ;;
  link) link ;;
  domain) domain ;;
  database) database ;;
  prod) prod ;;
  preview) preview ;;
  local) local_env ;;
  *) die "Target is link, domain, database, prod, preview or local." ;;
esac
if [ "$MODE" = "plan" ]; then printf '\n(plan only: nothing was written)\n'; fi
exit 0
