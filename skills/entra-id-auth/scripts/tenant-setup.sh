#!/usr/bin/env bash
# The Microsoft 365 side, one step at a time.
#
#   tenant-setup.sh --site <slug> plan              every step, every command, nothing run
#   tenant-setup.sh --site <slug> plan <step> [env] one step's commands, nothing run
#   tenant-setup.sh --site <slug> run  <step> [env] run that one step
#
# The skill shows a step's plan, asks the person, and runs it only on a yes.
# Every step reuses what already exists, so running one twice is safe. Plan
# mode reads the tenant (to resolve people and find names) and writes nothing.
#
# Steps, in order (env is prod, dev or preview), with the least role each needs:
#   group              the sign-in security group, members, owners   Groups Administrator
#                      (a group picked by id is checked, never changed)
#   admin-group        ROLE_SOURCE=entra only: the administrators group  Groups Administrator
#   app <env>          the app registration                          Application Developer
#   secret <env>       its client secret, to an owner-only file      Application Developer (as owner)
#   sp <env>           the enterprise app: assignment required,      Cloud Application Administrator
#                      the group assigned (or each roster member)
#   consent <env>      tenant-wide consent for openid, profile, email  Cloud Application Administrator
#   sync-assignments   ASSIGNMENT_MODE=direct only: direct            Cloud Application Administrator
#                      assignments made equal to the group's roster
#   ca                 REQUIRE_MFA=yes only: the MFA policy, report-only  Conditional Access Administrator
#   ca-enable          REQUIRE_MFA=yes only: switch it on after a clean week  Conditional Access Administrator
#   reader             server-side Microsoft 365 only: its own app    Application Developer
#   reader-exchange    server-side Microsoft 365 only: the Exchange script  Exchange Administrator (runs it)
#   record             the setup record of every object (no secrets)  any member (reads)
#   teardown           prints the delete commands; never runs them    (prints only)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
need az

[ "${1:-}" = "--site" ] || die "Usage: tenant-setup.sh --site <slug> plan|run [step] [env]"
load_config "${2:-}"; shift 2
MODE="${1:-plan}"; STEP="${2:-all}"; ENVN="${3:-}"
[ "$MODE" = "plan" ] || [ "$MODE" = "run" ] || die "Mode is plan or run."
[ "$MODE" = "run" ] && [ "$STEP" = "all" ] && die "Run one step at a time, after a yes for that step."
[ "$MODE" = "run" ] && [ "$STEP" = "teardown" ] && die "teardown only prints. This skill never deletes a tenant object: a person reads each printed line, checks it, and runs it themselves."

# The tenant is pinned: a run against any other tenant stops here.
pin_tenant
state_set TENANT_ID "$TENANT_ID"
note "tenant: $TENANT_ID (pinned; a run in another tenant refuses)"
need_owners
[ -n "$ENVN" ] && check_env "$ENVN"

MARKER="entra-id-auth:$DOMAIN"
ADMIN_MARKER="entra-id-auth:$DOMAIN:administrators"

needs() { note "needs (least role, from Microsoft's list): $*"; }

# refuse <text>: STOP at run; in plan says so and returns 1, so the caller
# returns and the rest of the plan still shows.
refuse() {
  [ "$MODE" = "plan" ] && { note "STOP at run: $*"; return 1; }
  die "$* Nothing was sent."
}

# OWNER_OIDS: the owners' object ids. Resolved in plan mode too (a read), so
# the plan shows every owner line the run will make and catches an address
# that does not resolve, or two addresses of one person.
OWNER_OIDS=""
resolve_owners() {
  local upn oid i=0 seen=""
  OWNER_OIDS=""
  for upn in ${OWNERS//,/ }; do
    i=$((i+1))
    oid="$(upn_to_oid "$upn" 2>/dev/null || true)"
    oid="$(printf '%s' "$oid" | tr '[:upper:]' '[:lower:]')"
    if ! is_guid "$oid"; then
      [ "$MODE" = "run" ] && die "Owner number $i in OWNERS was not found in this tenant. Nothing was changed by this step."
      note "STOP at run: owner number $i in OWNERS was not found in this tenant."
      oid="<owner-$i-object-id>"
    elif printf '%s\n' "$seen" | grep -qx "$oid"; then
      [ "$MODE" = "run" ] && die "Two entries in OWNERS are the same person (one account, two addresses). Two different people own every object (control M7)."
      note "STOP at run: two entries in OWNERS are the same person; two different people are needed (control M7)."
    fi
    seen="$seen"$'\n'"$oid"
    OWNER_OIDS="$OWNER_OIDS $oid"
  done
  return 0
}
case "$STEP" in all|group|admin-group|app|sp|reader) resolve_owners ;; esac

# ROSTER: one line per person the site's list starts with,
# "oid<TAB>email<TAB>name<TAB>role<TAB>from", from MEMBERS, FIRST_ADMIN and
# EXTRA_ADMINS (from=listed, duplicates dropped), plus, for a group picked by
# id with LIST_GROUP_MEMBERS=all, the group's enabled users (from=group).
# Resolved in plan mode too: every address must be an enabled member account
# (a guest only with ALLOW_GUESTS=yes). Reported as counts; a problem names the
# entry's position, never the person.
ROSTER=""; ROSTER_DONE=""
is_admin_addr() { [ "$1" = "$FIRST_ADMIN" ] || printf '%s\n' "$EXTRA_ADMINS" | tr ',' '\n' | grep -qxF "$1"; }
# group_picked: GROUP_ID is the person's own pick in the config (Q6), not a
# group an earlier run of this skill made. A picked group is never changed.
group_picked() { [ -n "$GROUP_ID" ] && picked_in_config GROUP_ID; }
resolve_roster() {
  [ -z "$ROSTER_DONE" ] || return 0
  ROSTER_DONE=yes
  local all upn i=0 info oid enabled utype name role n=0 admins=0 nf="" dis="" gst="" off=0 offg=0
  # shellcheck disable=SC2086  # the comma lists are split on purpose
  all="$(printf '%s\n' ${MEMBERS//,/ } $FIRST_ADMIN ${EXTRA_ADMINS//,/ } | awk 'NF && !seen[$0]++')"
  for upn in $all; do
    i=$((i+1))
    info="$(az ad user show --id "$upn" --query "[id, accountEnabled, userType, displayName]" -o tsv 2>/dev/null | tr '\n' '\t' || true)"
    oid="$(printf '%s' "$info" | cut -f1 | tr '[:upper:]' '[:lower:]')"
    enabled="$(printf '%s' "$info" | cut -f2)"; utype="$(printf '%s' "$info" | cut -f3)"; name="$(printf '%s' "$info" | cut -f4)"
    role=member; is_admin_addr "$upn" && role=administrator
    if ! is_guid "$oid"; then nf="$nf $i"; oid="<object id of entry $i>"
    else
      case "$enabled" in true|True) ;; *) dis="$dis $i" ;; esac
      [ "$utype" = Guest ] && [ "$ALLOW_GUESTS" != yes ] && gst="$gst $i"
    fi
    [ -z "$EMAIL_DOMAINS" ] || on_email_domains "$upn" || off=$((off+1))
    n=$((n+1)); [ "$role" = administrator ] && admins=$((admins+1))
    ROSTER="$ROSTER$oid"$'\t'"$upn"$'\t'"${name:-$upn}"$'\t'"$role"$'\t'listed$'\n'
  done
  if group_picked && [ "$LIST_GROUP_MEMBERS" = all ]; then
    # The picked group's own users go on the site's list too (Q7: all), so
    # JOIN_MODE=listed does not refuse the people the group already holds.
    # Every page is read (Graph gives at most 999 users a page). A member whose
    # address is off EMAIL_DOMAINS is left off the list when ALLOW_GUESTS=no:
    # the group is not the person's own list, and one such entry would make
    # seed-people.ts refuse the whole file.
    local q="value[?accountEnabled]" rows g=0 gemail gname
    [ "$ALLOW_GUESTS" = yes ] || q="value[?accountEnabled && userType!='Guest']"
    if rows="$(graph_list "https://graph.microsoft.com/v1.0/groups/$GROUP_ID/members/microsoft.graph.user?\$select=id,accountEnabled,userType,mail,userPrincipalName,displayName&\$top=999" \
        "$q.[id, mail || userPrincipalName, displayName]")"; then
      while IFS=$'\t' read -r oid gemail gname; do
        oid="$(printf '%s' "$oid" | tr '[:upper:]' '[:lower:]')"; gemail="$(printf '%s' "$gemail" | tr '[:upper:]' '[:lower:]')"
        is_guid "$oid" || continue
        printf '%s' "$ROSTER" | cut -f1 | grep -qx "$oid" && continue
        if ! on_email_domains "$gemail"; then
          if [ "$ALLOW_GUESTS" != yes ]; then offg=$((offg+1)); continue; fi
          off=$((off+1))
        fi
        g=$((g+1)); n=$((n+1))
        ROSTER="$ROSTER$oid"$'\t'"$gemail"$'\t'"${gname:-$gemail}"$'\t'member$'\t'group$'\n'
      done <<< "$rows"
      note "from the picked group (LIST_GROUP_MEMBERS=all): $g more enabled user(s) go on the site's list as members"
      [ "$offg" -eq 0 ] || note "$offg group member(s) off EMAIL_DOMAINS ($EMAIL_DOMAINS) were left off the site's list (ALLOW_GUESTS=no); add them one by one with scripts/add-person.ts if they should sign in"
    else
      refuse "The members of the picked group $GROUP_ID could not be read, so they cannot go on the site's list." || true
    fi
  fi
  note "roster: $n people ($admins administrator(s)); not found: $(printf '%s' "$nf" | wc -w | tr -d ' '); disabled: $(printf '%s' "$dis" | wc -w | tr -d ' '); guests refused: $(printf '%s' "$gst" | wc -w | tr -d ' ') (ALLOW_GUESTS=$ALLOW_GUESTS)"
  if [ "$off" -gt 0 ]; then
    if [ "$ALLOW_GUESTS" = yes ]; then note "WARNING: $off address(es) are not on EMAIL_DOMAINS ($EMAIL_DOMAINS); ALLOW_GUESTS=yes, so seed with scripts/seed-people.ts --allow-other-domains"
    else note "WARNING: $off address(es) are not on EMAIL_DOMAINS ($EMAIL_DOMAINS); the site's seeding refuses them unless their domain is added"; fi
  fi
  [ "$n" -gt 0 ] || { refuse "No one to add: MEMBERS, FIRST_ADMIN and EXTRA_ADMINS are all empty. Name the first administrator at least." || true; }
  local why=""
  [ -z "$nf" ] || why="$why entries$nf were not found in this tenant (use each person's sign-in address);"
  [ -z "$dis" ] || why="$why entries$dis are disabled accounts;"
  [ -z "$gst" ] || why="$why entries$gst are guests, and ALLOW_GUESTS is no;"
  if [ -n "$why" ]; then
    why="In the roster (MEMBERS, then FIRST_ADMIN, then EXTRA_ADMINS, duplicates dropped):$why fix the addresses in the config."
    [ "$MODE" = "run" ] && die "$why Nothing was changed by this step."
    note "STOP at run: $why"
  fi
  return 0
}

# roster_ids [administrator]: the resolved object ids (all, or administrators only).
roster_ids() {
  printf '%s' "$ROSTER" | awk -F'\t' -v r="${1:-}" 'NF && (r=="" || $4==r) {print $1}' | grep -E '^[0-9a-f]{8}-' || true
}

# write_people: the resolved roster to ~/.config/<slug>/people.json (owner-only),
# read by the site's scripts/seed-people.ts. Run mode only.
write_people() {
  local n admins
  n="$(printf '%s' "$ROSTER" | grep -c . || true)"; admins="$(roster_ids administrator | grep -c . || true)"
  if [ "$MODE" != "run" ]; then
    note "writes (at run): $PEOPLE_FILE (owner-only): $n people, $admins administrator(s), for scripts/seed-people.ts"
    return 0
  fi
  local tmp first=yes oid email name role _from
  tmp="$(mktemp)"
  {
    printf '[\n'
    while IFS=$'\t' read -r oid email name role _from; do
      [ -n "$oid" ] || continue
      is_guid "$oid" || continue
      [ "$first" = yes ] || printf ',\n'
      first=no
      printf '  {"oid": "%s", "email": "%s", "name": "%s", "role": "%s"}' "$oid" "$(js_str "$email")" "$(js_str "$name")" "$role"
    done <<< "$ROSTER"
    printf '\n]\n'
  } > "$tmp"
  (umask 077; mkdir -p "$CONFIG_DIR"; cat "$tmp" > "$PEOPLE_FILE")
  chmod 600 "$PEOPLE_FILE"; rm -f "$tmp"
  note "written: $PEOPLE_FILE (owner-only): $n people, $admins administrator(s)"
}

# group_shape <id> <label>: a group the setup uses must be a static security
# group, not mail-enabled, not Microsoft 365, not dynamic, with no nested
# groups (app assignment does not follow nesting). Returns 1 (plan) on a problem.
group_shape() {
  local id="$1" label="$2" shape sec mail types nested guests members bad=""
  shape="$(az ad group show --group "$id" --query "[securityEnabled, mailEnabled, length(groupTypes || \`[]\`)]" -o tsv 2>/dev/null | tr '\n' '\t' || true)"
  [ -n "$shape" ] || { refuse "$label $id was not found in this tenant." ; return 1; }
  sec="$(printf '%s' "$shape" | cut -f1)"; mail="$(printf '%s' "$shape" | cut -f2)"; types="$(printf '%s' "$shape" | cut -f3)"
  nested="$(graph_count "https://graph.microsoft.com/v1.0/groups/$id/members/microsoft.graph.group?\$select=id&\$top=999" "value[].id")"
  members="$(graph_count "https://graph.microsoft.com/v1.0/groups/$id/members?\$select=id&\$top=999" "value[].id")"
  guests="$(graph_count "https://graph.microsoft.com/v1.0/groups/$id/members/microsoft.graph.user?\$select=id,userType&\$top=999" "value[?userType=='Guest'].id")"
  note "$label now: $members member(s), $guests guest(s), $nested nested group(s)"
  case "$sec" in true|True) ;; *) bad="$bad not security-enabled;" ;; esac
  case "$mail" in false|False) ;; *) bad="$bad mail-enabled;" ;; esac
  [ "$types" = 0 ] || bad="$bad a Microsoft 365 or dynamic group;"
  # A count that could not be read ("?") fails closed, and says so: it is not
  # evidence that the group holds nested groups or guests.
  local unread=""
  case "$nested" in
    0) ;;
    "?") unread="$unread whether it holds nested groups could not be checked;" ;;
    *) bad="$bad it holds nested groups (not honoured for app assignment; add people directly);" ;;
  esac
  if [ "$ALLOW_GUESTS" != yes ]; then
    case "$guests" in
      0) ;;
      "?") unread="$unread whether it holds guests could not be checked;" ;;
      *) bad="$bad it holds guests and ALLOW_GUESTS is no ($guests guest(s), enabled or not: allow guests, remove them from the group, or let the setup make a new group);" ;;
    esac
  fi
  [ -z "$bad$unread" ] && return 0
  if [ -n "$bad" ]; then
    refuse "$label $id is not usable as it is:$bad$unread pick a static security group (or let the setup make one)."
  else
    refuse "$label $id could not be checked in full:$unread Microsoft Graph did not answer (a role, throttling or the network). Nothing is wrong with the group yet; rerun this step."
  fi
}

# group_is_ours <description> <marker> [not-marker]
group_is_ours() {
  printf '%s' "$1" | grep -qF "$2" || return 1
  [ -z "${3:-}" ] || ! printf '%s' "$1" | grep -qF "$3"
}

# ensure_group <ID_VAR> <name> <nick> <marker> <not-marker> <description> <label>:
# the group picked by id (checked, description untouched), or the one this
# skill made (by its marker), or a new one. A same-named group without the
# marker stops the run unless ADOPT_EXISTING_APPS=yes.
ensure_group() {
  local var="$1" name="$2" nick="$3" marker="$4" notm="$5" desc="$6" label="$7" id found n cur
  id="${!var:-}"
  if [ -n "$id" ]; then
    if picked_in_config "$var"; then
      note "Using the $label picked by id: $id. It is used as it is: its description, members and owners are never changed."
    else
      note "Using the $label an earlier run of this step made: $id (recorded in the state file)."
    fi
    group_shape "$id" "The $label" || return 1
    state_set "$var" "$id"
    return 0
  fi
  found="$(az ad group list --display-name "$name" --query "[].id" -o tsv 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  n="$(printf '%s\n' "$found" | grep -c . || true)"
  if [ "$n" -gt 1 ]; then
    refuse "$n groups are named \"$name\". Put the right one's id in the config, or pick another name." || return 1
  elif [ "$n" -eq 1 ]; then
    cur="$(az ad group show --group "$found" --query description -o tsv 2>/dev/null || true)"
    if group_is_ours "$cur" "$marker" "$notm"; then
      note "Exists ($found), made by this skill for https://$DOMAIN (its description carries $marker); reused."
      group_shape "$found" "The $label" || return 1
    elif [ "$ADOPT_EXISTING_APPS" = yes ]; then
      note "WARNING: a group named \"$name\" exists ($found) that this skill did not make for https://$DOMAIN. ADOPT_EXISTING_APPS=yes, so it is used: its description is REPLACED (below), and the people and owners below are added to it. Show the person this line."
      group_shape "$found" "The $label" || return 1
      run_cmd "The description now says what the group opens, who owns it, and carries this site's marker (control M17)." -- \
        az ad group update --group "$found" --description "$desc"
    else
      refuse "A group named \"$name\" exists ($found) that this skill did not make for https://$DOMAIN (its description lacks $marker), so it may be someone else's. Pick another name, put its id in the config to use it as it is, or set ADOPT_EXISTING_APPS=yes after the person hears that its description is replaced and people and owners are added." || return 1
    fi
    id="$found"
  else
    run_capture id "A security group (not Microsoft 365, not mail, not dynamic, not role-assignable). Its description carries the marker $marker, so a rerun finds it and nothing else is mistaken for it." -- \
      az ad group create --display-name "$name" --mail-nickname "$nick" --description "$desc" --query id -o tsv
    if [ "$MODE" = "run" ]; then
      id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
      is_guid "$id" || die "The $label was not created (no id came back). Nothing else was changed by this step."
    else id="<$var, known after this step runs>"; fi
  fi
  state_set "$var" "$id"
}

# add_members <group id> <all|administrator> <why>
add_members() {
  local gid="$1" which="$2" why="$3" oid have=0 added=0 filter=""
  [ "$which" = administrator ] && filter=administrator
  for oid in $(printf '%s' "$ROSTER" | awk -F'\t' -v r="$filter" 'NF && (r=="" || $4==r) {print $1}'); do
    if is_guid "$gid" && is_guid "$oid" && [ "$(az ad group member check --group "$gid" --member-id "$oid" --query value -o tsv 2>/dev/null || true)" = "true" ]; then
      have=$((have+1)); continue
    fi
    added=$((added+1))
    run_cmd "$why" -- az ad group member add --group "$gid" --member-id "$oid"
  done
  note "already members: $have; to add: $added"
}

# check_picked_members <group id> <all|administrator> <label>: a group picked
# by id is never changed, so no member and no owner is added to it. Each person
# this setup needs in it (from the config, not those read from the group) is
# checked instead; one missing stops the run.
check_picked_members() {
  local gid="$1" filter="" label="$3" oid in=0 out=0
  [ "$2" = administrator ] && filter=administrator
  for oid in $(printf '%s' "$ROSTER" | awk -F'\t' -v r="$filter" 'NF && $5=="listed" && (r=="" || $4==r) {print $1}' | grep -E '^[0-9a-f]{8}-' || true); do
    if is_guid "$gid" && [ "$(az ad group member check --group "$gid" --member-id "$oid" --query value -o tsv 2>/dev/null || true)" = "true" ]; then
      in=$((in+1))
    else out=$((out+1)); fi
  done
  note "the $label was picked by id, so no member and no owner is added to it. People from the config it must hold: $((in+out)); members already: $in; missing: $out"
  [ "$out" -eq 0 ] && return 0
  refuse "$out person(s) named in the config (the first administrator, the extra administrators or MEMBERS) are not members of the $label $gid. Add them to the group yourself, or let the setup make a new group (clear the id in the config)." || true
}

# add_group_owners <group id>: owners are added explicitly (an administrator
# who creates a group is not made its owner).
add_group_owners() {
  local gid="$1" oid
  for oid in $OWNER_OIDS; do
    if is_guid "$gid" && is_guid "$oid" && az ad group owner list --group "$gid" --query "[].id" -o tsv 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx "$oid"; then continue; fi
    run_cmd "Two named owners, added explicitly (an administrator who creates a group is not made its owner), so one person leaving does not orphan it (control M7)." -- \
      az ad group owner add --group "$gid" --owner-object-id "$oid"
  done
}

group_description() {
  local roles="Roles live in the site's own people list."
  [ "$ROLE_SOURCE" = entra ] && roles="Administrators are the members of $ADMIN_GROUP_NAME."
  printf 'Can open https://%s. %s Owners: %s. Set up by the entra-id-auth skill. %s' "$DOMAIN" "$roles" "$OWNERS" "$MARKER"
}

# ---------------------------------------------------------------------------
step_group() {
  head1 "Sign-in security group: the only door on the Microsoft side"
  needs "Groups Administrator (or User Administrator)"
  if group_picked; then
    case "$LIST_GROUP_MEMBERS" in
      all) note "LIST_GROUP_MEMBERS=all: every enabled user in the picked group goes on the site's own list now, as a member." ;;
      admins)
        note "LIST_GROUP_MEMBERS=admins: only the administrators go on the site's own list."
        [ "$JOIN_MODE" = group ] || note "WARNING: with JOIN_MODE=listed the site refuses every other member of this group until someone adds them to the site's list. Show the person this line." ;;
      *) refuse "Q7 is not answered for a picked group: set LIST_GROUP_MEMBERS=all (put the group's members on the site's list now) or admins (only the administrators; the others are refused unless JOIN_MODE=group)." || true ;;
    esac
  elif [ -n "$LIST_GROUP_MEMBERS" ]; then
    note "LIST_GROUP_MEMBERS is ignored: no group is picked by id, so MEMBERS is the roster."
  fi
  resolve_roster
  ensure_group GROUP_ID "$GROUP_NAME" "$GROUP_NICK" "$MARKER" "$ADMIN_MARKER" "$(group_description)" "sign-in group" || return 0
  if [ "$JOIN_MODE" = group ]; then
    note "JOIN_MODE=group: a member of this group who is not on the site's list is added on first sign-in, so a Groups Administrator then grants site access alone."
  else
    note "JOIN_MODE=listed: a member of this group who is not on the site's list is refused by the site."
  fi
  if group_picked; then
    check_picked_members "$GROUP_ID" all "sign-in group"
  else
    add_members "$GROUP_ID" all "One person. Users only: nested groups are not honoured for app assignment. Administrators are members too, or Microsoft refuses them."
    add_group_owners "$GROUP_ID"
  fi
  write_people
}

step_admin_group() {
  head1 "Administrators group (ROLE_SOURCE=entra)"
  if [ "$ROLE_SOURCE" != entra ]; then
    note "skipped: ROLE_SOURCE is site, so administrators live in the site's own people list and no second group is made."
    [ "$MODE" = "run" ] && [ "$STEP" = admin-group ] && die "ROLE_SOURCE is not entra for this site."
    return 0
  fi
  needs "Groups Administrator (or User Administrator)"
  resolve_roster
  local desc
  desc="$(printf 'Administers https://%s through its Administrator app role. Members must also be in %s. Owners: %s. Set up by the entra-id-auth skill. %s' "$DOMAIN" "$GROUP_NAME" "$OWNERS" "$ADMIN_MARKER")"
  ensure_group ADMIN_GROUP_ID "$ADMIN_GROUP_NAME" "$GROUP_NICK-admins" "$ADMIN_MARKER" "" "$desc" "administrators group" || return 0
  if [ -n "$ADMIN_GROUP_ID" ] && picked_in_config ADMIN_GROUP_ID; then
    check_picked_members "$ADMIN_GROUP_ID" administrator "administrators group"
  else
    add_members "$ADMIN_GROUP_ID" administrator "One administrator (FIRST_ADMIN or EXTRA_ADMINS). Users only."
    add_group_owners "$ADMIN_GROUP_ID"
  fi
  write_people
}

# is_ours <notes>: true when an object's notes say this skill set it up for this site.
is_ours() { printf '%s' "$1" | grep -q "Set up by the entra-id-auth skill" && printf '%s' "$1" | grep -qF "https://$DOMAIN"; }
# (the marker entra-id-auth:<DOMAIN> is written too; older notes carry the two phrases above)

# ---------------------------------------------------------------------------
step_app() {
  local env="$1" name uris app_id app_obj
  check_env "$env"
  name="$APP_NAME$(env_suffix "$env")"
  read -r -a uris <<< "$(redirect_uris "$env")"
  head1 "App registration \"$name\" ($env)"
  needs "Application Developer (the creator becomes an owner; Cloud Application Administrator also works)"
  app_id="$(az ad app list --display-name "$name" --query "[].appId" -o tsv 2>/dev/null || true)"
  if [ -n "$app_id" ]; then
    [ "$(printf '%s\n' "$app_id" | wc -l | tr -d ' ')" = "1" ] || die "More than one app is named $name."
    # An app with this name that this skill did not make for this site may be
    # someone else's live app. Reshaping it (redirects, scopes, audience) would
    # break it, so adopting one is an explicit choice (ADOPT_EXISTING_APPS=yes).
    local existing_notes recorded_var="APP_ID_$env"
    existing_notes="$(az ad app show --id "$app_id" --query notes -o tsv 2>/dev/null || true)"
    # Ours when its notes say so, or when this site's state file already
    # recorded it (a run that stopped before the notes step).
    if ! is_ours "$existing_notes" && [ "${!recorded_var:-}" != "$app_id" ]; then
      if [ "$ADOPT_EXISTING_APPS" = "yes" ]; then
        note "WARNING: an app named $name exists ($app_id) that this skill did not set up for https://$DOMAIN. ADOPT_EXISTING_APPS=yes, so it is reshaped below: its redirect URIs, scopes, audience, app roles and notes are REPLACED. Show the person this line."
      else
        refuse "An app named $name exists ($app_id) that this skill did not set up for https://$DOMAIN. Pick another APP_NAME, or set ADOPT_EXISTING_APPS=yes after the person agrees its redirects, scopes and audience are replaced." || return 0
      fi
    else
      note "Exists ($app_id), set up by this skill for this site; setting it to the checked shape."
    fi
  else
    run_capture app_id "Single tenant (AzureADMyOrg): no other tenant can get a token. Web redirects only, exact paths, no wildcard. Implicit grant off: code flow with PKCE only." -- \
      az ad app create --display-name "$name" --sign-in-audience AzureADMyOrg \
        --web-redirect-uris "${uris[@]}" \
        --enable-id-token-issuance false --enable-access-token-issuance false \
        --query appId -o tsv
    [ "$MODE" = "plan" ] || is_guid "$app_id" || die "The app registration $name was not created (no id came back)."
  fi
  state_set "APP_ID_$env" "$app_id"
  run_cmd "Exact redirect URIs for this environment only (a localhost URI never sits on production, control M3). No implicit grant. Not a public client." -- \
    az ad app update --id "$app_id" --sign-in-audience AzureADMyOrg --web-redirect-uris "${uris[@]}" \
      --enable-id-token-issuance false --enable-access-token-issuance false \
      --is-fallback-public-client false --web-home-page-url "https://$DOMAIN"
  # Shown inline, so the person approves exactly what is sent (no temp file).
  local rra='[{"resourceAppId":"'"$GRAPH_APP_ID"'","resourceAccess":[{"id":"'"$SCOPE_OPENID"'","type":"Scope"},{"id":"'"$SCOPE_PROFILE"'","type":"Scope"},{"id":"'"$SCOPE_EMAIL"'","type":"Scope"}]}]'
  run_cmd "Exactly three delegated scopes: openid, profile, email. No offline_access (no refresh token to store), no User.Read (no photo fetch). Control M8." -- \
    az ad app update --id "$app_id" --required-resource-accesses "$rra"
  if [ "$ROLE_SOURCE" = entra ]; then
    local rid="${ADMIN_ROLE_ID:-}"
    if [ -z "$rid" ] && is_guid "$app_id"; then
      rid="$(az ad app show --id "$app_id" --query "appRoles[?value=='administrator'].id | [0]" -o tsv 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
      is_guid "$rid" || rid=""
    fi
    if [ -z "$rid" ]; then
      if [ "$MODE" = "run" ]; then rid="$(new_guid)"; else rid="<ADMIN_ROLE_ID, a new GUID made at run>"; fi
    fi
    state_set ADMIN_ROLE_ID "$rid"
    local roles='[{"allowedMemberTypes":["User"],"description":"Administers the site: manages its people and settings.","displayName":"Administrator","id":"'"$rid"'","isEnabled":true,"value":"administrator"}]'
    run_cmd "One app role, Administrator (value administrator), for users and groups. The site reads it from the id token at each sign-in; nothing else is defined (control M20). The same role id on every registration of this site." -- \
      az ad app update --id "$app_id" --app-roles "$roles"
  fi
  app_obj="<object id of $name>"
  [ "$MODE" = "run" ] && app_obj="$(az ad app show --id "$app_id" --query id -o tsv)"
  run_cmd "Lock the service principal side (credentials cannot be added from the enterprise app, control M18); no SPA or public-client redirects (M2); no group claim (M19). Set here, not left to the tenant default." -- \
    az rest --method patch --url "https://graph.microsoft.com/v1.0/applications/$app_obj" \
      --headers Content-Type=application/json \
      --body '{"servicePrincipalLockConfiguration":{"isEnabled":true,"allProperties":true},"spa":{"redirectUris":[]},"publicClient":{"redirectUris":[]},"groupMembershipClaims":null}'
  run_cmd "Notes say what this is, who owns it, where its secret lives (control M17)." -- \
    az ad app update --id "$app_id" --set "notes=Sign-in for https://$DOMAIN ($env). Owners: $OWNERS. Secret: Vercel project ${VERCEL_PROJECT:-$SITE}, and an owner-only config folder for $SITE on the setup machine. Set up by the entra-id-auth skill. $MARKER"
  local oid
  for oid in $OWNER_OIDS; do
    if [ "$MODE" = "run" ] && az ad app owner list --id "$app_id" --query "[].id" -o tsv | tr '[:upper:]' '[:lower:]' | grep -qx "$oid"; then continue; fi
    run_cmd "Two owners on the registration (control M7)." -- az ad app owner add --id "$app_id" --owner-object-id "$oid"
  done
}

# ---------------------------------------------------------------------------
step_secret() {
  local env="$1" app_var="APP_ID_$1" app_id file end label
  check_env "$env"
  app_id="${!app_var:-}"; [ -n "$app_id" ] || [ "$MODE" = "plan" ] || die "Run the app step for $env first."
  app_id="${app_id:-<APP_ID_$env>}"
  file="$CONFIG_DIR/entra-client-secret-$env"
  end="$(end_date "$SECRET_MONTHS")"
  label="$SITE-$env-$(date -u +%Y%m%d)"
  head1 "Client secret for $env ($SECRET_MONTHS months, never printed)"
  needs "Application Developer, as an owner of the app (or Cloud Application Administrator)"
  if [ "$MODE" = "run" ]; then
    local active
    active="$(az ad app credential list --id "$app_id" --query "length([?endDateTime > '$(date -u +%Y-%m-%dT%H:%M:%SZ)'])" -o tsv)"
    note "active secrets on this app before this step: $active"
  fi
  to_secret_file "$file" -- az ad app credential reset --id "$app_id" --display-name "$label" --end-date "$end" --append --query password -o tsv
  note "why: Microsoft advises less than 12 months (control M11); this one is $SECRET_MONTHS. --append keeps any older secret working until the new one is live; remove the old one after."
  if [ "$MODE" = "run" ]; then
    local real_end
    real_end="$(az ad app credential list --id "$app_id" --query "[?displayName=='$label'].endDateTime | [0]" -o tsv)"
    state_set "SECRET_END_$env" "$real_end"
    note "ends: $real_end (written to the state file and, at the record step, to the record)"
  fi
}

# assigned <sp id> <app role id>: principal ids holding that role on the app.
# Returns 1 when the list cannot be read in full (every page), so a caller
# never plans from a partial list.
assigned() {
  is_guid "$1" || return 0
  local rows
  rows="$(graph_list "https://graph.microsoft.com/v1.0/servicePrincipals/$1/appRoleAssignedTo?\$top=999" \
    "value[?appRoleId=='$2'].principalId")" || return 1
  printf '%s\n' "$rows" | tr '[:upper:]' '[:lower:]' | grep . || true
}
ASSIGNED_UNREADABLE="The assignments on the enterprise app could not be read in full, so the step cannot tell what is already assigned."

# assign <sp id> <principal id> <app role id> <why>
assign() {
  run_cmd "$4" -- \
    az rest --method post --url "https://graph.microsoft.com/v1.0/servicePrincipals/$1/appRoleAssignedTo" \
      --headers Content-Type=application/json \
      --body "{\"principalId\":\"$2\",\"resourceId\":\"$1\",\"appRoleId\":\"$3\"}"
}

# ---------------------------------------------------------------------------
step_sp() {
  local env="$1" app_var="APP_ID_$1" app_id sp_id have
  check_env "$env"
  app_id="${!app_var:-}"; [ -n "$app_id" ] || [ "$MODE" = "plan" ] || die "Run the app step for $env first."
  [ -n "$GROUP_ID" ] || [ "$MODE" = "plan" ] || die "No GROUP_ID. Run the group step first."
  app_id="${app_id:-<APP_ID_$env>}"
  if [ "$ASSIGNMENT_MODE" = group ]; then
    head1 "Enterprise app for $env: assignment required, the group assigned"
  else
    head1 "Enterprise app for $env: assignment required, each roster member assigned directly"
  fi
  needs "Cloud Application Administrator (or Application Administrator)"
  check_admins_inside || return 0
  if [ "$ASSIGNMENT_MODE" = group ]; then
    case "$(p1_state)" in
      no) refuse "This tenant has no Entra ID P1 or P2, and Microsoft assigns a group to an app only with P1. Choose one: get P1 (or Microsoft 365 Business Premium), or set ASSIGNMENT_MODE=direct in the config (the group stays the roster; each member is assigned to the app directly, and sync-assignments keeps them equal)." || return 0 ;;
      unknown) note "WARNING: the licence list could not be read. Without Entra ID P1, Microsoft refuses the group assignment below." ;;
    esac
  fi
  sp_id=""
  is_guid "$app_id" && sp_id="$(az ad sp list --filter "appId eq '$app_id'" --query "[].id" -o tsv 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  if [ -z "$sp_id" ]; then
    run_capture sp_id "The enterprise app (service principal) is where assignment and consent live." -- \
      az ad sp create --id "$app_id" --query id -o tsv
    sp_id="$(printf '%s' "$sp_id" | tr '[:upper:]' '[:lower:]')"
    [ "$MODE" = "plan" ] || is_guid "$sp_id" || die "The enterprise app for $env was not created (no id came back)."
  else note "Exists ($sp_id)."; fi
  state_set "SP_ID_$env" "$sp_id"
  run_cmd "Assignment required: Microsoft refuses anyone not assigned before the site hears of them. The strongest control in the list (M4)." -- \
    az ad sp update --id "$sp_id" --set appRoleAssignmentRequired=true
  local access="group $GROUP_NAME only"
  [ "$ASSIGNMENT_MODE" = direct ] && access="each member of group $GROUP_NAME, assigned directly (no Entra ID P1)"
  run_cmd "Notes on the enterprise app too (control M17)." -- \
    az ad sp update --id "$sp_id" --set "notes=Sign-in for https://$DOMAIN ($env). Access: $access. Owners: $OWNERS. Set up by the entra-id-auth skill. $MARKER"
  if [ "$HIDE_FROM_MY_APPS" = "yes" ]; then
    run_cmd "Hidden from My Apps, as asked." -- az ad sp update --id "$sp_id" --add tags HideApp
  else
    note "Shown on My Apps for assigned people (the tile opens https://$DOMAIN)."
  fi
  local oid
  for oid in $OWNER_OIDS; do
    if is_guid "$sp_id" && az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id/owners?\$select=id" --query "value[].id" -o tsv 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx "$oid"; then continue; fi
    run_cmd "Two owners on the enterprise app (control M7)." -- \
      az rest --method post --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id/owners/\$ref" \
        --headers Content-Type=application/json --body "{\"@odata.id\":\"https://graph.microsoft.com/v1.0/directoryObjects/$oid\"}"
  done
  local role_id="${ADMIN_ROLE_ID:-<ADMIN_ROLE_ID, from the app step>}"
  if [ "$ASSIGNMENT_MODE" = group ]; then
    have="$(assigned "$sp_id" "$DEFAULT_APP_ROLE")" || { refuse "$ASSIGNED_UNREADABLE" || return 0; }
    if printf '%s\n' "$have" | grep -qx "${GROUP_ID:-none}"; then note "The group is already assigned."
    else assign "$sp_id" "${GROUP_ID:-<GROUP_ID>}" "$DEFAULT_APP_ROLE" "Assign the group, and only the group, with default access."; fi
    if [ "$ROLE_SOURCE" = entra ]; then
      [ -n "$ADMIN_GROUP_ID" ] || [ "$MODE" = "plan" ] || die "No ADMIN_GROUP_ID. Run the admin-group step first."
      have="$(assigned "$sp_id" "$role_id")" || { refuse "$ASSIGNED_UNREADABLE" || return 0; }
      if printf '%s\n' "$have" | grep -qx "${ADMIN_GROUP_ID:-none}"; then note "The administrators group already holds the Administrator role."
      else assign "$sp_id" "${ADMIN_GROUP_ID:-<ADMIN_GROUP_ID>}" "$role_id" "The administrators group gets the Administrator app role (control M20)."; fi
    fi
    if is_guid "$sp_id"; then
      local direct
      direct="$(graph_count "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id/appRoleAssignedTo?\$top=999" "value[?principalType!='Group'].id")"
      note "direct (non-group) assignments: $direct. Any above 0 is a second door that survives removal from the group (control M5). Remove each in the Entra admin center, or with: az rest --method delete --url https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id/appRoleAssignedTo/<assignment id>"
    fi
  else
    resolve_roster
    local n=0 k=0
    have="$(assigned "$sp_id" "$DEFAULT_APP_ROLE")" || { refuse "$ASSIGNED_UNREADABLE" || return 0; }
    for oid in $(roster_ids) ; do
      if printf '%s\n' "$have" | grep -qx "$oid"; then k=$((k+1)); continue; fi
      n=$((n+1))
      assign "$sp_id" "$oid" "$DEFAULT_APP_ROLE" "One roster member, default access (no P1: people are assigned one by one)."
    done
    note "roster members already assigned: $k; to assign: $n. Rerun sync-assignments whenever the group changes, so the app follows it (control M5)."
    note "Without Entra ID P1, a change to the sign-in group or the administrators group reaches the app only when sync-assignments runs again: removing someone does not stop or demote them until then. To stop or demote someone at once, change them on the site's list too. The record step writes this as an OPEN task."
    if [ "$ROLE_SOURCE" = entra ]; then
      have="$(assigned "$sp_id" "$role_id")" || { refuse "$ASSIGNED_UNREADABLE" || return 0; }
      n=0; k=0
      for oid in $(roster_ids administrator); do
        if printf '%s\n' "$have" | grep -qx "$oid"; then k=$((k+1)); continue; fi
        n=$((n+1))
        assign "$sp_id" "$oid" "$role_id" "One administrator gets the Administrator app role (control M20)."
      done
      note "administrators already holding the role: $k; to assign: $n"
    fi
  fi
}

# ---------------------------------------------------------------------------
step_consent() {
  local env="$1" sp_var="SP_ID_$1" sp_id graph_sp grant
  check_env "$env"
  sp_id="${!sp_var:-}"; [ -n "$sp_id" ] || [ "$MODE" = "plan" ] || die "Run the sp step for $env first."
  sp_id="${sp_id:-<SP_ID_$env>}"
  head1 "Tenant-wide consent for $env (openid profile email)"
  needs "Cloud Application Administrator (or Application Administrator)"
  graph_sp="$(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv 2>/dev/null || true)"
  [ -n "$graph_sp" ] || [ "$MODE" = "plan" ] || die "Microsoft Graph's service principal could not be read in this tenant."
  graph_sp="${graph_sp:-<Microsoft Graph service principal id>}"
  grant=""
  is_guid "$sp_id" && grant="$(az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id/oauth2PermissionGrants" --query "value[?consentType=='AllPrincipals' && resourceId=='$graph_sp'].id | [0]" -o tsv 2>/dev/null || true)"
  if [ -z "$grant" ] || [ "$grant" = None ]; then
    run_cmd "An app that requires assignment gets no user consent, so without this people see 'Need admin approval' (control M9). Three scopes, nothing more." -- \
      az rest --method post --url https://graph.microsoft.com/v1.0/oauth2PermissionGrants \
        --headers Content-Type=application/json \
        --body "{\"clientId\":\"$sp_id\",\"consentType\":\"AllPrincipals\",\"resourceId\":\"$graph_sp\",\"scope\":\"openid profile email\"}"
  else
    run_cmd "A tenant-wide grant exists; set its scopes to exactly three." -- \
      az rest --method patch --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$grant" \
        --headers Content-Type=application/json --body '{"scope":"openid profile email"}'
  fi
  if [ "$MODE" = "run" ]; then
    note "per-user grants on this app: $(az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id/oauth2PermissionGrants" --query "length(value[?consentType=='Principal'])" -o tsv) (should be 0; a leftover one is noise, control M9)"
  fi
}

# ---------------------------------------------------------------------------
# sync_role <env> <sp id> <app role id> <roster ids> <label>: makes the direct
# user assignments of one role equal the roster. Shows counts; changes only in run.
sync_role() {
  local env="$1" sp="$2" role="$3" want="$4" label="$5" rows have adds removes oid aid
  rows="$(graph_list "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/appRoleAssignedTo?\$top=999" \
    "value[?appRoleId=='$role' && principalType=='User'].[principalId, id]")" \
    || { refuse "The assignments on the $env enterprise app could not be read in full, so they cannot be made equal to the roster." || true; return 0; }
  have="$(printf '%s\n' "$rows" | cut -f1 | tr '[:upper:]' '[:lower:]' | grep . || true)"
  adds="$(printf '%s\n' "$want" | grep . | grep -vxF -f <(printf '%s\n' "$have" | grep . || printf '\n') || true)"
  removes="$(printf '%s\n' "$have" | grep . | grep -vxF -f <(printf '%s\n' "$want" | grep . || printf '\n') || true)"
  note "$env, $label: roster $(printf '%s\n' "$want" | grep -c . || true), assigned $(printf '%s\n' "$have" | grep -c . || true): add $(printf '%s\n' "$adds" | grep -c . || true), remove $(printf '%s\n' "$removes" | grep -c . || true)"
  for oid in $adds; do
    assign "$sp" "$oid" "$role" "Assign one roster member who is not yet assigned."
  done
  for oid in $removes; do
    aid="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$oid" 'tolower($1)==p {print $2; exit}')"
    run_cmd "Remove one direct assignment for someone no longer in the roster (an assignment, not an account)." -- \
      az rest --method delete --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/appRoleAssignedTo/$aid"
  done
}

# group_user_ids <group id>: the group's user members (enabled; guests only
# with ALLOW_GUESTS=yes), lower case, every page read. Returns 1 when the list
# cannot be read in full, so a partial list never drives removals.
group_user_ids() {
  local q="value[?accountEnabled]" rows
  [ "$ALLOW_GUESTS" = yes ] || q="value[?accountEnabled && userType!='Guest']"
  rows="$(graph_list "https://graph.microsoft.com/v1.0/groups/$1/members/microsoft.graph.user?\$select=id,accountEnabled,userType&\$top=999" "$q.id")" || return 1
  printf '%s\n' "$rows" | tr '[:upper:]' '[:lower:]' | grep . || true
}

# admins_outside <admin ids> <sign-in ids>: the administrators-group users who
# are not in the sign-in group, one id a line. Under ROLE_SOURCE=entra the
# Administrator role is itself an assignment, so each of them could sign in
# without the sign-in group: a second door.
admins_outside() {
  printf '%s\n' "$1" | grep . | grep -vxF -f <(printf '%s\n' "$2" | grep . || printf 'none\n') || true
}

# check_admins_inside: ROLE_SOURCE=entra only. Stops the run when anyone in the
# administrators group is not also in the sign-in group (the description of
# the administrators group says they must be).
check_admins_inside() {
  [ "$ROLE_SOURCE" = entra ] || return 0
  is_guid "$GROUP_ID" && is_guid "$ADMIN_GROUP_ID" || return 0
  local a m out
  if ! a="$(group_user_ids "$ADMIN_GROUP_ID")" || ! m="$(group_user_ids "$GROUP_ID")"; then
    refuse "The members of the sign-in group or the administrators group could not be read in full, so the setup cannot check that every administrator is also in the sign-in group."; return
  fi
  out="$(admins_outside "$a" "$m" | grep -c . || true)"
  note "administrators-group members who are not in the sign-in group: $out"
  [ "$out" -eq 0 ] && return 0
  refuse "$out member(s) of $ADMIN_GROUP_NAME are not in $GROUP_NAME. The Administrator app role lets them sign in without the sign-in group, as site administrators. Add them to $GROUP_NAME, or take them out of $ADMIN_GROUP_NAME."
}

# made_in_this_plan <value>: true in a full plan when the value is the
# placeholder an earlier step of the same plan left ("<..., known after ...>").
made_in_this_plan() {
  [ "$MODE" = plan ] && [ "$STEP" = all ] || return 1
  case "$1" in "<"*">") return 0 ;; *) return 1 ;; esac
}

step_sync() {
  head1 "Direct assignments made equal to the roster (ASSIGNMENT_MODE=direct)"
  if [ "$ASSIGNMENT_MODE" != direct ]; then
    note "not needed: ASSIGNMENT_MODE is group, so the group itself is assigned and membership changes apply on their own."
    [ "$MODE" = "run" ] && [ "$STEP" = sync-assignments ] && die "ASSIGNMENT_MODE is not direct for this site."
    return 0
  fi
  needs "Cloud Application Administrator (or Application Administrator)"
  local members admins="" outside e sv sp
  # In a full plan, a group or an enterprise app made earlier in the same plan
  # has no id yet. A group the setup makes holds exactly the roster the group
  # step adds, so the plan counts from the resolved roster. Run mode, and
  # "plan sync-assignments" alone, still refuse a missing id.
  if made_in_this_plan "$GROUP_ID"; then
    resolve_roster; members="$(roster_ids)"
    note "the sign-in group is made earlier in this plan (known after the group step runs); planned from the roster: $(printf '%s\n' "$members" | grep -c . || true) people"
  elif ! is_guid "$GROUP_ID"; then refuse "No GROUP_ID recorded. Run the group step first." || return 0
  else
    members="$(group_user_ids "$GROUP_ID")" || { refuse "The members of the sign-in group $GROUP_ID could not be read in full, so no assignment is changed." || true; return 0; }
  fi
  if [ "$ROLE_SOURCE" = entra ]; then
    if made_in_this_plan "$ADMIN_GROUP_ID"; then
      resolve_roster; admins="$(roster_ids administrator)"
      note "the administrators group is made earlier in this plan (known after the admin-group step runs); planned from the roster: $(printf '%s\n' "$admins" | grep -c . || true) administrator(s)"
    elif is_guid "$ADMIN_GROUP_ID"; then
      admins="$(group_user_ids "$ADMIN_GROUP_ID")" || { refuse "The members of the administrators group $ADMIN_GROUP_ID could not be read in full, so no assignment is changed." || true; return 0; }
    else refuse "No ADMIN_GROUP_ID recorded. Run the admin-group step first." || return 0; fi
    # The Administrator role is itself an assignment that lets its holder sign
    # in, so only administrators who are also in the sign-in group get it.
    outside="$(admins_outside "$admins" "$members")"
    if [ -n "$outside" ]; then
      note "WARNING: $(printf '%s\n' "$outside" | grep -c .) member(s) of $ADMIN_GROUP_NAME are not in $GROUP_NAME: they get no Administrator role (it would let them sign in without the sign-in group). Add them to $GROUP_NAME to make them administrators."
      admins="$(printf '%s\n' "$admins" | grep . | grep -vxF -f <(printf '%s\n' "$outside") || true)"
    fi
  fi
  for e in $(envs_in_use); do
    sv="SP_ID_$e"; sp="${!sv:-}"
    if made_in_this_plan "$sp"; then
      note "$e: the enterprise app is made earlier in this plan (known after the sp step runs). sign-in (default access): roster $(printf '%s\n' "$members" | grep -c . || true); the sp step assigns these $(printf '%s\n' "$members" | grep -c . || true) people$( [ "$ROLE_SOURCE" = entra ] && printf ' and gives %s administrator(s) the Administrator role' "$(printf '%s\n' "$admins" | grep -c . || true)"), so a sync straight after it: add 0, remove 0."
      continue
    fi
    if ! is_guid "$sp"; then refuse "No enterprise app recorded for $e. Run the sp step for $e first." || continue; fi
    sync_role "$e" "$sp" "$DEFAULT_APP_ROLE" "$members" "sign-in (default access)"
    if [ "$ROLE_SOURCE" = entra ]; then
      if made_in_this_plan "${ADMIN_ROLE_ID:-}"; then
        note "$e, Administrator role: its id is made at run by the app step; planned from the roster: add $(printf '%s\n' "$admins" | grep -c . || true)"
        continue
      fi
      is_guid "${ADMIN_ROLE_ID:-}" || { refuse "No ADMIN_ROLE_ID recorded. Run the app step first." || continue; }
      sync_role "$e" "$sp" "$ADMIN_ROLE_ID" "$admins" "Administrator role"
    fi
  done
  note "Rerun this step whenever someone joins or leaves the sign-in group or the administrators group; verify-tenant checks that they match (control M5)."
}

# ---------------------------------------------------------------------------
# mfa_skip <step>: true (and says why) when the site owner did not say yes to MFA.
mfa_skip() {
  [ "$REQUIRE_MFA" = "yes" ] && return 1
  head1 "Conditional Access ($1): skipped, MFA is not required for this site"
  note "skipped: REQUIRE_MFA is no, so this site has no MFA policy and nothing is created (the site owner's answer${MFA_ANSWERED_BY:+: $MFA_ANSWERED_BY}). Only the site owner's yes sets REQUIRE_MFA=yes."
  [ "$MODE" = "run" ] && [ "$STEP" = "$1" ] && die "REQUIRE_MFA is not yes for this site. $1 runs only after the site owner says yes to MFA."
  return 0
}

# ca_is_ours <id>: a policy found by name is updated only when this site
# recorded that id, or ADOPT_EXISTING_APPS=yes (the rule apps follow).
# Otherwise it may be someone else's policy: STOP (plan: says so, returns 1).
ca_is_ours() {
  local rec="${CA_POLICY_ID:-}"
  [ -n "$rec" ] && [ "$rec" != OPEN ] && [ "$rec" = "$1" ] && return 0
  if [ "$ADOPT_EXISTING_APPS" = "yes" ]; then
    note "WARNING: a policy named \"$APP_NAME: require MFA\" exists ($1) that this site did not record. ADOPT_EXISTING_APPS=yes, so the update below REPLACES its apps, users and controls (shown next). Show the person this line."
    return 0
  fi
  refuse "A policy named \"$APP_NAME: require MFA\" exists ($1, state $CA_FOUND_STATE) that this site did not record, so it may be someone else's. Pick another APP_NAME, or set ADOPT_EXISTING_APPS=yes after the person agrees its apps, users and controls are replaced. If an administrator made it from this site's policy file, write CA_POLICY_ID=$1 into $STATE_FILE instead."
}

# ca_list <id> <path>: a list from the policy as JSON items "a","b". Only ids
# and plain words pass, so nothing else reaches the body. 1: unreadable, 2: odd item.
ca_list() {
  local raw item out=""
  raw="$(az rest --method get --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$1" --query "$2" -o tsv 2>/dev/null)" || return 1
  for item in $raw; do
    printf '%s' "$item" | grep -Eq '^[A-Za-z0-9-]{1,64}$' || return 2
    out="$out\"$item\","
  done
  printf '%s' "${out%,}"
}

# ca_show_current <id>: prints what the update replaces (read-only), and keeps
# the policy's own excluded users and groups (a break-glass account) in the body.
ca_show_current() {
  local id="$1" cur ex_u ex_g
  cur="$(az rest --method get --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$id" \
      --query "{state:state, includeApplications:conditions.applications.includeApplications, excludeApplications:conditions.applications.excludeApplications, includeUsers:conditions.users.includeUsers, includeGroups:conditions.users.includeGroups, excludeUsers:conditions.users.excludeUsers, excludeGroups:conditions.users.excludeGroups, grant:grantControls.builtInControls, session:sessionControls}" -o json 2>/dev/null)" \
    || { refuse "The policy $id cannot be read, so what an update would replace cannot be shown."; return 1; }
  note "the policy now (the update replaces its apps, users, grant and session controls; its state and its exclusions are kept):"
  printf '%s\n' "$cur" | sed 's/^/      /'
  if ! ex_u="$(ca_list "$id" conditions.users.excludeUsers)" || ! ex_g="$(ca_list "$id" conditions.users.excludeGroups)"; then
    refuse "The exclusions of policy $id cannot be read as plain ids, so they could not be kept."; return 1
  fi
  [ -z "$ex_u$ex_g" ] && return 0
  rendered="$(printf '%s\n' "$rendered" | sed -e "s|\"includeGroups\": \[\([^]]*\)\] }|\"includeGroups\": [\1], \"excludeUsers\": [$ex_u], \"excludeGroups\": [$ex_g] }|")"
}

step_ca() {
  mfa_skip ca && return 0
  head1 "Conditional Access: require MFA for these apps and the site's groups, report-only first"
  needs "Conditional Access Administrator (or Security Administrator)"
  case "$(secdefaults_state)" in
    yes) refuse "Security defaults are on in this tenant. They already ask everyone for MFA, and no Conditional Access policy can be made while they are on. This skill never turns them off: that is the organisation's tenant-wide choice. Keep them (record REQUIRE_MFA=no), or have the organisation replace them with its own policies first." || return 0 ;;
    unknown) note "security defaults could not be read; if they are on, Microsoft refuses the policy below" ;;
  esac
  case "$(p1_state)" in
    no) refuse "Conditional Access needs Entra ID P1 or P2, and this tenant has none. Record REQUIRE_MFA=no, or get P1 first." || return 0 ;;
    unknown) note "WARNING: the licence list could not be read. Conditional Access needs Entra ID P1 or P2; without it, Microsoft refuses the policy below." ;;
  esac
  local file="$CONFIG_DIR/ca-policy.json" apps="" e v rendered found=""
  for e in $(envs_in_use); do
    v="APP_ID_$e"
    [ -n "${!v:-}" ] || [ "$MODE" = "plan" ] || die "No app id for $e. Run the app step for $e first."
    apps="$apps\"${!v:-<APP_ID_$e>}\","
  done
  apps="${apps%,}"
  [ -n "$GROUP_ID" ] || [ "$MODE" = "plan" ] || die "No GROUP_ID. Run the group step first."
  # Under ROLE_SOURCE=entra the administrators group holds its own assignment
  # (the Administrator role), which opens the apps too, so the policy names it.
  local groups="\"${GROUP_ID:-<GROUP_ID>}\""
  if [ "$ROLE_SOURCE" = entra ]; then
    [ -n "$ADMIN_GROUP_ID" ] || [ "$MODE" = "plan" ] || die "No ADMIN_GROUP_ID. Run the admin-group step first."
    groups="$groups, \"${ADMIN_GROUP_ID:-<ADMIN_GROUP_ID>}\""
  fi
  rendered="$(sed -e "s|__APP_NAME__|$(sed_repl "$(js_str "$APP_NAME")")|g" -e "s|__APP_IDS__|$(sed_repl "$apps")|g" -e "s|__GROUP_IDS__|$(sed_repl "$groups")|g" \
    -e "s|__SESSION_MAX_HOURS__|$SESSION_MAX_HOURS|g" \
    "$SKILL_DIR/scripts/ca-policy.json.tmpl")"
  # Reuse, never duplicate: the recorded policy, else the one with this exact name.
  if ca_lookup; then
    if [ "$CA_FOUND_N" -gt 1 ]; then
      refuse "$CA_FOUND_N policies are named \"$APP_NAME: require MFA\". Keep one (delete the others in the Entra admin center), then rerun." || return 0
    fi
    found="$CA_FOUND_ID"
    if [ -n "$found" ]; then ca_is_ours "$found" || return 0; fi
  elif [ -n "${CA_POLICY_ID:-}" ] && [ "$CA_POLICY_ID" != OPEN ]; then
    refuse "The policy list cannot be read, so the recorded policy $CA_POLICY_ID cannot be checked (needs Conditional Access Administrator)." || return 0
  else
    note "the policy list cannot be read (no Conditional Access role): a new policy is sent, and a refusal is recorded OPEN"
  fi
  if [ -n "$found" ]; then
    # Its state is left as it is: a PATCH never flips it either way.
    rendered="$(printf '%s\n' "$rendered" | grep -v '"state":')"
    ca_show_current "$found" || return 0
  fi
  # The person approves the policy itself, not a file name (it is short).
  note "scope: only this site's own app registrations and its sign-in group$( [ "$ROLE_SOURCE" = entra ] && printf ' and administrators group'). It does not cover all cloud apps, the Azure portal or the admin centers, so it cannot lock anyone out of the tenant.$( [ -n "$found" ] || printf ' It has no exclusions.')"
  note "the policy this step sends:"
  printf '%s\n' "$rendered" | sed 's/^/      /'
  if [ "$MODE" = "run" ]; then
    (umask 077; printf '%s\n' "$rendered" > "$file")
    note "policy file: $file"
  else
    note "policy file (written at run): $file"
  fi
  if [ -n "$found" ]; then
    printf '  $ az rest --method patch --url https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/%s --headers Content-Type=application/json --body @%s\n' "$found" "$file"
    note "why: the policy exists ($found, state $CA_FOUND_STATE), so it is updated, not made twice: these apps, the site's groups, MFA, sign-in frequency $SESSION_MAX_HOURS hours (SESSION_MAX_HOURS). Its state is kept."
  else
    printf '  $ az rest --method post --url https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies --headers Content-Type=application/json --body @%s\n' "$file"
    note "why: the site owner asked for MFA (REQUIRE_MFA=yes). Without it a password alone opens the site (control M14). MFA for these apps, sign-in frequency $SESSION_MAX_HOURS hours, the same cap the site's code uses. Report-only shows who it would stop before it stops anyone."
  fi
  if [ "$MODE" = "run" ]; then
    local id err
    err="$(mktemp)"
    if [ -n "$found" ]; then
      az rest --method patch --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$found" --headers Content-Type=application/json --body "@$file" 2>"$err" >/dev/null \
        || { note "The update failed (first line: $(head -1 "$err" | cut -c1-160)). Nothing else changed."; rm -f "$err"; die "The policy $found was not updated."; }
      state_set CA_POLICY_ID "$found"
      note "updated: $found (state $CA_FOUND_STATE)."
    elif id="$(az rest --method post --url https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies --headers Content-Type=application/json --body "@$file" --query id -o tsv 2>"$err")"; then
      state_set CA_POLICY_ID "$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
      note "created, report-only: $id. After a clean week, on its own yes: <skill>/scripts/tenant-setup.sh --site $SITE run ca-enable"
    else
      state_set CA_POLICY_ID "OPEN"
      if grep -Eqi 'forbidden|403|authorization' "$err"; then
        note "Refused (you do not hold Conditional Access Administrator). Hand $file to someone who does, with the command above. Recorded as OPEN."
      else
        note "The policy call failed for another reason (first line: $(head -1 "$err" | cut -c1-160)). Recorded as OPEN; fix and rerun."
      fi
    fi
    rm -f "$err"
  fi
}

step_ca_enable() {
  mfa_skip ca-enable && return 0
  head1 "Switch the MFA policy on"
  needs "Conditional Access Administrator (or Security Administrator)"
  [ -n "${CA_POLICY_ID:-}" ] && [ "${CA_POLICY_ID}" != "OPEN" ] || [ "$MODE" = "plan" ] || die "No policy id recorded."
  run_cmd "After a week in report-only with no one wrongly stopped." -- \
    az rest --method patch --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/${CA_POLICY_ID:-<CA_POLICY_ID>}" \
      --headers Content-Type=application/json --body '{"state":"enabled"}'
}

# check_mailboxes: the reader reaches named mailboxes only, read only. An
# empty or malformed list would make the Exchange scope wrong, and the role is
# written into a PowerShell script, so both are checked here.
check_mailboxes() {
  [ -n "$MAILBOXES" ] || die "MAILBOXES is empty. Name the mailboxes the site reads."
  local m
  for m in ${MAILBOXES//,/ }; do
    printf '%s' "$m" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' || die "MAILBOXES has an entry that is not a plain address."
  done
  EXCHANGE_ROLE="${EXCHANGE_ROLE:-Application Mail.Read}"
  printf '%s' "$EXCHANGE_ROLE" | grep -Eq '^Application [A-Za-z]+\.Read$' \
    || die "EXCHANGE_ROLE must be a read-only Application role (Application <Thing>.Read), not $EXCHANGE_ROLE."
}

# ---------------------------------------------------------------------------
step_reader() {
  [ "$NEEDS_M365_SERVER" = "yes" ] || { note "reader: NEEDS_M365_SERVER is not yes; nothing to do."; return 0; }
  check_mailboxes
  local name="$APP_NAME server reader" rid rsp key crt pem
  head1 "Server-side Microsoft 365: its own app, a certificate, no Graph permission"
  needs "Application Developer (the creator becomes an owner; Cloud Application Administrator also works)"
  rid="$(az ad app list --display-name "$name" --query "[].appId" -o tsv 2>/dev/null || true)"
  if [ -n "$rid" ]; then
    [ "$(printf '%s\n' "$rid" | wc -l | tr -d ' ')" = "1" ] || die "More than one app is named $name."
    local rnotes
    rnotes="$(az ad app show --id "$rid" --query notes -o tsv 2>/dev/null || true)"
    if ! printf '%s' "$rnotes" | grep -qF "https://$DOMAIN" && [ "$ADOPT_EXISTING_APPS" != "yes" ]; then
      refuse "An app named $name exists ($rid) that this skill did not set up for this site. Pick another APP_NAME or set ADOPT_EXISTING_APPS=yes." || return 0
    fi
  fi
  if [ -z "$rid" ]; then
    run_capture rid "A second registration for app-only work, so a leak of the sign-in secret cannot read mail (control M12). No redirect URIs, no delegated scopes." -- \
      az ad app create --display-name "$name" --sign-in-audience AzureADMyOrg --query appId -o tsv
    [ "$MODE" = "plan" ] || is_guid "$rid" || die "The reader app was not created (no id came back)."
  else note "Exists ($rid)."; fi
  state_set READER_APP_ID "$rid"
  run_cmd "No Graph permissions at all: mailbox reach comes only from Exchange RBAC for Applications, scoped to named mailboxes (controls M10, M13)." -- \
    az ad app update --id "$rid" --required-resource-accesses "[]" --set "notes=App-only Microsoft 365 access for https://$DOMAIN. Reach: Exchange RBAC for Applications, $(list_count "$MAILBOXES") named mailbox(es) only. Owners: $OWNERS. Set up by the entra-id-auth skill. $MARKER"
  local robj="<object id of $name>"
  [ "$MODE" = "run" ] && robj="$(az ad app show --id "$rid" --query id -o tsv)"
  run_cmd "Lock the service principal side of the reader too (control M18)." -- \
    az rest --method patch --url "https://graph.microsoft.com/v1.0/applications/$robj" \
      --headers Content-Type=application/json --body '{"servicePrincipalLockConfiguration":{"isEnabled":true,"allProperties":true}}'
  rsp=""
  [ "$MODE" = "run" ] && rsp="$(az ad sp list --filter "appId eq '$rid'" --query "[].id" -o tsv)"
  [ -n "$rsp" ] || run_capture rsp "Its enterprise app; Exchange points at this object id." -- az ad sp create --id "$rid" --query id -o tsv
  state_set READER_SP_ID "$rsp"
  key="$CONFIG_DIR/reader.key"; crt="$CONFIG_DIR/reader.crt"; pem="$CONFIG_DIR/reader.pem"
  if [ -s "$key" ] && [ "${ROTATE_READER_CERT:-no}" != "yes" ]; then
    note "A reader key exists ($key); kept. To renew it: ROTATE_READER_CERT=yes, then remove the old certificate from the app after Vercel has the new one."
  else
    run_cmd "A certificate, not a secret: Microsoft says secrets should not be used in production (control M11). One year. The private key never leaves the owner-only file." -- \
      sh -c "umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj '/CN=$SITE-reader' -keyout '$key' -out '$crt' 2>/dev/null && cat '$key' '$crt' > '$pem'"
    run_cmd "Upload only the public certificate." -- \
      az ad app credential reset --id "$rid" --cert "@$crt" --append --query appId -o tsv
  fi
  if [ "$MODE" = "run" ]; then
    state_set READER_CERT_END "$(az ad app credential list --id "$rid" --cert --query "max_by(@, &endDateTime).endDateTime" -o tsv)"
    note "certificate ends: $READER_CERT_END"
  fi
  local oid
  for oid in $OWNER_OIDS; do
    if [ "$MODE" = "run" ] && az ad app owner list --id "$rid" --query "[].id" -o tsv | tr '[:upper:]' '[:lower:]' | grep -qx "$oid"; then continue; fi
    run_cmd "Two owners." -- az ad app owner add --id "$rid" --owner-object-id "$oid"
  done
}

step_reader_exchange() {
  [ "$NEEDS_M365_SERVER" = "yes" ] || { note "reader-exchange: NEEDS_M365_SERVER is not yes; nothing to do."; return 0; }
  head1 "Exchange RBAC for Applications: read only, named mailboxes only"
  needs "Exchange Administrator (the person who runs the script)"
  check_mailboxes
  [ -n "${READER_APP_ID:-}" ] && [ -n "${READER_SP_ID:-}" ] || [ "$MODE" = "plan" ] || die "Run the reader step first."
  local out="$CONFIG_DIR/grant-mailbox.ps1" filter="" m
  for m in ${MAILBOXES//,/ }; do filter="$filter${filter:+ -or }PrimarySmtpAddress -eq '$m'"; done
  note "the Exchange role: $EXCHANGE_ROLE; the scope: $(list_count "$MAILBOXES") named mailbox(es)"
  if [ "$MODE" = "run" ]; then
    sed -e "s|__READER_APP_ID__|$READER_APP_ID|g" -e "s|__READER_SP_ID__|$READER_SP_ID|g" \
        -e "s|__DISPLAY__|$(sed_repl "$(printf '%s' "$APP_NAME server reader" | LC_ALL=C tr -cd 'A-Za-z0-9 ._()-')")|g" -e "s|__SITE__|$SITE|g" \
        -e "s|__FILTER__|$filter|g" -e "s|__FIRST_MAILBOX__|${MAILBOXES%%,*}|g" -e "s|__EXCHANGE_ROLE__|$EXCHANGE_ROLE|g" \
        "$SKILL_DIR/scripts/grant-mailbox.ps1.tmpl" > "$out"
  fi
  note "script: $out (from scripts/grant-mailbox.ps1.tmpl)"
  note "why: Exchange RBAC for Applications is set in Exchange Online PowerShell, not in Graph. An Exchange administrator runs this file in PowerShell 7 with the ExchangeOnlineManagement module (Windows, macOS or Linux). If the tenant's Conditional Access refuses it from an unmanaged device (AADSTS53003), run it on a compliant or registered device."
  note "It ends with two proof lines: InScope True on the named mailbox, InScope False on any other. Record both."
  note "Never a Graph Mail.Read application permission; never New-ApplicationAccessPolicy (the legacy method)."
}

# ---------------------------------------------------------------------------
step_record() {
  head1 "The setup record of every object (no secrets, no names of members)"
  needs "any member (it only reads)"
  local out
  out="$(record_path)"
  if [ "$RECORD_IN_REPO" = yes ]; then
    note "writes: $out (in the site's repo, as the person chose: it holds the tenant id and the owners' addresses)"
  else
    note "writes: $out (owner-only, outside the site's repo; RECORD_IN_REPO=no)"
  fi
  [ "$MODE" = "run" ] || return 0
  # With MFA now no, a policy left from an earlier yes is named, not hidden.
  local left=""
  if [ "$REQUIRE_MFA" != "yes" ]; then
    if ca_lookup; then
      [ -n "$CA_FOUND_ID" ] && left="$CA_FOUND_ID (state $CA_FOUND_STATE)"
    elif [ -n "${CA_POLICY_ID:-}" ] && [ "$CA_POLICY_ID" != OPEN ]; then
      left="$CA_POLICY_ID (recorded; the policy list could not be read)"
    fi
    [ -z "$left" ] || note "WARNING: MFA is no for this site, but a Conditional Access policy is still in the tenant: $left. Delete it in the Entra admin center, or set REQUIRE_MFA=yes."
  fi
  local body listed="?"
  # The site's list as the group step wrote it (people.json), which is the
  # number the person heard during setup; the group's own count follows.
  [ -f "$PEOPLE_FILE" ] && listed="$(grep -c '"oid"' "$PEOPLE_FILE" || true)"
  body="$(mktemp)"
  {
    echo "# Microsoft Entra ID objects for https://$DOMAIN"
    echo
    echo "Written by the entra-id-auth skill on $(date -u +%Y-%m-%d). Ids and dates only. No secret is in this file."
    echo
    echo "| Object | Id | Notes |"
    echo "|---|---|---|"
    echo "| Tenant | $TENANT_ID | |"
    echo "| Sign-in security group | ${GROUP_ID:-} | $(az ad group member list --group "$GROUP_ID" --query "length(@)" -o tsv 2>/dev/null || echo "?") group members ($listed on the site's list at setup); guests allowed: $ALLOW_GUESTS; owners: $OWNERS |"
    if [ "$ROLE_SOURCE" = entra ]; then
      echo "| Administrators group | ${ADMIN_GROUP_ID:-} | holds the Administrator app role (id ${ADMIN_ROLE_ID:-unknown}) |"
    fi
    local e a s d assigned_to="group assigned"
    [ "$ASSIGNMENT_MODE" = direct ] && assigned_to="each roster member assigned directly (no Entra ID P1); keep in step with sync-assignments"
    for e in $(envs_in_use); do
      a="APP_ID_$e"; s="SP_ID_$e"; d="SECRET_END_$e"
      echo "| App registration ($e) | ${!a:-} | client secret ends ${!d:-unknown}; kept in Vercel and the setup machine's owner-only config folder |"
      echo "| Enterprise app ($e) | ${!s:-} | assignment required; $assigned_to |"
    done
    if [ "$REQUIRE_MFA" = "yes" ]; then
      echo "| Conditional Access policy | ${CA_POLICY_ID:-not created} | require MFA, sign-in frequency $SESSION_MAX_HOURS hours; the site owner said yes ($MFA_ANSWERED_BY) |"
    elif [ -n "$left" ]; then
      echo "| Conditional Access policy | $left | STILL IN THE TENANT, left from an earlier yes. The site owner now says no${MFA_ANSWERED_BY:+ ($MFA_ANSWERED_BY)}: delete it in the Entra admin center, or set REQUIRE_MFA=yes |"
    else
      echo "| Conditional Access policy | none | MFA not required by the site owner${MFA_ANSWERED_BY:+ ($MFA_ANSWERED_BY)}; the site caps sessions itself |"
    fi
    [ "$NEEDS_M365_SERVER" = "yes" ] && echo "| Server reader app | ${READER_APP_ID:-} | certificate ends ${READER_CERT_END:-unknown}; Exchange scope: $(list_count "$MAILBOXES") named mailbox(es) |"
    echo
    echo "## Settings"
    echo
    echo "- Sessions: idle $SESSION_IDLE_MINUTES minutes, absolute $SESSION_MAX_HOURS hours${SESSION_ANSWERED_BY:+ (answered by $SESSION_ANSWERED_BY)}."
    echo "- Roles: $( [ "$ROLE_SOURCE" = entra ] && echo "the Administrator app role, through the administrators group" || echo "the site's own people list")."
    echo "- A group member not on the site's list: $( [ "$JOIN_MODE" = group ] && echo "added on first sign-in (JOIN_MODE=group)" || echo "refused (JOIN_MODE=listed)")."
    echo
    local today open=""
    today="$(date -u +%Y-%m-%d)"
    if [ "$ASSIGNMENT_MODE" = direct ]; then
      open="$open- OPEN ($today, owners: $OWNERS): no Entra ID P1, so Microsoft's door follows the sign-in group or the administrators group only when sync-assignments runs. After every change to either group run \`tenant-setup.sh --site $SITE run sync-assignments\`. To stop or demote someone at once, also change them on the site's list."$'\n'
    fi
    if [ "$REQUIRE_MFA" = "yes" ]; then
      if [ "${CA_POLICY_ID:-}" = OPEN ] || [ -z "${CA_POLICY_ID:-}" ]; then
        open="$open- OPEN ($today, owners: $OWNERS): the MFA policy was not created. Someone with Conditional Access Administrator runs the ca step."$'\n'
      elif ca_lookup && [ "$CA_FOUND_STATE" = enabledForReportingButNotEnforced ]; then
        open="$open- OPEN ($today, owners: $OWNERS): the MFA policy is report-only. After a week with no one wrongly stopped, switch it on: \`tenant-setup.sh --site $SITE run ca-enable\`."$'\n'
      fi
    fi
    if [ -n "$open" ]; then
      echo "## Open"
      echo
      printf '%s' "$open"
      echo
    fi
    echo "## Renewals"
    for e in $(envs_in_use); do d="SECRET_END_$e"; echo "- $e client secret ends ${!d:-unknown}. Renew 30 days before with the entra-id-auth skill: \`tenant-setup.sh --site $SITE run secret $e\`, then \`vercel-env.sh --site $SITE run $( [ "$e" = dev ] && echo local || echo "$e")\`."; done
    [ "$NEEDS_M365_SERVER" = "yes" ] && echo "- Reader certificate ends ${READER_CERT_END:-unknown}. Renew with the entra-id-auth skill's reader step."
  } > "$body"
  if [ "$RECORD_IN_REPO" = yes ]; then
    mkdir -p "$(dirname "$out")"; cat "$body" > "$out"
  else
    (umask 077; mkdir -p "$(dirname "$out")"; cat "$body" > "$out"); chmod 600 "$out"
  fi
  rm -f "$body"
  note "written: $out"
}

# ---------------------------------------------------------------------------
step_teardown() {
  head1 "Teardown: the delete commands, printed only"
  note "This skill never deletes a tenant object. Check each id in the Entra admin center first; whoever holds the role runs the lines they want, in this order."
  local e a s any=no
  if [ -n "${CA_POLICY_ID:-}" ] && [ "$CA_POLICY_ID" != OPEN ]; then
    printf '  $ az rest --method delete --url https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/%s\n' "$CA_POLICY_ID"
    note "the MFA policy (needs Conditional Access Administrator)"; any=yes
  fi
  for e in prod dev preview; do
    a="APP_ID_$e"; s="SP_ID_$e"
    [ -n "${!s:-}" ] && { printf '  $ az ad sp delete --id %s\n' "${!s}"; any=yes; }
    [ -n "${!a:-}" ] && { printf '  $ az ad app delete --id %s\n' "${!a}"; note "the $e registration and its enterprise app (needs Cloud Application Administrator, or an owner of the app)"; any=yes; }
  done
  if [ -n "${READER_APP_ID:-}" ]; then
    printf '  $ az ad app delete --id %s\n' "$READER_APP_ID"
    note "the server reader app; an Exchange administrator also removes its management role assignment and scope"; any=yes
  fi
  if [ -n "${ADMIN_GROUP_ID:-}" ]; then
    if picked_in_config ADMIN_GROUP_ID; then note "the administrators group $ADMIN_GROUP_ID was picked by the person: kept, not listed for deletion"
    else printf '  $ az ad group delete --group %s\n' "$ADMIN_GROUP_ID"; note "the administrators group (needs Groups Administrator)"; any=yes; fi
  fi
  if [ -n "${GROUP_ID:-}" ]; then
    if picked_in_config GROUP_ID; then note "the sign-in group $GROUP_ID was picked by the person: kept, not listed for deletion"
    else printf '  $ az ad group delete --group %s\n' "$GROUP_ID"; note "the sign-in group (needs Groups Administrator)"; any=yes; fi
  fi
  [ "$any" = yes ] || note "no object ids are recorded for this site, so there is nothing to delete in the tenant"
  note "Vercel: vercel env rm <NAME> <environment> --yes for each name the vercel-env plan lists${VERCEL_SCOPE:+ (with --scope $VERCEL_SCOPE)}."
  note "This machine: the owner-only folder ~/.config/$SITE holds the secrets, the state and the roster; remove it last, after Vercel."
  note "The setup record ($(record_path)) says what existed; keep it or remove it."
}

# ---------------------------------------------------------------------------
all_steps() {
  step_group
  step_admin_group
  local e
  for e in $(envs_in_use); do step_app "$e"; step_secret "$e"; step_sp "$e"; step_consent "$e"; done
  step_sync
  step_ca
  step_reader
  step_reader_exchange
  step_record
}

case "$STEP" in
  all) all_steps ;;
  group) step_group ;;
  admin-group) step_admin_group ;;
  app) step_app "${ENVN:?give prod, dev or preview}" ;;
  secret) step_secret "${ENVN:?give prod, dev or preview}" ;;
  sp) step_sp "${ENVN:?give prod, dev or preview}" ;;
  consent) step_consent "${ENVN:?give prod, dev or preview}" ;;
  sync-assignments) step_sync ;;
  ca) step_ca ;;
  ca-enable) step_ca_enable ;;
  reader) step_reader ;;
  reader-exchange) step_reader_exchange ;;
  record) step_record ;;
  teardown) step_teardown ;;
  *) die "Unknown step $STEP. Steps: group admin-group app secret sp consent sync-assignments ca ca-enable reader reader-exchange record teardown." ;;
esac
if [ "$MODE" = "plan" ]; then printf '\n(plan only: nothing was changed)\n'; fi
exit 0
