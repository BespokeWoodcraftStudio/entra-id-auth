#!/usr/bin/env bash
# Read only. What the tenant, the signed-in administrator, Vercel and the
# site's repo already say, so the interview asks only what is left.
#
#   preflight.sh [--site <slug>] [--dir <site folder>]
#                [--group <id>] [--admin-group <id>] [--domains <list>] [--admins <list>]
#                [--vercel-project <name> [--vercel-scope <team>]]
#
# --vercel-project (Q17's answer when the site folder is not linked yet) reads
# that project's own domains for Q4 and Q5, with --vercel-scope as its team.
#
# Prints what it found, then a block of suggested KEY=value lines for the
# interview (each is confirmed with the person, never written by this
# script). With --site it also checks whether the names in the site's config
# are already taken, and whether each carries this site's marker.
# --group (Q6) and --admin-group (Q11) check a group the person picked the
# way the group step will (tenant-setup.sh group_shape, check_picked_members):
# its type, its guests, its nested groups, and, with --admins (the first
# administrator and Q10's extras, comma list), whether each administrator is
# already in it. Each problem comes out as a "for Q6, say" or "for Q11, say"
# line, so it is said at the question, before the summary. --group also counts
# the members the way the setup puts them on the site's list, for Q7.
# --domains gives Q2's answer (comma list) when there is no --site config yet.
# With --site, a GROUP_ID or ADMIN_GROUP_ID picked in the config is checked
# the same way, the config's ALLOW_GUESTS (Q8) decides the count, as the group
# step does, and its administrators stand in for --admins.
# Nothing here writes to the tenant, Vercel, GitHub or any file.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
# Native Windows shells (Git Bash, MSYS, Cygwin) are not supported: the
# owner-only secret files mean nothing there. WSL reports Linux and is fine.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) die "This setup runs on macOS, Linux or Windows through WSL, not in Git Bash, MSYS or Cygwin. Install WSL (in an administrator PowerShell: wsl --install, then restart), open the Ubuntu terminal, install Claude Code there, and start the setup again." ;;
esac
need az

SITE_ARG=""; DIR_ARG=""; GROUP_ARG=""; ADMIN_GROUP_ARG=""; DOMAINS_ARG=""; ADMINS_ARG=""; VPROJECT_ARG=""; VSCOPE_ARG=""
usage() { die "Usage: preflight.sh [--site <slug>] [--dir <site folder>] [--group <group object id>] [--admin-group <group object id>] [--domains <comma list>] [--admins <comma list>] [--vercel-project <name> [--vercel-scope <team>]]"; }
# group_arg <flag> <value>: a group's object id, lower case.
group_arg() {
  local v; v="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  is_guid "$v" || die "$1 is a group's object id (a GUID), from the group's Overview page. From a name: az ad group list --display-name \"<name>\" --query \"[].{id:id, security:securityEnabled, mail:mailEnabled}\" -o tsv (read only; more than one hit: say how many, and ask which one, by id)."
  printf '%s' "$v"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --site) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || usage; SITE_ARG="$2"; shift 2 ;;
    --dir) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || usage; DIR_ARG="$2"; shift 2 ;;
    --vercel-project) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || usage
                      printf '%s' "$2" | grep -Eq '^[a-z0-9][a-z0-9._-]{0,99}$' || die "--vercel-project is a Vercel project name (lower case letters, digits, dot, dash, underscore)."
                      VPROJECT_ARG="$2"; shift 2 ;;
    --vercel-scope) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || usage
                    printf '%s' "$2" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$' || die "--vercel-scope is a Vercel team slug or id (letters, digits, dash, underscore)."
                    VSCOPE_ARG="$2"; shift 2 ;;
    --group) GROUP_ARG="$(group_arg --group "${2:-}")" || exit 1; shift 2 ;;
    --admin-group) ADMIN_GROUP_ARG="$(group_arg --admin-group "${2:-}")" || exit 1; shift 2 ;;
    --domains) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || usage
               DOMAINS_ARG="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"; shift 2 ;;
    --admins) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || usage
              ADMINS_ARG="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
              for a in ${ADMINS_ARG//,/ }; do is_address "$a" || die "--admins is a comma list of work addresses; \"$a\" is not one."; done
              shift 2 ;;
    *) usage ;;
  esac
done
[ -z "$GROUP_ARG" ] || [ "$GROUP_ARG" != "$ADMIN_GROUP_ARG" ] || die "--group and --admin-group are the same group. The administrators group is a second, smaller group."

SUGGEST=""
# suggest KEY VALUE [why]: one line for the interview's confirmation screen.
suggest() {
  local v="$2"
  case "$v" in
    *\'*) v="$(printf '%q' "$v")" ;;
    *[!A-Za-z0-9_./:@,+-]*|"") v="'$v'" ;;
  esac
  SUGGEST="$SUGGEST$1=$v${3:+   # $3}"$'\n'
}

head1 "Signed in"
# A list comes back on one tab-separated line; one per line is read the same.
ACCOUNT="$(az account show --query "[tenantId, user.name, user.type]" -o tsv 2>/dev/null | tr '\t' '\n')" \
  || die "The Azure CLI is not signed in. Run: az login --tenant <organisation domain, e.g. contoso.com> --allow-no-subscriptions"
TENANT="$(printf '%s\n' "$ACCOUNT" | sed -n 1p | tr '[:upper:]' '[:lower:]')"
note "tenant id: $TENANT"
note "signed in as: $(printf '%s\n' "$ACCOUNT" | sed -n 2p) ($(printf '%s\n' "$ACCOUNT" | sed -n 3p))"
suggest TENANT_ID "$TENANT" "the signed-in tenant (Q1)"

head1 "Tenant"
ORG_NAME="$(az rest --method get --url "https://graph.microsoft.com/v1.0/organization?\$select=displayName" --query "value[0].displayName" -o tsv 2>/dev/null)" \
  || die "Could not read the tenant from Microsoft Graph. Check the network and az login, then re-run."
DOMAINS="$(az rest --method get --url "https://graph.microsoft.com/v1.0/organization?\$select=verifiedDomains" --query "value[0].verifiedDomains[].name" -o tsv 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
DEFAULT_DOMAIN="$(az rest --method get --url "https://graph.microsoft.com/v1.0/organization?\$select=verifiedDomains" --query "value[0].verifiedDomains[?isDefault].name | [0]" -o tsv 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
note "name: $ORG_NAME"
note "default domain: ${DEFAULT_DOMAIN:-unknown}"
note "verified domains: $(printf '%s\n' "$DOMAINS" | grep -c . || true) ($(printf '%s\n' "$DOMAINS" | paste -sd' ' -))"
ORG_DOMAINS="$(printf '%s\n' "$DOMAINS" | grep -v '\.onmicrosoft\.com$' | paste -sd, - || true)"
DOMAINS_WHY="every verified domain except *.onmicrosoft.com (Q2)"
if [ -z "$ORG_DOMAINS" ]; then
  ORG_DOMAINS="$DEFAULT_DOMAIN"
  DOMAINS_WHY="found: ${DEFAULT_DOMAIN:-none} (the tenant has no other domain) (Q2)"
fi
[ -z "$ORG_DOMAINS" ] || suggest EMAIL_DOMAINS "$ORG_DOMAINS" "$DOMAINS_WHY"

head1 "Your directory roles against the least role each step needs"
if ROLES="$(az rest --method get --url "https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?\$select=displayName" --query "value[].displayName" -o tsv 2>/dev/null)"; then
  note "you hold: $(printf '%s\n' "$ROLES" | grep -c . || true) directory role(s)$( [ -n "$ROLES" ] && printf ': %s' "$(printf '%s\n' "$ROLES" | paste -sd, - | sed 's/,/, /g')")"
  note "roles through Privileged Identity Management show here only while activated"
else
  ROLES=""
  note "your roles could not be read; the lines below assume none"
fi
has_role() { printf '%s\n' "$ROLES" | grep -qxF "$1"; }
MISSING=0
# step_role <label> <least role> [<other role that also works>...]
step_role() {
  local label="$1" least="$2" r
  for r in "$@"; do
    [ "$r" = "$label" ] && continue
    if has_role "$r" || has_role "Global Administrator"; then
      note "$label: you can (least role: $least)"; return 0
    fi
  done
  note "$label: MISSING. Least role: $least. Ask someone who holds it, or have it assigned for the setup."
  MISSING=$((MISSING+1))
}
step_role "groups (group, admin-group)" "Groups Administrator" "User Administrator"
step_role "app registrations and secrets (app, secret, reader)" "Application Developer" "Cloud Application Administrator" "Application Administrator"
step_role "enterprise apps, assignment, consent (sp, consent, sync-assignments)" "Cloud Application Administrator" "Application Administrator"
step_role "Conditional Access (ca, ca-enable; only with MFA)" "Conditional Access Administrator" "Security Administrator"
step_role "Exchange scope (reader-exchange; only for server-side Microsoft 365)" "Exchange Administrator"
CREATE_APPS="$(az rest --method get --url "https://graph.microsoft.com/v1.0/policies/authorizationPolicy?\$select=defaultUserRolePermissions" --query "defaultUserRolePermissions.allowedToCreateApps" -o tsv 2>/dev/null || true)"
case "$CREATE_APPS" in
  true|True) note "any member may register apps in this tenant, so the app step needs no role (the creator becomes the app's owner)" ;;
  false|False) note "members may not register apps here: the app step needs Application Developer or higher" ;;
esac
note "steps you cannot run yourself: $MISSING (the plan names the role on each)"

head1 "Licences"
P1="$(p1_state)"
case "$P1" in
  yes) note "Entra ID P1 or P2: yes (an enabled licence carries AAD_PREMIUM). The group can be assigned to the app, and Conditional Access is possible."
       suggest ASSIGNMENT_MODE group "P1 found (Q6)" ;;
  no) note "Entra ID P1 or P2: NO. Microsoft assigns a group to an app only with P1, and Conditional Access needs P1."
      note "the choices (before any write): (a) get P1 (or Microsoft 365 Business Premium), or (b) the roster path: the group is still created, and each member is assigned to the app directly, kept in step by sync-assignments."
      suggest ASSIGNMENT_MODE direct "no P1 found (Q6); or get P1 and use group" ;;
  *) note "Entra ID P1 or P2: unknown (the licence list was refused). Ask the Microsoft 365 administrator before choosing ASSIGNMENT_MODE." ;;
esac

head1 "Security defaults and existing MFA"
SD="$(secdefaults_state)"
case "$SD" in
  yes) note "security defaults: ON. They already ask everyone for MFA when needed. No Conditional Access policy can be made while they are on, and this skill never turns them off." ;;
  no) note "security defaults: off" ;;
  *) note "security defaults: unknown (not readable with your roles)" ;;
esac
TENANT_MFA=""
if POLS="$(az rest --method get --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" \
    --query "value[?state=='enabled' && contains(conditions.users.includeUsers || \`[]\`, 'All') && contains(conditions.applications.includeApplications || \`[]\`, 'All') && (contains(grantControls.builtInControls || \`[]\`, 'mfa') || grantControls.authenticationStrength != null)].id" -o tsv 2>/dev/null)"; then
  TENANT_MFA="$(printf '%s\n' "$POLS" | grep -c . || true)"
  note "Conditional Access: readable. Enabled tenant-wide MFA policies (all users, all apps): $TENANT_MFA"
  note "the final check will read this site's policy itself"
else
  note "Conditional Access: not readable (no role). The final check reads MFA from the sign-in log instead and marks the policy UNVERIFIED."
fi
if [ "$P1" = no ]; then
  suggest REQUIRE_MFA no "no P1: no site policy possible (security defaults: $SD) (Q12)"
elif [ "$SD" = yes ]; then
  suggest REQUIRE_MFA no "security defaults are on: no site policy possible while they are (Q12)"
elif [ -n "$TENANT_MFA" ] && [ "$TENANT_MFA" -gt 0 ]; then
  suggest REQUIRE_MFA no "already covered by $TENANT_MFA tenant-wide MFA policy (Q12; the person may still say yes)"
else
  suggest REQUIRE_MFA yes "recommended by Microsoft; report-only for a week first; the site owner answers (Q12)"
fi

head1 "Microsoft Graph in this tenant"
note "Graph service principal id: $(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv 2>/dev/null || echo "not readable (the Azure CLI could not look it up)")"

SITE_FOLDER="${DIR_ARG:-$(pwd)}"
# The site address comes from the config only, never from the shell's environment.
unset DOMAIN
if [ -n "$SITE_ARG" ]; then
  load_config "$SITE_ARG"
  [ -z "$DIR_ARG" ] && [ -n "${SITE_DIR:-}" ] && SITE_FOLDER="$SITE_DIR"
  # The name lookups below run in whatever tenant the CLI is signed in to, so
  # they answer for the site's own tenant only.
  if [ -n "${TENANT_ID:-}" ]; then
    [ "$TENANT_ID" = "$TENANT" ] \
      || die "The Azure CLI is signed in to tenant $TENANT, but $SITE belongs to $TENANT_ID. Names were not checked. Sign in to the right tenant: az login --tenant $TENANT_ID --allow-no-subscriptions"
    note "tenant: $TENANT (matches TENANT_ID in the config)"
  else
    note "WARNING: TENANT_ID is not in the config yet; the names below are for tenant $TENANT. Write it before any step runs."
  fi
  note "MFA for this site: REQUIRE_MFA=$REQUIRE_MFA (a Conditional Access policy is made only on the site owner's yes)"
  head1 "Names already in the tenant (and whether each carries this site's marker)"
  for suffix in "" " (local)" " (preview)" " server reader"; do
    ids="$(az ad app list --display-name "$APP_NAME$suffix" --query "[].appId" -o tsv)" \
      || die "Could not list app registrations. Names were not checked."
    n="$(printf '%s\n' "$ids" | grep -c . || true)"
    ours=0
    for id in $ids; do
      notes="$(az ad app show --id "$id" --query notes -o tsv 2>/dev/null || true)"
      printf '%s' "$notes" | grep -qF "https://$DOMAIN" && printf '%s' "$notes" | grep -q "Set up by the entra-id-auth skill" && ours=$((ours+1))
    done
    note "app \"$APP_NAME$suffix\": $n found, $ours set up by this skill for https://$DOMAIN"
  done
  # group_names <label> <name> <marker>
  group_names() {
    local ids n ours=0 id desc
    ids="$(az ad group list --display-name "$2" --query "[].id" -o tsv 2>/dev/null || true)"
    n="$(printf '%s\n' "$ids" | grep -c . || true)"
    for id in $ids; do
      desc="$(az ad group show --group "$id" --query description -o tsv 2>/dev/null || true)"
      printf '%s' "$desc" | grep -qF "$3" && ours=$((ours+1))
    done
    note "$1 \"$2\": $n found, $ours carrying the marker $3"
  }
  if [ -n "$GROUP_ID" ]; then
    note "sign-in group picked by id $GROUP_ID: $(az ad group show --group "$GROUP_ID" --query displayName -o tsv 2>/dev/null || echo "NOT FOUND in this tenant")"
  else
    group_names "sign-in group" "$GROUP_NAME" "entra-id-auth:$DOMAIN"
  fi
  if [ "$ROLE_SOURCE" = entra ]; then
    if [ -n "$ADMIN_GROUP_ID" ]; then
      note "administrators group picked by id $ADMIN_GROUP_ID: $(az ad group show --group "$ADMIN_GROUP_ID" --query displayName -o tsv 2>/dev/null || echo "NOT FOUND in this tenant")"
    else
      group_names "administrators group" "$ADMIN_GROUP_NAME" "entra-id-auth:$DOMAIN:administrators"
    fi
  fi
  if ca_lookup; then
    note "Conditional Access policy \"$APP_NAME: require MFA\": $CA_FOUND_N found"
  else
    note "Conditional Access policy \"$APP_NAME: require MFA\": the policy list is not readable"
  fi
fi

# A picked group, read the way the group step reads it later (tenant-setup.sh
# group_shape and check_picked_members), so each problem is said at its
# question (Q6 or Q11), before the summary, and the plan only re-confirms.
# The sign-in group (Q6) is also counted the way resolve_roster puts its
# members on the site's list, for Q7: enabled user accounts only; accounts off
# the email domains only when guests are allowed. Guests are counted the way
# the group step checks them (every guest, enabled or not): with guests not
# allowed, a group holding any guest is refused. Nested groups' members and
# devices are never read.
COUNT_GROUP="${GROUP_ARG:-}"
[ -n "$COUNT_GROUP" ] || { [ -n "$SITE_ARG" ] && [ -n "${GROUP_ID:-}" ] && picked_in_config GROUP_ID && COUNT_GROUP="$GROUP_ID"; }
CHECK_ADMIN_GROUP="${ADMIN_GROUP_ARG:-}"
[ -n "$CHECK_ADMIN_GROUP" ] || { [ -n "$SITE_ARG" ] && [ "${ROLE_SOURCE:-site}" = entra ] && [ -n "${ADMIN_GROUP_ID:-}" ] && picked_in_config ADMIN_GROUP_ID && CHECK_ADMIN_GROUP="$ADMIN_GROUP_ID"; }
ADMINS="$ADMINS_ARG"
# shellcheck disable=SC2086  # the comma list is split on purpose
[ -n "$ADMINS" ] || [ -z "$SITE_ARG" ] || ADMINS="$(printf '%s\n' ${FIRST_ADMIN:-} ${EXTRA_ADMINS//,/ } | awk 'NF && !seen[$0]++' | paste -sd, - || true)"
if [ -n "$COUNT_GROUP$CHECK_ADMIN_GROUP" ]; then
  if [ -n "$DOMAINS_ARG" ]; then EMAIL_DOMAINS="$DOMAINS_ARG"
  elif [ -z "$SITE_ARG" ]; then EMAIL_DOMAINS="$ORG_DOMAINS"; DOMAINS_GUESSED=yes; fi
fi
# enabled_people <n>: "1 enabled person", "2 enabled people".
enabled_people() { if [ "$1" = 1 ]; then printf '1 enabled person'; else printf '%s enabled people' "$1"; fi; }

# picked_group <id> <Q6|Q11>: the checks above for one group; the counts it
# leaves (GNAME, GN, GG, GGE, GO, GD) are the Q7 ones when <Q> is Q6.
picked_group() {
  local id="$1" q="$2" shape sec mail types shape_bad="" shape_unread="" a oid v ain=0 aout=0 aunread=0 anf=0
  GNAME="$(az ad group show --group "$id" --query displayName -o tsv 2>/dev/null || true)"
  if [ -z "$GNAME" ]; then note "group $id: NOT FOUND in this tenant"; return 1; fi
  [ "$q" != Q6 ] || [ "${DOMAINS_GUESSED:-}" != yes ] || note "counted against every verified domain except *.onmicrosoft.com; if Q2's answer is narrower, rerun with --domains <Q2's list>"
  # Its type: a static security group, not mail-enabled, not Microsoft 365, not dynamic.
  shape="$(az ad group show --group "$id" --query "[securityEnabled, mailEnabled, length(groupTypes || \`[]\`)]" -o tsv 2>/dev/null | tr '\n' '\t' || true)"
  sec="$(printf '%s' "$shape" | cut -f1)"; mail="$(printf '%s' "$shape" | cut -f2)"; types="$(printf '%s' "$shape" | cut -f3)"
  if [ -z "$sec$mail$types" ]; then
    note "group \"$GNAME\": its type could not be read"
    shape_bad=yes; shape_unread=" (or it could not be checked)"
  else
    note "group \"$GNAME\": security-enabled $sec; mail-enabled $mail; Microsoft 365 or dynamic types: $types"
    case "$sec" in true|True) ;; *) shape_bad=yes ;; esac
    case "$mail" in false|False) ;; *) shape_bad=yes ;; esac
    [ "$types" = 0 ] || shape_bad=yes
  fi
  [ -z "$shape_bad" ] || note "for $q, say: \"This group is a Microsoft 365, mail-enabled or dynamic group$shape_unread. It cannot be used: pick a security group, or let the setup make a new group.\""
  GN=0; GG=0; GGE=0; GO=0; GD=0; GNEST=0
  if ! GROWS="$(graph_list "https://graph.microsoft.com/v1.0/groups/$id/members/microsoft.graph.user?\$select=id,accountEnabled,userType,mail,userPrincipalName&\$top=999" \
      "value[].[accountEnabled, userType, mail || userPrincipalName]")"; then
    note "group \"$GNAME\": its members could not be read in full (a role or a network problem); no count is given, so none is guessed. Count again before going on."
    GROWS_READ=no
  else
    GROWS_READ=yes
    while IFS=$'\t' read -r g_en g_type g_addr; do
      [ -n "$g_en$g_type$g_addr" ] || continue
      if [ "$g_type" = Guest ]; then
        GG=$((GG+1)); case "$g_en" in true|True) GGE=$((GGE+1)) ;; esac; continue
      fi
      case "$g_en" in true|True) ;; *) GD=$((GD+1)); continue ;; esac
      if [ -n "$EMAIL_DOMAINS" ] && ! on_email_domains "$(printf '%s' "$g_addr" | tr '[:upper:]' '[:lower:]')"; then GO=$((GO+1))
      else GN=$((GN+1)); fi
    done <<< "$GROWS"
    note "guests in the group (enabled or not): $GG"
    # With --site and ALLOW_GUESTS=yes the group step takes guests, so nothing is said.
    if [ "$GG" -gt 0 ] && { [ -z "$SITE_ARG" ] || [ "${ALLOW_GUESTS:-no}" != yes ]; }; then
      if [ "$q" = Q6 ]; then
        note "for Q6, say: \"This group holds $GG guest(s). With guests not allowed (recommended), it cannot be used: allow guests (Q8 yes, asked now), remove them from the group, or let the setup make a new group.\""
      else
        note "for $q (only when Q8 is no), say: \"This group holds $GG guest(s). With guests not allowed (recommended), it cannot be used: allow guests (Q8 yes), remove them from the group, or let the setup make a new group.\""
      fi
    fi
  fi
  GNEST="$(graph_count "https://graph.microsoft.com/v1.0/groups/$id/members/microsoft.graph.group?\$select=id&\$top=999" "value[].id")"
  note "nested groups: $GNEST (their members are not read)"
  [ "$GNEST" = 0 ] || note "for $q, say: \"This group holds other groups inside it$( [ "$GNEST" = "?" ] && printf ' (or they could not be checked)'). It cannot be used as it is: add those people directly, or let the setup make a new group.\""
  # The administrators must already be in it: a picked group is never changed.
  if [ -n "$ADMINS" ]; then
    for a in ${ADMINS//,/ }; do
      oid="$(az ad user show --id "$a" --query id -o tsv 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
      if ! is_guid "$oid"; then anf=$((anf+1)); continue; fi
      v="$(az ad group member check --group "$id" --member-id "$oid" --query value -o tsv 2>/dev/null || true)"
      case "$v" in true|True) ain=$((ain+1)) ;; false|False) aout=$((aout+1)) ;; *) aunread=$((aunread+1)) ;; esac
    done
    note "administrators checked: $((ain+aout+aunread+anf)); in this group: $ain; not in it: $aout; could not be checked: $aunread; address not found in this tenant: $anf"
    local k=$((aout+aunread)) who
    if [ "$k" -eq 1 ]; then who="1 administrator is"; else who="$k administrators are"; fi
    [ "$k" -eq 0 ] || note "for $q, say: \"$who not in this group yet$( [ "$aunread" -gt 0 ] && printf ' (or could not be checked)'): add them to it yourself, or let the setup make a new group.\""
    [ "$anf" -eq 0 ] || note "tell the person: $anf administrator address(es) were not found in this tenant; check the spelling (the first administrator, Q10) before going on"
  else
    note "the administrators were not given (--admins), so whether they are in this group was not checked"
  fi
}

if [ -n "$COUNT_GROUP" ]; then
  head1 "The picked sign-in group (Q6), and its members as the setup would list them (Q7)"
  if picked_group "$COUNT_GROUP" Q6 && [ "$GROWS_READ" = yes ]; then
    note "group \"$GNAME\", for the site's list: $(enabled_people "$GN") on the email domains (${EMAIL_DOMAINS:-none known})"
    note "left off unless guests are allowed (Q8): $GO enabled member(s) off those domains"
    note "never listed: $GD disabled account(s); $GNEST nested group(s) (add their people one by one if they should sign in)"
    # among: the guests and off-domain members inside a count, each only when above 0.
    among=""
    [ "$GGE" -gt 0 ] && among="$GGE guest(s)"
    [ "$GO" -gt 0 ] && among="${among:+$among and }$GO off your domains"
    # interview.md Q7 words the question; these are its counts. With --site
    # the config's ALLOW_GUESTS (Q8) is known, so the count is the one the
    # group step lists (the recount after the summary's yes).
    if [ -n "$SITE_ARG" ] && [ "${ALLOW_GUESTS:-no}" = yes ]; then
      note "for Q7 (ALLOW_GUESTS=yes in the config), the count: \"$(enabled_people $((GN+GO+GGE))) will go on the list${among:+, $among among them}\""
    elif [ "$GG" -gt 0 ]; then
      note "for Q7 (only if guests are allowed, Q8 yes), the count: \"$(enabled_people $((GN+GO+GGE))) will go on the list${among:+, $among among them}\""
    else
      note "for Q7, the count: \"$(enabled_people "$GN") will go on the list$( [ "$GO" -gt 0 ] && printf ' (%s off your domains are left off unless Q8 is yes)' "$GO")\""
    fi
  fi
fi
if [ -n "$CHECK_ADMIN_GROUP" ]; then
  head1 "The picked administrators group (Q11)"
  picked_group "$CHECK_ADMIN_GROUP" Q11 || true
fi

head1 "The site's repo"
if command -v gh >/dev/null 2>&1 && [ -d "$SITE_FOLDER" ]; then
  VIS="$( (cd "$SITE_FOLDER" && gh repo view --json visibility -q .visibility) 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"
  case "$VIS" in
    PRIVATE|INTERNAL) note "visibility: $VIS"; suggest RECORD_IN_REPO yes "the site's repo is $VIS (Q19)" ;;
    PUBLIC) note "visibility: PUBLIC. The setup record (tenant id, owners' addresses) stays out of it."; suggest RECORD_IN_REPO no "the site's repo is public (Q19)" ;;
    *) note "visibility: unknown (gh is not signed in, or the folder has no GitHub remote)"; suggest RECORD_IN_REPO no "visibility unknown (Q19)" ;;
  esac
else
  note "visibility: unknown (gh is not installed)"
  suggest RECORD_IN_REPO no "visibility unknown (Q19)"
fi

head1 "Vercel"
if command -v vercel >/dev/null 2>&1; then
  VSCOPE=(); P_NAME=""; P_ID=""; P_ORG=""; P_READ=""; P_SERVES=""; P_MISSING=""
  PJ="$SITE_FOLDER/.vercel/project.json"
  if [ -f "$PJ" ] && command -v node >/dev/null 2>&1; then
    LINK="$(node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write([j.projectName||"",j.projectId||"",j.orgId||""].join("\t"))}catch{}' "$PJ" 2>/dev/null || true)"
    P_NAME="$(printf '%s' "$LINK" | cut -f1)"; P_ID="$(printf '%s' "$LINK" | cut -f2)"; P_ORG="$(printf '%s' "$LINK" | cut -f3)"
    note "linked project: ${P_NAME:-name not recorded} (id $(printf '%s' "$LINK" | cut -f2)); team: ${P_ORG:-unknown}"
    [ -z "$P_NAME" ] || suggest VERCEL_PROJECT "$P_NAME" "the linked project (Q17)"
    case "$P_ORG" in team_*) VSCOPE=(--scope "$P_ORG"); suggest VERCEL_SCOPE "$P_ORG" "the linked project's team (Q17)" ;; esac
  elif [ -n "$VPROJECT_ARG" ]; then
    # Not linked, but Q17 named the project: its domains are read by name.
    P_NAME="$VPROJECT_ARG"; P_ID="$VPROJECT_ARG"
    note "linked project: not linked (no .vercel/project.json in $SITE_FOLDER); reading the project named for Q17: $P_NAME${VSCOPE_ARG:+ (team $VSCOPE_ARG)}"
    [ -z "$VSCOPE_ARG" ] || VSCOPE=(--scope "$VSCOPE_ARG")
  else
    note "linked project: not linked (no .vercel/project.json in $SITE_FOLDER)"
  fi
  if WHO="$(vercel whoami 2>/dev/null)"; then
    note "signed in as: $(printf '%s\n' "$WHO" | tail -1)"
    note "teams:"; vercel teams ls 2>/dev/null | sed -n '1,15p' | sed 's/^/      /' || true
    if [ -n "$P_ID" ] && command -v node >/dev/null 2>&1; then
      # The linked project's own domains (a read-only GET). `vercel domains ls`
      # lists every domain in the team, attached to this project or not, so
      # only this read decides Q4's found address and Q5's "already there".
      # One line per domain: name, then serves | unverified | redirect | branch | custom environment.
      # The team comes from --scope (the linked orgId), as for every read here.
      P_DOMS="$(vercel api "/v9/projects/$P_ID/domains" ${VSCOPE[@]+"${VSCOPE[@]}"} 2>/dev/null \
        | node -e 'let t="";process.stdin.on("data",c=>t+=c).on("end",()=>{try{const j=JSON.parse(t);const a=Array.isArray(j)?j:j.domains;if(!Array.isArray(a)||(j.pagination&&j.pagination.next!=null))process.exit(1);for(const d of a){if(!d||typeof d.name!=="string")continue;process.stdout.write(d.name.toLowerCase()+"\t"+(d.redirect?"redirect":d.gitBranch?"branch":d.customEnvironmentId?"custom environment":d.verified===false?"unverified":"serves")+"\n")}}catch{process.exit(1)}})' 2>/dev/null)" && P_READ=yes || P_READ=""
    fi
    if [ -n "$P_READ" ]; then
      P_SERVES="$(printf '%s\n' "$P_DOMS" | awk -F'\t' '$2=="serves"{print $1}')"
      # A wildcard (*.example.com) is never the address the site signs in on.
      P_CUSTOM="$(printf '%s\n' "$P_SERVES" | grep -v '\.vercel\.app$' | grep -v '^\*' | grep . || true)"
      P_UNVER="$(printf '%s\n' "$P_DOMS" | awk -F'\t' '$2=="unverified"{print $1}' | grep -v '^\*' | grep . || true)"
      P_OTHER="$(printf '%s\n' "$P_DOMS" | awk -F'\t' '$2!="serves" && $1!=""{print $1" ("$2")"}' | paste -sd' ' -)"
      P_WILD="$(printf '%s\n' "$P_SERVES" | grep -c '^\*' || true)"
      note "domains on this project (production): $(printf '%s\n' "$P_SERVES" | grep . | paste -sd' ' - | grep . || echo none)${P_OTHER:+; also: $P_OTHER}"
      NCUSTOM="$(printf '%s\n' "$P_CUSTOM" | grep -c . || true)"
      if [ -z "${DOMAIN:-}" ]; then
        if [ "$NCUSTOM" -eq 1 ]; then suggest DOMAIN "$P_CUSTOM" "the one custom domain on this project (Q4; Q5: already on the project)"
        elif [ "$NCUSTOM" -eq 0 ]; then
          note "for Q4: this project has no custom domain that serves yet$( [ -n "$P_UNVER" ] && printf ' (attached, DNS not verified yet: %s)' "$(printf '%s\n' "$P_UNVER" | paste -sd' ' -)")$( [ "$P_WILD" -gt 0 ] && printf ' (a wildcard domain is on it: ask for the exact host the site signs in on)'); ask for the address (Q5 adds it), or use its .vercel.app host"
        else note "for Q4: this project has $NCUSTOM custom domains; ask which one the site signs in on"; fi
      fi
      DOMAIN_L="$(printf '%s' "${DOMAIN:-}" | tr '[:upper:]' '[:lower:]')"; DOMAIN_L="${DOMAIN_L%.}"
      if [ -n "$DOMAIN_L" ]; then
        if printf '%s\n' "$P_SERVES" | grep -qxF "$DOMAIN_L"; then note "for Q5: $DOMAIN is already on the project (skip adding it)"
        elif printf '%s\n' "$P_UNVER" | grep -qxF "$DOMAIN_L"; then note "for Q5: $DOMAIN is on the project but Vercel has not verified its DNS: tell the person it is attached already, so Q5 is no, and whoever manages the site's DNS must fix that before sign-in works"
        elif K="$(printf '%s\n' "$P_DOMS" | awk -F'\t' -v d="$DOMAIN_L" '$1==d{print $2; exit}')" && [ -n "$K" ]; then note "for Q5: $DOMAIN is on the project as a $K domain, not as a production address: tell the person, and let them choose Q5 (adding it as a production address) or another address at Q4"
        else note "for Q5: $DOMAIN is not on this project yet: ask Q5 (step 5.2 adds it)"; fi
      fi
    elif [ -z "$P_ID" ]; then
      note "projects you can see (the choices for Q17):"; vercel project ls ${VSCOPE[@]+"${VSCOPE[@]}"} 2>/dev/null | sed -n '1,20p' | sed 's/^/      /' || true
      note "for Q4 and Q5: this folder is not linked to a Vercel project, so the project's domains were not read. Ask Q17 first, then run this again with --vercel-project <name> (and --vercel-scope <team>) to read them; until then ask Q4 and Q5, do not skip them"
    else
      # A name given with --vercel-project that the team does not list is a typo or a project not made yet, not an old CLI.
      if [ -n "$VPROJECT_ARG" ] && ! vercel project ls ${VSCOPE[@]+"${VSCOPE[@]}"} 2>/dev/null | awk -v p="$VPROJECT_ARG" '$1==p{f=1} END{exit !f}'; then
        P_MISSING=yes
        note "for Q17: no project named $VPROJECT_ARG${VSCOPE_ARG:+ in team $VSCOPE_ARG} was found: check the name, or create the project in Vercel first, then run this again. Ask Q4 and Q5; do not skip them."
      else
        note "domains on this project: could not be read in full (this Vercel CLI may be too old for 'vercel api', or the project has more domains than one page holds). Ask Q4 and Q5; do not skip them."
      fi
    fi
    note "domains in the team (not all on this project):"; vercel domains ls ${VSCOPE[@]+"${VSCOPE[@]}"} 2>/dev/null | sed -n '1,20p' | sed 's/^/      /' || true
    if [ -f "$PJ" ]; then
      # Names only: the first word of each variable line, never a value.
      NAMES="$(vercel env ls ${VSCOPE[@]+"${VSCOPE[@]}"} --cwd "$SITE_FOLDER" 2>/dev/null | awk '$1 ~ /^[A-Z][A-Z0-9_]*$/ {print $1}' | sort -u || true)"
      note "environment variable names on the project: $(printf '%s\n' "$NAMES" | grep -c . || true)$( [ -n "$NAMES" ] && printf ' (%s)' "$(printf '%s\n' "$NAMES" | paste -sd' ' -)")"
      if printf '%s\n' "$NAMES" | grep -Eqx 'DATABASE_URL|POSTGRES_URL'; then
        suggest DB_SOURCE existing "a database variable is already on the project (Q18)"
      else
        suggest DB_SOURCE neon "no database variable on the project yet (Q18)"
      fi
    fi
  else
    note "the Vercel CLI is not signed in. The person runs: vercel login"
  fi
  if [ -n "$P_NAME" ] && [ -z "$P_MISSING" ]; then
    # The production .vercel.app host: read from the project when it could be,
    # else the usual <project>.vercel.app, marked as a guess. With no custom
    # domain, DOMAIN is that host itself and VERCEL_HOST stays empty (a
    # redirect to itself would loop).
    P_VH="$(printf '%s\n' "$P_SERVES" | grep -xF "$P_NAME.vercel.app" || printf '%s\n' "$P_SERVES" | grep '\.vercel\.app$' | head -1 || true)"
    if [ -n "$P_VH" ]; then VH_WHY="the project's production .vercel.app host, read from the project"
    else P_VH="$P_NAME.vercel.app"; VH_WHY="a guess: the usual production .vercel.app host; confirm in the project's Domains"; fi
    case "${DOMAIN:-}" in
      *.vercel.app) suggest VERCEL_HOST "" "DOMAIN is the .vercel.app host itself: no canonical-host redirect (Q4)" ;;
      "") suggest VERCEL_HOST "$P_VH" "$VH_WHY, only when DOMAIN is a custom domain; empty when DOMAIN is this host (Q4)" ;;
      *) suggest VERCEL_HOST "$P_VH" "$VH_WHY (Q4)" ;;
    esac
  fi
else
  note "the Vercel CLI is not installed ($VERCEL_FIX); the Vercel steps are planned but not run"
fi

head1 "Local Postgres (the local proof creates, migrates and drops a database on this machine)"
# Read only: pg_isready and one SELECT on the server's own postgres database.
PG_URL="${LOCAL_DATABASE_URL:-postgres://localhost:5432/postgres}"
PG_ADMIN_URL="$(printf '%s' "$PG_URL" | sed -E 's|/[A-Za-z0-9_.-]+(\?[^/]*)?$|/postgres\1|')"
PG_MISSING=""
for b in pg_isready psql createdb dropdb; do command -v "$b" >/dev/null 2>&1 || PG_MISSING="$PG_MISSING $b"; done
if [ -n "$PG_MISSING" ]; then
  note "MISSING on PATH:$PG_MISSING. Step 6 needs a Postgres 15 or later server running on this machine, with its client tools (createdb, dropdb, psql). Install and start it with the system's package manager (for example Homebrew postgresql@17, or the distro's postgresql package), then re-run."
elif ! pg_isready -q -d "$PG_ADMIN_URL" >/dev/null 2>&1; then
  note "no Postgres server answers at the local address${LOCAL_DATABASE_URL:+ in LOCAL_DATABASE_URL} (default localhost:5432). Start it (or install one, Postgres 15 or later), then re-run."
else
  PG_CAN="$(psql "$PG_ADMIN_URL" -Atqc "select current_user || ' ' || (rolcreatedb or rolsuper)::text from pg_roles where rolname = current_user" 2>/dev/null || true)"
  case "$PG_CAN" in
    *" true") note "Postgres answers; role ${PG_CAN% *} may create databases (step 6 can run)" ;;
    *" false") note "Postgres answers, but role ${PG_CAN% *} may not create databases. Grant CREATEDB to it, or put a role that may into LOCAL_DATABASE_URL (postgres://<user>:<password>@localhost:5432/<slug>)." ;;
    *) note "Postgres answers but refused this login. The default connects as your OS user with no password; a server that has no such role (the usual Linux package makes only postgres) needs user:password@ in LOCAL_DATABASE_URL." ;;
  esac
fi

head1 "Suggested answers for the interview (confirm each; this script writes nothing)"
printf '%s' "$SUGGEST" | sed 's/^/  /'
