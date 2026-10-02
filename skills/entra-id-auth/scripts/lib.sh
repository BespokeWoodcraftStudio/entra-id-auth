# shellcheck shell=bash disable=SC2034  # sourced: its constants are read by the scripts that source it
# Shared helpers for the entra-id-auth scripts. Sourced, never run.
#
# Rules every script here keeps:
# - A secret is written from a command straight to an owner-only file. It is
#   never echoed, never put on a command line, never logged.
# - A write to the tenant or to Vercel runs only through `run_cmd`, which
#   prints the command first. `plan` mode prints and does nothing.
# - Ids, names, dates and counts may be printed. People are counted, not listed.
# - Nothing written anywhere names this machine's paths or accounts.

set -euo pipefail

# The skill's own folder, found from this file, so the scripts run the same
# from a plugin install, a clone or a copy in .claude/skills.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
# Microsoft Graph delegated permission ids (the same in every tenant).
SCOPE_OPENID="37f7f235-527c-4136-accd-4a02d197296e"
SCOPE_PROFILE="14dad69e-099b-42c9-810b-d002981feec1"
SCOPE_EMAIL="64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0"
DEFAULT_APP_ROLE="00000000-0000-0000-0000-000000000000"

MODE="${MODE:-plan}"

die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
note() { printf '  - %s\n' "$*"; }
head1() { printf '\n## %s\n' "$*"; }

# The Node line the tests need, and how to get it, for any machine.
NODE_NEED="The tests need Node 22 (22.12 or later), 24, or 26 or later. 24 is recommended (Vercel's default)."
NODE_FIX="Install Node 24 in one of these ways: a version manager (nvm install 24 && nvm alias default 24; or fnm, volta, asdf, mise), Homebrew (brew install node@24, then put its bin folder first on PATH), or your system's package manager (apt, dnf, pacman, or the NodeSource packages). If a version manager's folder comes first on PATH, that manager decides which node runs: set its default rather than installing another copy. A PATH change reaches only terminals opened after it, and the agent keeps the PATH it started with: open a new terminal, check node -v, start the agent again from there, then re-run."

# How to get the other tools, as SETUP.md step 2 gives them.
AZ_FIX="Install the Azure CLI: on macOS, brew install azure-cli; on Linux or Windows (WSL), the command from Microsoft's Azure CLI install page. Then sign in with az login and re-run."
VERCEL_FIX="Install the Vercel CLI: on macOS, brew install vercel; elsewhere, the command from Vercel's CLI install page. Then sign in with vercel login and re-run."
OPENSSL_FIX="Install OpenSSL: on macOS, brew install openssl; elsewhere, the system's package manager."

# need <bin...>: each is on PATH; node must also run (a version manager's shim
# with no version chosen is on PATH but exits non-zero).
need() {
  local bin
  for bin in "$@"; do
    if [ "$bin" = node ]; then
      command -v node >/dev/null 2>&1 || die "Node is not installed (no node on PATH). $NODE_NEED $NODE_FIX"
      node -v >/dev/null 2>&1 || die "node is on PATH ($(command -v node)) but does not run: a version manager (nvm, asdf, volta, mise) with no version chosen, or a broken install. $NODE_NEED $NODE_FIX"
    else
      command -v "$bin" >/dev/null 2>&1 && continue
      case "$bin" in
        az) die "az is not installed or not on PATH. $AZ_FIX" ;;
        vercel) die "vercel is not installed or not on PATH. $VERCEL_FIX" ;;
        openssl) die "openssl is not installed or not on PATH. $OPENSSL_FIX" ;;
        *) die "$bin is not installed or not on PATH." ;;
      esac
    fi
  done
  return 0
}

# Every name the config or the state file may set. They are cleared first, so
# the files alone decide (a value left in the caller's environment, such as
# REQUIRE_MFA=yes, never counts as the site owner's answer). EMAIL_DOMAIN and
# PREVIEW_PASSWORD_LANE are old names, cleared so an old config is caught.
CONFIG_KEYS="SITE SITE_TITLE APP_NAME DOMAIN VERCEL_PROJECT VERCEL_HOST VERCEL_SCOPE EMAIL_DOMAINS SITE_DIR
  GROUP_ID GROUP_NAME GROUP_NICK MEMBERS OWNERS FIRST_ADMIN FIRST_ADMIN_NAME EXTRA_ADMINS
  ASSIGNMENT_MODE ROLE_SOURCE ADMIN_GROUP_ID ADMIN_GROUP_NAME ALLOW_GUESTS JOIN_MODE LIST_GROUP_MEMBERS
  REQUIRE_MFA MFA_ANSWERED_BY SESSION_IDLE_MINUTES SESSION_MAX_HOURS SESSION_ANSWERED_BY
  TENANT_ID LOCAL_PORT LOCAL_DATABASE_URL SECRET_MONTHS ADOPT_EXISTING_APPS HIDE_FROM_MY_APPS
  PASSWORD_LANE PREVIEW_MODE PREVIEW_HOST DB_SOURCE RECORD_IN_REPO
  NEEDS_M365_SERVER MAILBOXES EXCHANGE_ROLE
  EMAIL_DOMAIN PREVIEW_PASSWORD_LANE
  APP_ID_prod APP_ID_dev APP_ID_preview SP_ID_prod SP_ID_dev SP_ID_preview ADMIN_ROLE_ID
  SECRET_END_prod SECRET_END_dev SECRET_END_preview CA_POLICY_ID READER_APP_ID READER_SP_ID READER_CERT_END"

# one_of <NAME> <choice...>: the variable holds one of the choices.
one_of() {
  local name="$1" v="${!1:-}" c; shift
  for c in "$@"; do [ "$v" = "$c" ] && return 0; done
  die "$name must be one of: $*. It is '$v'."
}

# whole_in <NAME> <min> <max>: a whole number in the range.
whole_in() {
  local name="$1" v="${!1:-}"
  printf '%s' "$v" | grep -Eq '^[0-9]{1,4}$' && [ "$v" -ge "$2" ] && [ "$v" -le "$3" ] \
    || die "$name must be a whole number from $2 to $3. It is '$v'."
}

# answered_by <NAME>: who answered, and when. Written into the record and the
# control table, so plain text only: no | < > ` or line breaks can reach them.
answered_by() {
  local name="$1" v="${!1:-}"
  case "$v" in *$'\n'*|*$'\r'*) die "$name must be one line, for example $name='<name>, <YYYY-MM-DD>'." ;; esac
  # Byte-wise, so it holds in any locale: ASCII letters and digits, the listed
  # marks, and any non-ASCII byte (a UTF-8 letter such as e with an accent).
  printf '%s' "$v" | LC_ALL=C grep -Eq "^[A-Za-z0-9 .,()@':"$'\x80'"-"$'\xff'"-]{1,240}\$" \
    || die "$name may hold only letters, digits, spaces and . , - ( ) @ ' : (one short line), for example $name='<name>, <YYYY-MM-DD>' with both filled in. Replace any <placeholder>."
}

# norm_list <text>: a comma list lower-cased, spaces dropped, duplicates
# (ignoring case) removed, order kept.
norm_list() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' ',' | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, - || true
}

# list_count <comma list>: how many entries.
list_count() { printf '%s\n' "$1" | tr ',' '\n' | grep -c . || true; }

is_host() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; }
is_guid() { printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; }
# A work address or user principal name (a guest's name holds #EXT#).
is_address() { printf '%s' "$1" | grep -Eq '^[a-z0-9._%+#-]+@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; }
addr_domain() { printf '%s' "${1##*@}"; }

# check_addresses <NAME>: every entry of a comma list is an address.
check_addresses() {
  local name="$1" v="${!1:-}" a i=0
  for a in ${v//,/ }; do
    i=$((i+1))
    is_address "$a" || die "$name entry number $i is not a work address (name@domain)."
  done
  return 0
}

# on_email_domains <address>: its domain is one of EMAIL_DOMAINS.
on_email_domains() {
  local d
  d="$(addr_domain "$1")"
  printf '%s\n' "$EMAIL_DOMAINS" | tr ',' '\n' | grep -qxF "$d"
}

# load_config <site-slug>: reads ~/.config/<site>/entra-site.env (answers, no
# secrets) and entra-state.env (object ids written by earlier steps), then
# checks every answer. A bad answer stops here, before any read or write.
load_config() {
  local site="${1:-}"
  [ -n "$site" ] || die "Give the site slug, for example: --site contoso-portal"
  printf '%s' "$site" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || die "The site slug is lower case letters, digits and dashes, for example contoso-portal."
  CONFIG_DIR="$HOME/.config/$site"
  CONFIG_FILE="$CONFIG_DIR/entra-site.env"
  STATE_FILE="$CONFIG_DIR/entra-state.env"
  PEOPLE_FILE="$CONFIG_DIR/people.json"
  [ -f "$CONFIG_FILE" ] || die "No $CONFIG_FILE. Write it from references/site-config.md in the skill's folder first."
  # shellcheck disable=SC2086  # a word list on purpose
  unset $CONFIG_KEYS
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  # Which answers the config itself carries (read before the state file).
  local mfa_in_config=no session_in_config=no
  [ -n "${REQUIRE_MFA:-}" ] && mfa_in_config=yes
  [ -n "${SESSION_IDLE_MINUTES:-}${SESSION_MAX_HOURS:-}" ] && session_in_config=yes
  [ -z "${EMAIL_DOMAIN:-}" ] || die "EMAIL_DOMAIN is now EMAIL_DOMAINS (a comma list of the organisation's email domains). Rename it in $CONFIG_FILE."
  [ -z "${PREVIEW_PASSWORD_LANE:-}" ] || die "PREVIEW_PASSWORD_LANE is now PASSWORD_LANE (local+preview, local or off). Rename it in $CONFIG_FILE."
  [ -f "$STATE_FILE" ] || { (umask 077; mkdir -p "$CONFIG_DIR"; : > "$STATE_FILE"); }
  # shellcheck disable=SC1090
  . "$STATE_FILE"

  : "${SITE:?SITE missing in config}" "${APP_NAME:?APP_NAME missing}" "${DOMAIN:?DOMAIN missing}"
  [ "$SITE" = "$site" ] || die "SITE in $CONFIG_FILE is $SITE, not $site."
  SITE_TITLE="${SITE_TITLE:-$APP_NAME}"
  is_host "$DOMAIN" || die "DOMAIN must be a bare host name (no https://, no path, no wildcard, lower case)."
  if [ -n "${VERCEL_HOST:-}" ]; then
    is_host "$VERCEL_HOST" || die "VERCEL_HOST must be a bare host name, for example contoso-portal.vercel.app."
    if [ "$VERCEL_HOST" = "$DOMAIN" ]; then
      case "$DOMAIN" in
        *.vercel.app) die "DOMAIN is the .vercel.app host itself (no custom domain yet), so VERCEL_HOST stays empty: set VERCEL_HOST= in $CONFIG_FILE. No canonical-host redirect is written (control C24 is then N/A)." ;;
        *) die "VERCEL_HOST must be the .vercel.app host, not the domain (the canonical-host redirect would loop). When the site has no custom domain, DOMAIN is the .vercel.app host and VERCEL_HOST stays empty." ;;
      esac
    fi
  fi
  VERCEL_SCOPE="${VERCEL_SCOPE:-}"
  if [ -n "$VERCEL_SCOPE" ]; then
    printf '%s' "$VERCEL_SCOPE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$' || die "VERCEL_SCOPE must be a Vercel team slug or id (letters, digits, dash, underscore)."
  fi

  # Email domains: a comma list of bare domains.
  EMAIL_DOMAINS="$(norm_list "${EMAIL_DOMAINS:-}")"
  [ -n "$EMAIL_DOMAINS" ] || die "EMAIL_DOMAINS is empty. It names the organisation's email domains, for example contoso.com (preflight suggests them; with no custom domain, the tenant's own <name>.onmicrosoft.com)."
  local d
  for d in ${EMAIL_DOMAINS//,/ }; do
    is_host "$d" || die "EMAIL_DOMAINS must be bare domains separated by commas, for example contoso.com,contoso.co.uk."
  done

  # People. Lists are lower-cased and de-duplicated ignoring case.
  MEMBERS="$(norm_list "${MEMBERS:-}")"; OWNERS="$(norm_list "${OWNERS:-}")"
  EXTRA_ADMINS="$(norm_list "${EXTRA_ADMINS:-}")"; MAILBOXES="$(norm_list "${MAILBOXES:-}")"
  FIRST_ADMIN="$(printf '%s' "${FIRST_ADMIN:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  FIRST_ADMIN_NAME="${FIRST_ADMIN_NAME:-}"
  check_addresses MEMBERS; check_addresses OWNERS; check_addresses EXTRA_ADMINS; check_addresses MAILBOXES
  [ -z "$FIRST_ADMIN" ] || is_address "$FIRST_ADMIN" || die "FIRST_ADMIN must be one work address."
  case "$FIRST_ADMIN" in *,*) die "FIRST_ADMIN is one address; put the others in EXTRA_ADMINS." ;; esac
  if [ -n "$EMAIL_DOMAINS" ]; then
    local a
    for a in $FIRST_ADMIN ${EXTRA_ADMINS//,/ }; do
      on_email_domains "$a" || die "An administrator's address is not on EMAIL_DOMAINS ($EMAIL_DOMAINS). The site refuses administrators outside the organisation's own domains: fix the address, or add its domain to EMAIL_DOMAINS."
    done
  fi

  LOCAL_PORT="${LOCAL_PORT:-3000}"
  printf '%s' "$LOCAL_PORT" | grep -Eq '^[0-9]{2,5}$' || die "LOCAL_PORT must be a port number."
  # Microsoft advises an expiration of less than 12 months (control M11).
  SECRET_MONTHS="${SECRET_MONTHS:-11}"
  whole_in SECRET_MONTHS 1 12
  HIDE_FROM_MY_APPS="${HIDE_FROM_MY_APPS:-no}"; one_of HIDE_FROM_MY_APPS yes no
  NEEDS_M365_SERVER="${NEEDS_M365_SERVER:-no}"; one_of NEEDS_M365_SERVER yes no
  ADOPT_EXISTING_APPS="${ADOPT_EXISTING_APPS:-no}"; one_of ADOPT_EXISTING_APPS yes no
  GROUP_ID="${GROUP_ID:-}"; GROUP_NAME="${GROUP_NAME:-$APP_NAME}"; GROUP_NICK="${GROUP_NICK:-$SITE}"
  printf '%s' "$GROUP_NICK" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || die "GROUP_NICK must be letters, digits, dot, dash or underscore (it becomes the group's mail nickname)."

  # Who may sign in, and how.
  ASSIGNMENT_MODE="${ASSIGNMENT_MODE:-group}"; one_of ASSIGNMENT_MODE group direct
  ROLE_SOURCE="${ROLE_SOURCE:-site}"; one_of ROLE_SOURCE site entra
  ADMIN_GROUP_ID="${ADMIN_GROUP_ID:-}"; ADMIN_GROUP_NAME="${ADMIN_GROUP_NAME:-$APP_NAME Administrators}"
  ALLOW_GUESTS="${ALLOW_GUESTS:-no}"; one_of ALLOW_GUESTS yes no
  # Without guests, the site's seeding refuses the whole people file over one
  # address off EMAIL_DOMAINS, so such a member is refused here, before the
  # Entra steps add them to the sign-in group.
  if [ "$ALLOW_GUESTS" != yes ]; then
    local m
    for m in ${MEMBERS//,/ }; do
      on_email_domains "$m" || die "A member's address ($m, in MEMBERS) is not on EMAIL_DOMAINS ($EMAIL_DOMAINS). With ALLOW_GUESTS=no the site refuses people outside the organisation's own domains: fix the address, or add its domain to EMAIL_DOMAINS, or set ALLOW_GUESTS=yes if outside people may sign in."
    done
  fi
  JOIN_MODE="${JOIN_MODE:-listed}"; one_of JOIN_MODE listed group
  # Q7 for a group picked by id: its members all go on the site's list now
  # (all), or only the administrators do (admins). Empty when no group is picked.
  LIST_GROUP_MEMBERS="${LIST_GROUP_MEMBERS:-}"
  [ -z "$LIST_GROUP_MEMBERS" ] || one_of LIST_GROUP_MEMBERS all admins

  # MFA is the site owner's call, asked per site; off unless they said yes.
  REQUIRE_MFA="${REQUIRE_MFA:-no}"
  case "$REQUIRE_MFA" in yes|no) ;; *) die "REQUIRE_MFA must be yes or no (yes only on the site owner's own yes)." ;; esac
  MFA_ANSWERED_BY="${MFA_ANSWERED_BY:-}"
  if [ "$mfa_in_config" = yes ] || [ "$REQUIRE_MFA" = yes ]; then
    [ -n "$MFA_ANSWERED_BY" ] || die "MFA_ANSWERED_BY is empty. REQUIRE_MFA=$REQUIRE_MFA is the site owner's answer: write who gave it and when, for example MFA_ANSWERED_BY='<name>, <YYYY-MM-DD>' with both filled in."
  fi
  [ -z "$MFA_ANSWERED_BY" ] || answered_by MFA_ANSWERED_BY

  # Session length: idle minutes and an absolute cap in hours. One answer
  # feeds the code and the Conditional Access sign-in frequency.
  SESSION_IDLE_MINUTES="${SESSION_IDLE_MINUTES:-60}"; whole_in SESSION_IDLE_MINUTES 15 480
  SESSION_MAX_HOURS="${SESSION_MAX_HOURS:-12}"; whole_in SESSION_MAX_HOURS 1 24
  [ "$SESSION_IDLE_MINUTES" -lt $((SESSION_MAX_HOURS * 60)) ] \
    || die "SESSION_IDLE_MINUTES ($SESSION_IDLE_MINUTES) must be shorter than SESSION_MAX_HOURS ($SESSION_MAX_HOURS hours), or the idle limit never applies."
  SESSION_ANSWERED_BY="${SESSION_ANSWERED_BY:-}"
  if [ "$session_in_config" = yes ]; then
    [ -n "$SESSION_ANSWERED_BY" ] || die "SESSION_ANSWERED_BY is empty. The session lengths in the config are the site owner's answer: write who gave it and when, for example SESSION_ANSWERED_BY='<name>, <YYYY-MM-DD>' with both filled in."
  fi
  [ -z "$SESSION_ANSWERED_BY" ] || answered_by SESSION_ANSWERED_BY

  # Previews and the test sign-in lane.
  PASSWORD_LANE="${PASSWORD_LANE:-local+preview}"; one_of PASSWORD_LANE local+preview local off
  PREVIEW_MODE="${PREVIEW_MODE:-test-lane}"; one_of PREVIEW_MODE test-lane stable-host none
  PREVIEW_HOST="${PREVIEW_HOST:-}"
  if [ "$PREVIEW_MODE" = stable-host ]; then
    [ -n "$PREVIEW_HOST" ] || die "PREVIEW_MODE is stable-host, so PREVIEW_HOST must name the one stable branch host (for example contoso-portal-git-preview-contoso.vercel.app)."
    is_host "$PREVIEW_HOST" || die "PREVIEW_HOST must be a bare host name (no https://, no path, no wildcard: Microsoft needs each address exactly)."
    [ "$PREVIEW_HOST" != "$DOMAIN" ] && [ "$PREVIEW_HOST" != "${VERCEL_HOST:-}" ] || die "PREVIEW_HOST must differ from DOMAIN and VERCEL_HOST (previews never share production's registration)."
  else
    [ -z "$PREVIEW_HOST" ] || die "PREVIEW_HOST is set but PREVIEW_MODE is $PREVIEW_MODE. Set PREVIEW_MODE=stable-host to give that host its own registration, or clear PREVIEW_HOST."
  fi
  if [ "$PREVIEW_MODE" = test-lane ] && [ "$PASSWORD_LANE" != local+preview ]; then
    die "PREVIEW_MODE=test-lane means previews sign in with the test lane, but PASSWORD_LANE is $PASSWORD_LANE. Set PASSWORD_LANE=local+preview, or PREVIEW_MODE=none (previews without sign-in) or stable-host."
  fi

  DB_SOURCE="${DB_SOURCE:-existing}"; one_of DB_SOURCE existing neon other
  # The record holds the tenant id and the owners' addresses: in the site's
  # repo only on a yes (a public site repo would publish them).
  RECORD_IN_REPO="${RECORD_IN_REPO:-no}"; one_of RECORD_IN_REPO yes no
  if [ "$RECORD_IN_REPO" = yes ] && [ -z "${SITE_DIR:-}" ]; then
    die "RECORD_IN_REPO=yes needs SITE_DIR (the site's folder) in the config."
  fi

  # Ids are spliced into queries, Graph URLs and JSON, so only a GUID passes.
  # Graph answers in lower case and compares ids case-sensitively, so they are
  # lower-cased here, once.
  local k v
  for k in TENANT_ID GROUP_ID ADMIN_GROUP_ID CA_POLICY_ID ADMIN_ROLE_ID; do
    [ -n "${!k:-}" ] || continue
    [ "$k" = CA_POLICY_ID ] && [ "${!k}" = OPEN ] && continue
    is_guid "${!k}" || die "$k must be a GUID (8-4-4-4-12 hex), not ${!k}."
    v="$(printf '%s' "${!k}" | tr '[:upper:]' '[:lower:]')"
    eval "$k=\$v"
  done
  [ -z "$GROUP_ID" ] || [ "$GROUP_ID" != "$ADMIN_GROUP_ID" ] || die "GROUP_ID and ADMIN_GROUP_ID are the same group. The administrators group is a second, smaller group."
  # The local database only: the production URL lives in its owner-only file.
  if [ -n "${LOCAL_DATABASE_URL:-}" ]; then
    is_local_db "$LOCAL_DATABASE_URL" \
      || die "LOCAL_DATABASE_URL $(db_refusal "$LOCAL_DATABASE_URL"). It must be a Postgres on this machine, for example postgres://localhost:5432/$SITE (never production)."
  fi
}

# in_git_repo <folder>: true when the folder is inside a git repository.
in_git_repo() { ( cd "$1" && git rev-parse --git-dir >/dev/null 2>&1 ); }
NOT_A_REPO_HINT="is not a git repository yet, so git cannot keep .env.local out of commits. Set git user.name and user.email, run git init there (and a first commit), then re-run."

# record_path: where the setup record lives. In the site's repo only when
# RECORD_IN_REPO=yes; otherwise beside the config, owner-only.
record_path() {
  if [ "$RECORD_IN_REPO" = yes ]; then printf '%s/docs/auth/entra-record.md' "$SITE_DIR"
  else printf '%s/entra-record.md' "$CONFIG_DIR"; fi
}

# graph_list <url> <query>: every row of a Graph list, page after page. Graph
# answers at most 999 items a page and az rest does not follow
# @odata.nextLink, so each page's link is read and followed here. Returns 1
# when a page or its next link cannot be read, when a next link points off
# Microsoft Graph, or past 200 pages (a partial list is never taken for the
# whole one). Callers capture the output and check the status: rows already
# printed before a failure are not the whole list.
graph_list() {
  local url="$1" q="$2" next pages=0
  while [ -n "$url" ]; do
    pages=$((pages+1))
    [ "$pages" -le 200 ] || { echo "More than 200 pages from Microsoft Graph; stopped reading." >&2; return 1; }
    az rest --method get --url "$url" --query "$q" -o tsv 2>/dev/null || return 1
    # A failed read of the link (a throttle, a network blip) is a failure,
    # never "no more pages".
    next="$(az rest --method get --url "$url" --query '"@odata.nextLink"' -o tsv 2>/dev/null)" || return 1
    case "$next" in
      ""|None) url="" ;;
      https://graph.microsoft.com/*) url="$next" ;;
      *) echo "Microsoft Graph gave a next page link off graph.microsoft.com; stopped reading." >&2; return 1 ;;
    esac
  done
}

# graph_count <url> <query>: how many rows a Graph list has, every page read; "?" when unreadable.
graph_count() {
  local rows
  rows="$(graph_list "$1" "$2")" || { printf '?'; return 0; }
  printf '%s\n' "$rows" | grep -c . || true
}

# picked_in_config <KEY>: the id came from the person's own config (a group
# they chose), not from a step. Those are never offered for deletion.
picked_in_config() { grep -Eq "^$1=['\"]?[0-9A-Fa-f]{8}-" "$CONFIG_FILE"; }

# p1_state: "yes" when an enabled licence carries an Entra ID P1 or P2 service
# plan (AAD_PREMIUM, AAD_PREMIUM_P2; also inside Microsoft 365 Business
# Premium, E3, E5), "no" when none does, "unknown" when the list is refused.
# A licence counts while Enabled or in its grace period (Warning), and a plan
# only once provisioned (Success; not PendingActivation just after a purchase).
p1_state() {
  local plans
  plans="$(az rest --method get --url "https://graph.microsoft.com/v1.0/subscribedSkus?\$select=capabilityStatus,servicePlans" \
    --query "value[?capabilityStatus=='Enabled' || capabilityStatus=='Warning'].servicePlans[] | [?provisioningStatus=='Success'].servicePlanName" -o tsv 2>/dev/null)" || { printf unknown; return 0; }
  if printf '%s\n' "$plans" | grep -Eq '^AAD_PREMIUM(_P2)?$'; then printf yes; else printf no; fi
}

# secdefaults_state: "yes" when security defaults are on, "no", or "unknown".
secdefaults_state() {
  local v
  v="$(az rest --method get --url "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy" --query isEnabled -o tsv 2>/dev/null)" || { printf unknown; return 0; }
  case "$v" in true|True) printf yes ;; false|False) printf no ;; *) printf unknown ;; esac
}

# ca_lookup: finds this site's Conditional Access policy in the tenant, by the
# recorded id first, else by its exact name "<APP_NAME>: require MFA". Sets
# CA_FOUND_ID, CA_FOUND_STATE and CA_FOUND_N (how many share the name).
# Returns 1 when the policy list cannot be read (no role).
ca_lookup() {
  local pols rec line name="$APP_NAME: require MFA"
  CA_FOUND_ID=""; CA_FOUND_STATE=""; CA_FOUND_N=0
  pols="$(az rest --method get --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" --query "value[].[id, displayName, state]" -o tsv 2>/dev/null)" || return 1
  rec="${CA_POLICY_ID:-}"; [ "$rec" = OPEN ] && rec=""
  line=""
  [ -n "$rec" ] && line="$(printf '%s\n' "$pols" | awk -F'\t' -v id="$rec" 'tolower($1)==id' | head -1)"
  if [ -n "$line" ]; then
    CA_FOUND_N=1
  else
    # Compared outside JMESPath, so a quote in the name cannot break a query.
    CA_FOUND_N="$(printf '%s\n' "$pols" | awk -F'\t' -v name="$name" '$2==name' | grep -c . || true)"
    line="$(printf '%s\n' "$pols" | awk -F'\t' -v name="$name" '$2==name' | head -1)"
  fi
  CA_FOUND_ID="$(printf '%s' "$line" | cut -f1 | tr '[:upper:]' '[:lower:]')"
  CA_FOUND_STATE="$(printf '%s' "$line" | cut -f3)"
  return 0
}

# is_local_db <url>: true for a Postgres on this machine only (localhost,
# 127.0.0.1 or [::1]), with an optional plain query such as ?sslmode=disable.
# A host= or hostaddr= query key (which some drivers read over the URL's host)
# is refused.
is_local_db() {
  printf '%s' "$1" | grep -Eq '^postgres(ql)?://([^@/]*@)?(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{2,5})?/[A-Za-z0-9_.-]+(\?[A-Za-z0-9=&_.-]*)?$' || return 1
  ! printf '%s' "$1" | grep -Eiq '[?&](host|hostaddr)='
}

# db_refusal <url>: why is_local_db refused it, in words (the value is never printed).
db_refusal() {
  local h
  [ -n "$1" ] || { printf 'is empty'; return 0; }
  if printf '%s' "$1" | grep -Eiq '[?&](host|hostaddr)='; then printf 'sets host= or hostaddr= in its query, which can point a driver at another machine'; return 0; fi
  h="$(printf '%s' "$1" | sed -e 's|^[A-Za-z]*://||' -e 's|^[^@/]*@||')"
  case "$h" in '['*) h="${h%%]*}]" ;; *) h="$(printf '%s' "$h" | sed -e 's|[/:?].*||')" ;; esac
  case "$h" in
    localhost|127.0.0.1|'[::1]') printf 'is on this machine but not in the plain form the check reads (postgres://localhost:5432/<name>, letters, digits, dot, dash or underscore in the name, plain query options only)' ;;
    *) printf '%s' "$h" | grep -Eq '^[A-Za-z0-9.-]+$' || h="(not shown)"
       printf 'names host %s, not this machine' "$h" ;;
  esac
}

# pin_tenant: the Azure CLI must be signed in to the tenant this site was set
# up in. TENANT_ID comes from the config (written after preflight) or from the
# state file (recorded by the first step). A write never goes to another tenant.
pin_tenant() {
  local current
  current="$(az account show --query tenantId -o tsv 2>/dev/null)" || die "The Azure CLI is not signed in. Run: az login --tenant ${TENANT_ID:-<organisation domain, e.g. contoso.com>} --allow-no-subscriptions"
  current="$(printf '%s' "$current" | tr '[:upper:]' '[:lower:]')"
  if [ -n "${TENANT_ID:-}" ]; then
    [ "$(printf '%s' "$TENANT_ID" | tr '[:upper:]' '[:lower:]')" = "$current" ] \
      || die "The Azure CLI is signed in to tenant $current, but this site belongs to $TENANT_ID. Sign in to the right tenant: az login --tenant $TENANT_ID --allow-no-subscriptions"
  elif [ "$MODE" = "run" ]; then
    die "TENANT_ID is not in $CONFIG_FILE. Write the tenant preflight showed (az account show --query tenantId) into it first, so no step can run against another tenant."
  fi
  TENANT_ID="$current"
}

# need_owners: two different people own every object (control M7). Addresses
# are compared ignoring case (OWNERS is de-duplicated by load_config); the run
# also compares their object ids, so two aliases of one person do not count.
need_owners() {
  local n
  n="$(list_count "$OWNERS")"
  [ "$n" -ge 2 ] && return 0
  if [ "$MODE" = "plan" ]; then
    note "WARNING: OWNERS names $n different owner(s); two different people are needed (control M7). A run refuses. When the signed-in admin is also the first administrator, ask for a second owner."
  else
    die "OWNERS must name two different people (control M7); it names $n. Add a second owner to the config."
  fi
}

# sed_repl <text>: the text made safe as a sed replacement with | as delimiter.
sed_repl() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }

# js_str <text>: the text made safe inside a double-quoted JS or JSON string.
js_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# fill <file>: the code placeholders, safely escaped for a quoted string.
# With no src folder the root is ".", written as ./lib and ../lib, not ././lib.
# The numbers and choices were checked by load_config, so they go in as they are.
fill() {
  local strip1='s|__SRC_ROOT__/||g' strip2='s|"\./__SRC_ROOT__"|"."|g'
  [ "${ROOT_SRC:-src}" = "." ] || { strip1='s|^$||'; strip2='s|^$||'; }
  sed -e "$strip1" -e "$strip2" \
      -e "s|__SITE_NAME__|$(sed_repl "$(js_str "$SITE_TITLE")")|g" \
      -e "s|__EMAIL_DOMAINS__|$(sed_repl "$(js_str "${EMAIL_DOMAINS:-}")")|g" \
      -e "s|__DOMAIN__|$(sed_repl "$DOMAIN")|g" \
      -e "s|__VERCEL_HOST__|$(sed_repl "${VERCEL_HOST:-}")|g" \
      -e "s|__SRC_ROOT__|$(sed_repl "${ROOT_SRC:-src}")|g" \
      -e "s|__SESSION_IDLE_MINUTES__|$SESSION_IDLE_MINUTES|g" \
      -e "s|__SESSION_MAX_HOURS__|$SESSION_MAX_HOURS|g" \
      -e "s|__ROLE_SOURCE__|$ROLE_SOURCE|g" \
      -e "s|__JOIN_MODE__|$JOIN_MODE|g" \
      -e "s|__ALLOW_GUESTS__|$ALLOW_GUESTS|g" \
      "$1"
}

# state_set KEY VALUE: records an object id (never a secret) for later steps.
state_set() {
  local key="$1" value="$2"
  eval "$key=\$value"
  [ "$MODE" = "run" ] || return 0
  local tmp
  tmp="$(mktemp)"
  grep -v "^${key}=" "$STATE_FILE" > "$tmp" || true
  printf '%s=%q\n' "$key" "$value" >> "$tmp"
  (umask 077; cat "$tmp" > "$STATE_FILE")
  rm -f "$tmp"
  eval "$key=\$value"
}

# show_cmd <command...>: one line a person can read and paste, arguments with
# spaces or shell characters in single quotes.
show_cmd() {
  local out="" a
  for a in "$@"; do
    case "$a" in
      *\'*) out="$out $(printf '%q' "$a")" ;;
      *[!A-Za-z0-9_./:=@%+,-]*) out="$out '$a'" ;;
      *) out="$out $a" ;;
    esac
  done
  printf '  $%s' "$out"
}

# run_cmd <description> -- <command...>: prints, then runs only in run mode.
run_cmd() {
  local desc="$1"; shift
  [ "$1" = "--" ] && shift
  show_cmd "$@"; printf '\n'
  printf '    why: %s\n' "$desc"
  if [ "$MODE" = "run" ]; then
    "$@"
  fi
}

# run_capture VAR <description> -- <command...>: like run_cmd, keeps stdout.
# Only for commands whose stdout is an id, never a secret.
run_capture() {
  local var="$1" desc="$2"; shift 2
  [ "$1" = "--" ] && shift
  show_cmd "$@"; printf '\n'
  printf '    why: %s\n' "$desc"
  if [ "$MODE" = "run" ]; then
    local out
    out="$("$@")"
    eval "$var=\$out"
  else
    eval "$var=\"<$var, known after this step runs>\""
  fi
}

# to_secret_file <path> -- <command...>: stdout of the command goes to an
# owner-only file and nowhere else. Prints only the byte count.
to_secret_file() {
  local path="$1"; shift
  [ "$1" = "--" ] && shift
  show_cmd "$@"; printf ' > %s   (owner-only file, never printed)\n' "$path"
  if [ "$MODE" = "run" ]; then
    # Held in a variable only long enough to drop the trailing newline, so the
    # value Vercel stores is exactly the secret. Never echoed.
    (umask 077; mkdir -p "$(dirname "$path")"; value="$("$@")"; printf '%s' "$value" > "$path")
    [ -s "$path" ] || die "Nothing was written to $path."
    printf '    written: %s (%s bytes)\n' "$path" "$(wc -c < "$path" | tr -d ' ')"
  fi
}

# upn_to_oid <upn>: read-only lookup of a user's object id.
upn_to_oid() {
  az ad user show --id "$1" --query id -o tsv
}

# new_guid: a random GUID, lower case (uuidgen, the kernel, or Node).
new_guid() {
  local g=""
  if command -v uuidgen >/dev/null 2>&1; then g="$(uuidgen)"
  elif [ -r /proc/sys/kernel/random/uuid ]; then g="$(cat /proc/sys/kernel/random/uuid)"
  elif command -v node >/dev/null 2>&1; then g="$(node -p 'require("crypto").randomUUID()')"; fi
  g="$(printf '%s' "$g" | tr '[:upper:]' '[:lower:]')"
  is_guid "$g" || die "Could not make a GUID (no uuidgen, /proc or node)."
  printf '%s' "$g"
}

# end_date <months>: ISO date that many months from now, UTC (macOS or GNU date).
end_date() {
  local months="$1"
  date -u -v+"${months}"m +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+${months} months" +%Y-%m-%dT%H:%M:%SZ
}

# check_env <env>: prod, dev, or preview only with PREVIEW_MODE=stable-host.
# Called before any $(...) that uses the env, because a die inside a subshell
# does not stop the script.
check_env() {
  case "$1" in
    prod|dev) ;;
    preview) [ "$PREVIEW_MODE" = stable-host ] || die "PREVIEW_MODE is $PREVIEW_MODE, so there is no preview registration (only stable-host has one)." ;;
    *) die "Environment must be prod, dev or preview, not $1." ;;
  esac
}

env_suffix() {
  case "$1" in
    prod) printf '' ;;
    dev) printf ' (local)' ;;
    preview) printf ' (preview)' ;;
    *) die "Environment must be prod, dev or preview, not $1." ;;
  esac
}

redirect_uris() {
  case "$1" in
    prod)
      printf 'https://%s/api/auth/callback/microsoft' "$DOMAIN"
      [ -n "${VERCEL_HOST:-}" ] && printf ' https://%s/api/auth/callback/microsoft' "$VERCEL_HOST"
      ;;
    dev) printf 'http://localhost:%s/api/auth/callback/microsoft' "$LOCAL_PORT" ;;
    preview) printf 'https://%s/api/auth/callback/microsoft' "$PREVIEW_HOST" ;;
  esac
  printf '\n'
}

envs_in_use() {
  printf 'prod dev'
  [ "$PREVIEW_MODE" = stable-host ] && printf ' preview'
  printf '\n'
}
