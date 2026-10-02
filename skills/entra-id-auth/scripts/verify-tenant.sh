#!/usr/bin/env bash
# Read only. The Microsoft 365 half of the final check: every tenant control
# in references/controls.md, run against this site's own objects.
#
#   verify-tenant.sh --site <slug>
#
# Prints a Markdown table: control, environment, PASS / PASS (decided) /
# FAIL / WARN / UNVERIFIED / N/A, evidence. Counts people; never lists them.
# N/A (the control does not apply to this site, with the reason) and
# PASS (decided) (a choice the config records) are not failures.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
need az
[ "${1:-}" = "--site" ] || die "Usage: verify-tenant.sh --site <slug>"
load_config "${2:-}"
# shellcheck disable=SC2034  # MODE is read by pin_tenant in lib.sh
MODE=plan
pin_tenant

MARKER="entra-id-auth:$DOMAIN"
FAILS=0
row() { printf '| %s | %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" "$5"; [ "$4" = "FAIL" ] && FAILS=$((FAILS+1)); return 0; }
# pf <control> <name> <where> <PASS evidence> <FAIL evidence> <test...>: PASS
# when the test holds, else FAIL.
pf() {
  local c="$1" n="$2" w="$3" ok="$4" bad="$5"; shift 5
  if "$@"; then row "$c" "$n" "$w" PASS "$ok"; else row "$c" "$n" "$w" FAIL "$bad"; fi
}
g() { az rest --method get --url "$1" --query "$2" -o tsv 2>/dev/null || true; }
# azr: a read that may fail (an object deleted from the tenant) gives an empty
# answer, which FAILs its row, instead of stopping the check mid-table.
azr() { az "$@" 2>/dev/null || true; }
# more <url>: "yes" when Graph has a further page past this one ($top=999).
more() { local n; n="$(g "$1" '"@odata.nextLink"')"; if [ -n "$n" ] && [ "$n" != "None" ]; then echo yes; else echo no; fi; }
nn() { if [ "$1" = "None" ]; then printf ""; else printf "%s" "$1"; fi; }
ge() { [ "${1:-0}" -ge "$2" ] 2>/dev/null; }
count() { printf '%s\n' "$1" | grep -c . || true; }
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# users_of <group id>: the group's user members (enabled; guests only when
# allowed), lower case, every page read: the roster direct assignments must
# equal. Returns 1 when the list cannot be read in full (the rows printed
# before a failed page are not the whole list).
users_of() {
  local q="value[?accountEnabled]" rows
  [ "$ALLOW_GUESTS" = yes ] || q="value[?accountEnabled && userType!='Guest']"
  rows="$(graph_list "https://graph.microsoft.com/v1.0/groups/$1/members/microsoft.graph.user?\$select=id,accountEnabled,userType&\$top=999" "$q.id")" || return 1
  printf '%s\n' "$rows" | tr '[:upper:]' '[:lower:]' | grep . | sort -u || true
}
# ROSTER_OK / ADMIN_OK: "no" when a group's members could not be read in full,
# so the rows compared against them are UNVERIFIED, never a false FAIL.
ROSTER_IDS=""; ADMIN_IDS=""; ROSTER_OK=yes; ADMIN_OK=yes
if [ "$ASSIGNMENT_MODE" = direct ] && is_guid "$GROUP_ID"; then
  ROSTER_IDS="$(users_of "$GROUP_ID")" || { ROSTER_IDS=""; ROSTER_OK=no; }
  if [ "$ROLE_SOURCE" = entra ] && is_guid "$ADMIN_GROUP_ID"; then
    # The setup gives the Administrator role only to administrators who are
    # also in the sign-in group (the role is itself a way in).
    if [ "$ROSTER_OK" = yes ] && ag_all="$(users_of "$ADMIN_GROUP_ID")"; then
      ADMIN_IDS="$(printf '%s\n' "$ag_all" | grep . | grep -xF -f <(printf '%s\n' "$ROSTER_IDS" | grep . || printf 'none\n') || true)"
    else ADMIN_OK=no; fi
  fi
fi

echo "| # | Control | Where | Result | Evidence |"
echo "|---|---|---|---|---|"

for e in $(envs_in_use); do
  a="APP_ID_$e"; s="SP_ID_$e"; app="${!a:-}"; sp="${!s:-}"
  if [ -z "$app" ] || [ -z "$sp" ]; then row "-" "objects exist" "$e" FAIL "no app or enterprise app id in the state file"; continue; fi
  obj="$(azr ad app show --id "$app" --query id -o tsv)"
  if [ -z "$obj" ]; then row "-" "App registration found" "$e" FAIL "app $app is not in the tenant (deleted, or the state file is stale)"; continue; fi
  if [ -z "$(azr ad sp show --id "$sp" --query id -o tsv)" ]; then row "-" "Enterprise app found" "$e" FAIL "enterprise app $sp is not in the tenant (deleted, or the state file is stale)"; continue; fi
  aud="$(azr ad app show --id "$app" --query signInAudience -o tsv)"
  pf M1 "Single tenant" "$e" "$aud" "$aud" [ "$aud" = "AzureADMyOrg" ]

  imp="$(azr ad app show --id "$app" --query "[web.implicitGrantSettings.enableIdTokenIssuance, web.implicitGrantSettings.enableAccessTokenIssuance, length(spa.redirectUris || \`[]\`), length(publicClient.redirectUris || \`[]\`), isFallbackPublicClient || \`false\`]" -o tsv | tr '\n\t' '  ')"
  case "$imp" in
    "false false 0 0 false "*) row M2 "Code flow only, confidential client" "$e" PASS "implicit off, no SPA or public redirects" ;;
    *) row M2 "Code flow only, confidential client" "$e" FAIL "$imp" ;;
  esac

  want="$(redirect_uris "$e" | tr ' ' '\n' | sort | tr '\n' ' ')"
  have="$(azr ad app show --id "$app" --query "web.redirectUris" -o tsv | sort | tr '\n' ' ')"
  pf M3 "Exact redirect URIs for this environment" "$e" "$have" "have: $have; want: $want" [ "$want" = "$have" ]
  if [ "$e" != "dev" ] && printf '%s' "$have" | grep -q 'http://'; then row M3 "No plain-http redirect" "$e" FAIL "$have"; fi

  rar="$(azr ad sp show --id "$sp" --query appRoleAssignmentRequired -o tsv)"
  pf M4 "Assignment required" "$e" "true" "$rar" [ "$rar" = "true" ]

  ara_url="https://graph.microsoft.com/v1.0/servicePrincipals/$sp/appRoleAssignedTo?\$top=999"
  rows="$(g "$ara_url" "value[].[principalType, principalId, appRoleId]" | awk -F'\t' '{print $1 "\t" tolower($2) "\t" tolower($3)}')"
  types="$(printf '%s\n' "$rows" | cut -f1 | grep . | sort | uniq -c | tr -s ' ' | tr '\n' ';' || true)"
  groups_assigned="$(printf '%s\n' "$rows" | awk -F'\t' '$1=="Group" {print $2}' | sort -u)"
  if [ "$(more "$ara_url")" = yes ]; then
    row M5 "The group is the only door" "$e" UNVERIFIED "more than 999 assignments; read them all in the Entra admin center"
  elif [ "$ASSIGNMENT_MODE" = group ]; then
    allowed="$GROUP_ID"; [ "$ROLE_SOURCE" = entra ] && allowed="$allowed"$'\n'"$ADMIN_GROUP_ID"
    hasgrp="$(printf '%s\n' "$rows" | awk -F'\t' -v g="$GROUP_ID" -v r="$DEFAULT_APP_ROLE" '$1=="Group" && $2==g && $3==r' | grep -c . || true)"
    nongrp="$(printf '%s\n' "$rows" | awk -F'\t' 'NF && $1!="Group"' | grep -c . || true)"
    othergrp="$(printf '%s\n' "$groups_assigned" | grep . | grep -vxF -f <(printf '%s\n' "$allowed" | grep . || printf 'none\n') | grep -c . || true)"
    if [ "$hasgrp" = "1" ] && [ "$nongrp" = "0" ] && [ "$othergrp" = "0" ]; then row M5 "The group is the only door" "$e" PASS "$types"
    else row M5 "The group is the only door" "$e" FAIL "group assigned: $hasgrp; direct users: $nongrp; other groups: $othergrp"; fi
  else
    have_ids="$(printf '%s\n' "$rows" | awk -F'\t' -v r="$DEFAULT_APP_ROLE" '$1=="User" && $3==r {print $2}' | sort -u)"
    adds="$(printf '%s\n' "$ROSTER_IDS" | grep . | grep -vxF -f <(printf '%s\n' "$have_ids" | grep . || printf 'none\n') | grep -c . || true)"
    removes="$(printf '%s\n' "$have_ids" | grep . | grep -vxF -f <(printf '%s\n' "$ROSTER_IDS" | grep . || printf 'none\n') | grep -c . || true)"
    ngroups="$(count "$groups_assigned")"
    if ! is_guid "$GROUP_ID"; then row M5 "Direct assignments equal the roster" "$e" FAIL "no GROUP_ID recorded (the roster group)"
    elif [ "$ROSTER_OK" = no ]; then row M5 "Direct assignments equal the roster" "$e" UNVERIFIED "the sign-in group's members could not be read in full"
    elif [ "$adds" = 0 ] && [ "$removes" = 0 ] && [ "$ngroups" = 0 ]; then
      row M5 "Direct assignments equal the roster" "$e" "PASS (decided)" "ASSIGNMENT_MODE=direct (no Entra ID P1): $(count "$have_ids") assignments equal the $(count "$ROSTER_IDS")-member roster"
    else row M5 "Direct assignments equal the roster" "$e" FAIL "missing $adds, extra $removes, groups assigned $ngroups; run the sync-assignments step"; fi
  fi

  ao="$(azr ad app owner list --id "$app" --query "length(@)" -o tsv)"
  so="$(g "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/owners?\$select=id" "length(value)")"
  if ge "$ao" 2 && ge "$so" 2; then row M7 "Two owners (app, enterprise app)" "$e" PASS "app $ao, enterprise app $so"
  else row M7 "Two owners (app, enterprise app)" "$e" FAIL "app $ao, enterprise app $so"; fi

  scopes="$(azr ad app show --id "$app" --query "requiredResourceAccess[].resourceAccess[].id" -o tsv | sort | tr '\n' ' ')"
  wantsc="$(printf '%s\n' "$SCOPE_OPENID" "$SCOPE_PROFILE" "$SCOPE_EMAIL" | sort | tr '\n' ' ')"
  pf M8 "Three delegated scopes only" "$e" "openid profile email" "$scopes" [ "$scopes" = "$wantsc" ]

  grants="$(g "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/oauth2PermissionGrants" "value[].[consentType, scope]" | tr '\t' ':' | tr '\n' ';')"
  allp="$(g "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/oauth2PermissionGrants" "value[?consentType=='AllPrincipals'].scope | [0]" | xargs -n1 | sort | tr '\n' ' ')"
  pr="$(g "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/oauth2PermissionGrants" "length(value[?consentType=='Principal'])")"
  if [ "$allp" = "email openid profile " ]; then
    if [ "$pr" = "0" ]; then row M9 "Tenant-wide consent, three scopes" "$e" PASS "$grants"
    else row M9 "Tenant-wide consent, three scopes" "$e" WARN "$pr leftover per-user grant(s)"; fi
  else row M9 "Tenant-wide consent, three scopes" "$e" FAIL "${grants:-none}"; fi

  ara="$(g "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/appRoleAssignments" "length(value)")"
  pf M10 "No application permissions on a sign-in app" "$e" "0" "$ara" [ "$ara" = "0" ]

  live="$(azr ad app credential list --id "$app" --query "length([?endDateTime > '$now'])" -o tsv)"
  ends="$(azr ad app credential list --id "$app" --query "[?endDateTime > '$now'].endDateTime" -o tsv | sort | head -1)"
  certs="$(azr ad app credential list --id "$app" --cert --query "length(@)" -o tsv)"
  long="$(azr ad app credential list --id "$app" --query "length([?endDateTime > '$(end_date 12)'])" -o tsv)"
  soon="$(azr ad app credential list --id "$app" --query "length([?endDateTime > '$now' && endDateTime < '$(end_date 1)'])" -o tsv)"
  if ge "$live" 1 && [ "$long" = "0" ] && [ "$soon" = "0" ]; then
    if [ "$live" = "1" ]; then row M11 "Secret life at most 12 months, not near expiry" "$e" PASS "ends $ends; certificates $certs"
    else row M11 "Secret life at most 12 months, not near expiry" "$e" WARN "$live live secrets: remove the old one after rotation"; fi
  else row M11 "Secret life at most 12 months, not near expiry" "$e" FAIL "live $live, longer than 12 months $long, ending within 30 days $soon"; fi

  lock="$(g "https://graph.microsoft.com/v1.0/applications/$obj?\$select=servicePrincipalLockConfiguration" "servicePrincipalLockConfiguration.isEnabled")"
  pf M18 "Service principal lock" "$e" "enabled" "${lock:-not set}" [ "$lock" = "true" ]

  extra="$(azr ad app show --id "$app" --query "[groupMembershipClaims || 'None', length(identifierUris || \`[]\`), optionalClaims || 'None']" -o tsv | tr '\n\t' '  ')"
  case "$extra" in "None 0 None "*) row M19 "No group claim, no exposed API, no optional claims" "$e" PASS "none" ;; *) row M19 "No group claim, no exposed API, no optional claims" "$e" FAIL "$extra" ;; esac

  approles="$(azr ad app show --id "$app" --query "appRoles[].[value, isEnabled, join(',', allowedMemberTypes)]" -o tsv | tr '[:upper:]' '[:lower:]')"
  nroles="$(count "$approles")"
  if [ "$ROLE_SOURCE" = site ]; then
    if [ "$nroles" = 0 ]; then row M20 "App roles" "$e" N/A "ROLE_SOURCE=site: roles live in the site's own list; no app role defined"
    else row M20 "App roles" "$e" FAIL "$nroles app role(s) defined although ROLE_SOURCE=site"; fi
  else
    holders="$(printf '%s\n' "$rows" | awk -F'\t' -v r="${ADMIN_ROLE_ID:-none}" '$3==r {print $2}' | sort -u)"
    if [ "$ASSIGNMENT_MODE" = group ]; then
      stray="$(printf '%s\n' "$holders" | grep . | grep -vxF "${ADMIN_GROUP_ID:-none}" | grep -c . || true)"
      held="$(printf '%s\n' "$holders" | grep -cxF "${ADMIN_GROUP_ID:-none}" || true)"
    else
      stray="$(printf '%s\n' "$holders" | grep . | grep -vxF -f <(printf '%s\n' "$ADMIN_IDS" | grep . || printf 'none\n') | grep -c . || true)"
      held="$(count "$holders")"
    fi
    if [ "$ASSIGNMENT_MODE" = direct ] && [ "$ADMIN_OK" = no ]; then
      row M20 "App roles" "$e" UNVERIFIED "a group's members could not be read in full, so the Administrator role's holders cannot be checked"
    elif [ "$approles" = "$(printf 'administrator\ttrue\tuser')" ] && [ "$stray" = 0 ] && [ "${held:-0}" -ge 1 ]; then
      row M20 "App roles" "$e" PASS "one role, administrator (users); held by $held $( [ "$ASSIGNMENT_MODE" = group ] && echo "group (the administrators group)" || echo "named administrator(s)")"
    else row M20 "App roles" "$e" FAIL "roles defined: $nroles; holders outside the administrators: $stray; holders: ${held:-0}"; fi
  fi

  an="$(nn "$(azr ad app show --id "$app" --query "notes" -o tsv)")"; sn="$(nn "$(azr ad sp show --id "$sp" --query notes -o tsv)")"
  if printf '%s' "$an" | grep -qF "$MARKER" && printf '%s' "$sn" | grep -qF "$MARKER"; then row M17 "Notes on app and enterprise app carry the marker" "$e" PASS "$MARKER"
  else row M17 "Notes on app and enterprise app carry the marker" "$e" FAIL "app notes: ${an:+present}; sp notes: ${sn:+present}; marker $MARKER missing on at least one"; fi
done

# The sign-in group, and the administrators group when used.
# check_group <id> <label> <marker>
check_group() {
  local id="$1" label="$2" marker="$3" gs mem_url nest_url members guests nested go gd
  if [ -z "$id" ] || [ -z "$(azr ad group show --group "$id" --query id -o tsv)" ]; then
    row M6 "$label found" group FAIL "group ${id:-(no id)} is not in the tenant (deleted, or the state file is stale)"; return 0
  fi
  gs="$(azr ad group show --group "$id" --query "[securityEnabled, mailEnabled, length(groupTypes || \`[]\`), isAssignableToRole || \`false\`]" -o tsv | tr '\n\t' '  ')"
  case "$gs" in "true false 0 "*) row M6 "$label: security, static, not mail" group PASS "$gs" ;; *) row M6 "$label: security, static, not mail" group FAIL "$gs" ;; esac
  mem_url="https://graph.microsoft.com/v1.0/groups/$id/members?\$select=id,userType&\$top=999"
  nest_url="https://graph.microsoft.com/v1.0/groups/$id/members/microsoft.graph.group?\$select=id&\$top=999"
  members="$(g "$mem_url" "length(value)")"
  guests="$(g "$mem_url" "length(value[?userType=='Guest'])")"
  nested="$(g "$nest_url" "length(value)")"
  if [ "$(more "$mem_url")" = yes ] || [ "$(more "$nest_url")" = yes ]; then row M16 "$label: no guests, no nested groups" group UNVERIFIED "more than 999 members; count guests in the Entra admin center"
  elif [ "${nested:-0}" != "0" ]; then row M16 "$label: no guests, no nested groups" group FAIL "nested ${nested}, guests ${guests:-0}"
  elif [ "${guests:-0}" = "0" ]; then row M16 "$label: no guests, no nested groups" group PASS "$members members"
  elif [ "$ALLOW_GUESTS" = yes ]; then row M16 "$label: no guests, no nested groups" group "PASS (decided)" "ALLOW_GUESTS=yes: $guests guest(s) of $members members; no nested groups"
  else row M16 "$label: no guests, no nested groups" group FAIL "guests $guests (ALLOW_GUESTS=no)"; fi
  go="$(azr ad group owner list --group "$id" --query "length(@)" -o tsv)"
  pf M7 "$label: two owners" group "$go" "$go" ge "$go" 2
  gd="$(azr ad group show --group "$id" --query description -o tsv)"
  if picked_by_person "$id"; then
    row M17 "$label description" group N/A "picked by the person by id; its description is theirs and is never rewritten"
  else
    if printf '%s' "$gd" | grep -qF "$marker"; then row M17 "$label description carries the marker" group PASS "$marker"
    else row M17 "$label description carries the marker" group FAIL "description lacks $marker"; fi
  fi
}
# picked_by_person <id>: the id came from the person's own config.
picked_by_person() { grep -Eiq "^(ADMIN_)?GROUP_ID=['\"]?$1" "$CONFIG_FILE"; }
check_group "$GROUP_ID" "Sign-in group" "$MARKER"
if [ "$ROLE_SOURCE" = entra ]; then
  check_group "$ADMIN_GROUP_ID" "Administrators group" "$MARKER:administrators"
  # The Administrator role is itself an assignment, so an administrators-group
  # member outside the sign-in group could sign in without it: a second door.
  if is_guid "$GROUP_ID" && is_guid "$ADMIN_GROUP_ID"; then
    ag_ids="$(graph_list "https://graph.microsoft.com/v1.0/groups/$ADMIN_GROUP_ID/members/microsoft.graph.user?\$select=id&\$top=999" "value[].id")" && ag_ok=yes || ag_ok=no
    sg_ids="$(graph_list "https://graph.microsoft.com/v1.0/groups/$GROUP_ID/members/microsoft.graph.user?\$select=id&\$top=999" "value[].id")" || ag_ok=no
    if [ "$ag_ok" = no ]; then row M5 "Administrators are all in the sign-in group" group UNVERIFIED "a group's members could not be read in full"
    else
      ag_out="$(printf '%s\n' "$ag_ids" | tr '[:upper:]' '[:lower:]' | grep . | grep -vxF -f <(printf '%s\n' "$sg_ids" | tr '[:upper:]' '[:lower:]' | grep . || printf 'none\n') | grep -c . || true)"
      pf M5 "Administrators are all in the sign-in group" group "$(count "$ag_ids") administrator(s), all in the sign-in group" "$ag_out member(s) of the administrators group are not in the sign-in group (a second door; add them to it, or remove them)" [ "$ag_out" = 0 ]
    fi
  fi
fi

# The setup record, where RECORD_IN_REPO put it, with no local path in it.
rec="$(record_path)"
where="the site's docs/auth/entra-record.md"
# shellcheck disable=SC2088  # a path shown to the person, not expanded
[ "$RECORD_IN_REPO" = yes ] || where="~/.config/$SITE/entra-record.md (owner-only)"
if [ ! -f "$rec" ]; then row M17 "Setup record" record FAIL "none at $where; run the record step"
elif grep -Eq '/(Users|home|root)/' "$rec"; then row M17 "Setup record" record FAIL "$where names a local path"
elif [ "$RECORD_IN_REPO" = no ] && [ -n "${SITE_DIR:-}" ] && [ -f "$SITE_DIR/docs/auth/entra-record.md" ]; then
  row M17 "Setup record" record WARN "kept at $where, but a copy is also in the site's repo although RECORD_IN_REPO=no"
else row M17 "Setup record" record PASS "at $where (RECORD_IN_REPO=$RECORD_IN_REPO)"; fi

# MFA, only where the site owner said yes (REQUIRE_MFA=yes): a site whose
# owner said no is N/A on both M14 rows, never FAIL.
# A policy left from an earlier yes is a WARN, not N/A: the record and the
# tenant must agree.
POL_FREQ=""
if [ "$REQUIRE_MFA" != "yes" ]; then
  why="MFA not required by the site owner (REQUIRE_MFA=no${MFA_ANSWERED_BY:+; $MFA_ANSWERED_BY})"
  left=""
  if ca_lookup; then
    [ -n "$CA_FOUND_ID" ] && left="$CA_FOUND_ID, state $CA_FOUND_STATE"
  elif [ -n "${CA_POLICY_ID:-}" ] && [ "$CA_POLICY_ID" != OPEN ]; then
    left="$CA_POLICY_ID, recorded in the state file; the policy list could not be read"
  fi
  if [ -n "$left" ]; then
    row M14 "MFA policy" tenant WARN "a policy still exists ($left) although the site owner said no${MFA_ANSWERED_BY:+ ($MFA_ANSWERED_BY)}: remove it in the Entra admin center, or set REQUIRE_MFA=yes"
  else
    row M14 "MFA policy" tenant N/A "$why"
  fi
  row M14 "Sign-ins used MFA (last 20)" prod N/A "$why"
else
  # The policy if readable, and the sign-in log either way. Found by id when
  # recorded, else by exact name (compared outside JMESPath, so a quote in the
  # name cannot break the query). It must grant MFA and name the group; its
  # state decides PASS or WARN.
  if pols="$(az rest --method get --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" --query "value[].[id, displayName, state, contains(grantControls.builtInControls || \`[]\`, 'mfa'), contains(conditions.users.includeGroups || \`[]\`, '$GROUP_ID'), sessionControls.signInFrequency.value, contains(conditions.users.includeGroups || \`[]\`, '${ADMIN_GROUP_ID:-none}')]" -o tsv 2>/dev/null)"; then
    line="$(printf '%s\n' "$pols" | awk -F'\t' -v id="${CA_POLICY_ID:-}" -v name="$APP_NAME: require MFA" '($1==id && id!="") || $2==name' | head -1)"
    pol="$(printf '%s' "$line" | cut -f3)"; mfa="$(printf '%s' "$line" | cut -f4)"; grp="$(printf '%s' "$line" | cut -f5)"; POL_FREQ="$(printf '%s' "$line" | cut -f6)"; agrp="$(printf '%s' "$line" | cut -f7)"
    if [ -z "$line" ]; then row M14 "MFA policy" tenant FAIL "no policy named $APP_NAME: require MFA"
    elif [ "$mfa" != "True" ] && [ "$mfa" != "true" ]; then row M14 "MFA policy" tenant FAIL "the policy does not grant MFA"
    elif [ "$grp" != "True" ] && [ "$grp" != "true" ]; then row M14 "MFA policy" tenant FAIL "the policy does not name the group"
    elif [ "$ROLE_SOURCE" = entra ] && [ "$agrp" != "True" ] && [ "$agrp" != "true" ]; then row M14 "MFA policy" tenant FAIL "the policy does not name the administrators group (ROLE_SOURCE=entra: its Administrator role opens the apps too); rerun the ca step"
    else
      case "$pol" in enabled) row M14 "MFA policy" tenant PASS "enabled, grants MFA, names the group" ;; enabledForReportingButNotEnforced) row M14 "MFA policy" tenant WARN "report-only; switch on after a clean week" ;; *) row M14 "MFA policy" tenant FAIL "state $pol" ;; esac
    fi
  else row M14 "MFA policy" tenant UNVERIFIED "policy list refused (needs Security Reader); see the sign-in log row"; fi
  if [ -z "${APP_ID_prod:-}" ]; then row M14 "Sign-ins used MFA (last 20)" prod FAIL "no production app id in the state file"
  elif req="$(az rest --method get --url "https://graph.microsoft.com/beta/auditLogs/signIns?\$filter=appId eq '${APP_ID_prod:-}'&\$top=20" --query "value[].authenticationRequirement" -o tsv 2>/dev/null)"; then
    total="$(printf '%s\n' "$req" | grep -c . || true)"; single="$(printf '%s\n' "$req" | grep -c singleFactorAuthentication || true)"
    if [ "$total" = "0" ]; then row M14 "Sign-ins used MFA (last 20)" prod UNVERIFIED "no sign-ins yet"
    elif [ "$single" = "0" ]; then row M14 "Sign-ins used MFA (last 20)" prod PASS "$total of $total multifactor"
    else row M14 "Sign-ins used MFA (last 20)" prod FAIL "$single of $total single factor"; fi
  else row M14 "Sign-ins used MFA (last 20)" prod UNVERIFIED "sign-in log refused (needs Reports Reader or Security Reader)"; fi
fi

# Session length: the configured numbers, and the MFA policy's sign-in
# frequency when there is one. The code's numbers are checked in the site.
sess="idle $SESSION_IDLE_MINUTES minutes, absolute $SESSION_MAX_HOURS hours"
if [ -n "$SESSION_ANSWERED_BY" ]; then row C17 "Absolute session cap" config "PASS (decided)" "$sess; answered by $SESSION_ANSWERED_BY"
else row C17 "Absolute session cap" config "PASS (default)" "$sess (the defaults; no SESSION_ANSWERED_BY in the config)"; fi
if [ -n "$POL_FREQ" ] && [ "$POL_FREQ" != None ]; then
  pf C17 "MFA policy sign-in frequency equals the cap" tenant "$POL_FREQ hours" "policy $POL_FREQ hours, config $SESSION_MAX_HOURS" [ "$POL_FREQ" = "$SESSION_MAX_HOURS" ]
fi

# Server-side Microsoft 365, when used.
READER_APP_ID="${READER_APP_ID:-}"; READER_SP_ID="${READER_SP_ID:-}"
if [ "$NEEDS_M365_SERVER" = "yes" ] && { [ -z "$READER_APP_ID" ] || [ -z "$READER_SP_ID" ]; }; then
  row M12 "Reader is its own app" reader FAIL "no reader app or enterprise app id in the state file"
elif [ "$NEEDS_M365_SERVER" = "yes" ]; then
  pf M12 "Reader is its own app" reader "$READER_APP_ID" "same as the sign-in app or missing" [ "$READER_APP_ID" != "${APP_ID_prod:-}" ]
  rr="$(azr ad app show --id "$READER_APP_ID" --query "[length(web.redirectUris || \`[]\`), length(requiredResourceAccess || \`[]\`)]" -o tsv | tr '\n\t' '  ')"
  case "$rr" in "0 0 "*) row M12 "Reader has no redirects and no scopes" reader PASS "$rr" ;; *) row M12 "Reader has no redirects and no scopes" reader FAIL "$rr" ;; esac
  rsec="$(azr ad app credential list --id "$READER_APP_ID" --query "length(@)" -o tsv)"; rcert="$(azr ad app credential list --id "$READER_APP_ID" --cert --query "length(@)" -o tsv)"
  if [ "$rsec" = "0" ] && ge "$rcert" 1; then row M11 "Reader uses a certificate, no secret" reader PASS "certificates $rcert"
  else row M11 "Reader uses a certificate, no secret" reader FAIL "secrets $rsec, certificates $rcert"; fi
  rara="$(g "https://graph.microsoft.com/v1.0/servicePrincipals/$READER_SP_ID/appRoleAssignments" "length(value)")"
  pf M10 "Reader holds no Graph application permission" reader "0 (reach is Exchange RBAC only)" "$rara" [ "$rara" = "0" ]
  row M13 "Mailbox scope proof" reader UNVERIFIED "read the two Test-ServicePrincipalAuthorization lines from the Exchange run (InScope True, then False)"
fi

echo
echo "Failures: $FAILS"
[ "$FAILS" = 0 ]
