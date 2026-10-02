# The Entra side, step by step

Every step is one call of `<skill>/scripts/tenant-setup.sh`, run from the site's folder. The rhythm,
for each step:

1. `tenant-setup.sh --site <slug> plan <step> [env]`, and show the person the commands and the why
   lines.
2. Ask: "Run this step? (yes / no / change something)". One step per question.
3. Only on a yes: `tenant-setup.sh --site <slug> run <step> [env]`. Report what it printed (ids,
   counts).

`plan` with no step prints the whole setup (the dry run). `env` is `prod`, `dev` or `preview`.
Steps reuse what this skill made for this site, so a rerun is safe. Every step first checks the
Azure CLI is signed in to `TENANT_ID` and stops otherwise.

## Order, and the least role each step needs

| # | Step | Least role (Microsoft's list) | Creates or sets | Controls |
|---|---|---|---|---|
| 0 | `preflight.sh --site <slug>` | any member (read only) | nothing | names taken, marker, roles held |
| 1 | `group` | Groups Administrator | a new sign-in group: members (plus the first administrator), 2 owners, the marker. A group picked by id: nothing added. Both: `people.json` | M5, M6, M7, M16, M17 |
| 2 | `admin-group` | Groups Administrator | only with `ROLE_SOURCE=entra`: `<Site> Administrators`, same shape; adds to `people.json` | M20 |
| 3 | `app prod` | Application Developer (the creator becomes owner) | registration: single tenant, exact https redirects, no implicit grant, 3 scopes, the `Administrator` app role only with `ROLE_SOURCE=entra`, notes, 2 owners | M1, M2, M3, M8, M17, M18, M19, M20 |
| 4 | `secret prod` | Application Developer (as owner) | client secret, `SECRET_MONTHS` (default 11, never more than 12), straight to `~/.config/<slug>/entra-client-secret-prod`; end date to the state file | M11 |
| 5 | `sp prod` | Cloud Application Administrator | enterprise app, assignment required, notes, 2 owners; the group assigned (or, with `direct`, each roster member, and with `ROLE_SOURCE=entra` each administrator the `Administrator` role); with `group`, the admin group given `Administrator` | M4, M5, M7, M17, M20 |
| 6 | `consent prod` | Cloud Application Administrator | one tenant-wide grant, `openid profile email` | M9 |
| 7 | `app dev`, `secret dev`, `sp dev`, `consent dev` | as above | the local registration, localhost redirect only | M3 |
| 8 | `app preview` ... | as above | only with `PREVIEW_MODE=stable-host` | M3, C38 |
| 9 | `sync-assignments` | Cloud Application Administrator | only with `ASSIGNMENT_MODE=direct`: each enterprise app's direct assignments made equal to the roster | M5 |
| 10 | `ca` | Conditional Access Administrator | only with `REQUIRE_MFA=yes`: the MFA policy, report-only, sign-in frequency `SESSION_MAX_HOURS` | M14 |
| 11 | `reader` | Application Developer, then Cloud Application Administrator for its enterprise app | only with `NEEDS_M365_SERVER=yes`: its own app and certificate | M10, M11, M12 |
| 12 | `reader-exchange` | Exchange Administrator | writes `grant-mailbox.ps1` for them to run | M13 |
| 13 | `record` | none | the setup record, where `RECORD_IN_REPO` says | M11, M17 |
| later | `ca-enable` | Conditional Access Administrator | only with `REQUIRE_MFA=yes`: switch the policy on after a clean week | M14 |
| any time | `teardown` | none | prints the delete commands for this site's marked objects; runs none | |

Preflight prints the roles the signed-in admin holds against this table and names what is missing.
A step whose role is missing is handed, with its plan output, to someone who holds it, and recorded
OPEN. A wider role (Application Administrator, Global Administrator) also works; never ask for one.

## The takeover guard

Every object this skill makes carries the marker `entra-id-auth:<DOMAIN>`: in the group's
description, the app registration's notes and the enterprise app's notes. The CA policy is
recognised by the id this site recorded.

| A step finds | It does |
|---|---|
| nothing of that name | creates it, with the marker |
| one of that name with this site's marker | reuses it |
| one of that name without the marker | STOP. Pick another name, or `ADOPT_EXISTING_APPS=yes` after the person hears what will change (redirects, scopes, audience, members, owners) and says yes |
| two or more of that name | STOP |
| a group given by id (`GROUP_ID`, `ADMIN_GROUP_ID`) | checks its type (below); uses it as is: adds no members and no owners, never rewrites its description. The plan reports how many of the administrators are already members; one missing stops the plan ("add them to the group yourself, or let the setup make a new group") |

**Group type check.** A group given by id must be `securityEnabled` true, `mailEnabled` false,
`groupTypes` empty (not a Microsoft 365 group, not dynamic), with no nested groups. Anything else
stops at plan time, not at the final check.

## What each command does, and why

**Group.** `az ad group create --display-name ... --mail-nickname ... --description ...` makes a
static security group (the CLI default: security, not mail, not Microsoft 365). The description
carries the marker. Members are users only: nested group memberships are not honoured for app
assignment. An administrator who creates a group is not made its owner, so both owners are added
explicitly. Members are resolved by `az ad user show` at plan time; disabled accounts, and guests
unless `ALLOW_GUESTS=yes`, stop the plan. The resolved roster goes to `~/.config/<slug>/people.json`.
With a group picked by id and `LIST_GROUP_MEMBERS=all`, the group's own user members (enabled; guests
only with `ALLOW_GUESTS=yes`) go into `people.json` as members too, read, never changed; with `admins`,
only the administrators do. Every read of a group's members follows Microsoft's next-page links, so
a group of any size is read whole. With `ALLOW_GUESTS=no`, a group member whose address is off
`EMAIL_DOMAINS` (a service account on `*.onmicrosoft.com`, say) is left off `people.json`, and the
plan gives the count: add such a person one by one with `scripts/add-person.ts` if they should sign
in. Seeding refuses the whole file when one entry is off the domains, so leaving them off keeps
everyone else seeded.

**Administrators group** (`ROLE_SOURCE=entra`). The same shape and guard, named
`<Site> Administrators`. It is assigned the `Administrator` app role on each sign-in enterprise app
in the `sp` step. With no P1, the role is assigned to each named administrator directly instead.
That assignment is a door of its own: "assignment required" accepts any assignment, so a member of
the administrators group can sign in without being in the sign-in group, and becomes a site
administrator. Tell the person so (interview Q11), and keep the administrators group to people who
may manage the site. Every administrator must also be in the sign-in group: `sp` stops at run when
one is not, `sync-assignments` (direct mode) gives the Administrator role only to those inside it,
and verify-tenant checks it (M5). With `REQUIRE_MFA=yes` the Conditional Access policy covers both
groups.

**App registration.** `az ad app create --sign-in-audience AzureADMyOrg --web-redirect-uris ...
--enable-id-token-issuance false --enable-access-token-issuance false`. Single tenant is Microsoft's
recommendation for most applications. Redirects are exact https URIs (`https://<DOMAIN>` and
`https://<VERCEL_HOST>` callbacks for production; `http://localhost:<LOCAL_PORT>` on its own local
app); a wildcard is refused. The redirect list is replaced whole on each update, so the script
always passes every URI for that environment. `--required-resource-accesses` sets exactly three
delegated Graph scopes (ids in `lib.sh`); a new registration otherwise gets `User.Read`. With
`ROLE_SOURCE=entra` the registration defines one app role, display name `Administrator`, value
`administrator`, allowed member type User; with `site` it defines none. One Graph PATCH then turns
on `servicePrincipalLockConfiguration` (M18) and clears SPA and public-client redirects (M2) and
any group claim (M19), instead of trusting the tenant default.

**Secret.** `az ad app credential reset --end-date <SECRET_MONTHS from today> --append --query password -o tsv > <file>`.
Microsoft advises an expiry of less than 12 months, and says client secrets are weaker than
certificates or federated credentials (see the end of this page). The value goes to an owner-only
file and nowhere else. `--append` keeps an old secret alive during a rotation; remove it after the
new one is on Vercel.

**Enterprise app.** `az ad sp create`, then `appRoleAssignmentRequired=true`: only assigned users
(directly or through a group) can sign in. With `ASSIGNMENT_MODE=group` the group is assigned with
the default role id `00000000-0000-0000-0000-000000000000`; any direct user assignment is a second
door, counted, and M5 fails on it. With `direct`, each roster member is assigned here (and, with
`ROLE_SOURCE=entra`, each administrator the `Administrator` role); `sync-assignments` later makes the
assignments equal to the group's members, adding and removing.

**No Entra ID P1.** Assigning a group to an enterprise app needs P1 or P2. Preflight finds this
before any write and the interview offers two paths: get P1, or `ASSIGNMENT_MODE=direct`. With
`direct`, the group is still created as the roster, and `sync-assignments` assigns each member to
each enterprise app directly and removes the assignment of anyone no longer in the group (an
assignment, not an account: no tenant object is deleted). The plan shows the counts to add and to
remove. Nothing reruns it by itself: removing someone from the group does not stop them at
Microsoft until someone reruns it, so to remove someone at once, take them off the site's list too
(with `JOIN_MODE=listed` the list is a second gate). The record writes a dated OPEN line for the
rerun. M5 reads PASS (decided) when the direct assignments equal the roster, and FAIL on drift. No
Conditional Access policy is possible without P1. A scheduled job in the site that edits
assignments is not offered: it would put a Graph credential that can change assignments inside the
site.

**Consent.** An app that requires assignment gets no user consent, so tenant-wide consent is
granted. The step posts one `AllPrincipals` `oauth2PermissionGrants` row for exactly
`openid profile email`, or trims an existing one. The grant call is exact; a blanket admin-consent
command would grant whatever the registration lists.

**Security defaults.** A tenant-wide setting, free on every tenant, that already asks for MFA. It
cannot be scoped to one app, and Microsoft does not run Conditional Access policies beside it. This
skill reads it and never turns it on or off. While it is on, `ca` is not offered.

**Conditional Access, only on the person's yes.** With `REQUIRE_MFA=no`, `ca` and `ca-enable`
create nothing (a `run` of either refuses), the record says why, and verify-tenant marks M14 N/A.
With yes, the policy is written from `scripts/ca-policy.json.tmpl`: these apps, the sign-in group
(and the admin group with `ROLE_SOURCE=entra`), all client apps, grant MFA, sign-in frequency
`SESSION_MAX_HOURS` hours, state `enabledForReportingButNotEnforced`. It covers only this site's
apps and groups, with no exclusions; it never reaches other apps or the admin portals, so it cannot
lock anyone out of the tenant. The plan prints the whole policy, so the person approves what is sent, not a file name. After a week in which nobody is
wrongly stopped, `ca-enable`. A rerun of `ca` never makes a second policy.

| `ca` finds | It does |
|---|---|
| the policy whose id this site recorded | updates it |
| a policy named `<APP_NAME>: require MFA` this site never recorded | STOP: pick another name, `ADOPT_EXISTING_APPS=yes` after the person agrees, or record its id if an administrator made it from this site's file |
| two with that name | STOP |
| none | makes it, report-only |

An update first prints the policy as it is now. It replaces the apps, users and controls, keeps the
policy's excluded users and groups, and never changes its state. If the answer later changes from
yes to no, the skill does not delete the policy: the record names it, and verify-tenant reports M14
WARN until someone removes it in the Entra admin center or sets `REQUIRE_MFA=yes` again. If the
runner lacks the role, the file is kept in `~/.config/<slug>/ca-policy.json`, handed to someone who
has it, and recorded OPEN. A device rule (compliant or registered) is the organisation's own
tenant-wide choice; the skill does not add one. App-only sign-ins are outside Conditional Access.

**Reader (server-side Microsoft 365 only).** Its own registration, no redirects, no scopes, no Graph
application permission. A one-year self-signed certificate: the key stays in
`~/.config/<slug>/reader.key`, only the public `reader.crt` is uploaded, and `reader.pem` (key plus
certificate) goes to Vercel as a Sensitive setting. Reach comes from Exchange RBAC for
Applications, which replaces Application Access Policies: `reader-exchange` writes
`grant-mailbox.ps1` with `New-ServicePrincipal`, `New-ManagementScope` (the named mailboxes),
`New-ManagementRoleAssignment -Role "Application Mail.Read"`, and two
`Test-ServicePrincipalAuthorization` proof lines. Never a Graph `Mail.Read` application permission
(every mailbox in the tenant), never `New-ApplicationAccessPolicy`.

An Exchange Administrator runs it in PowerShell 7 with the ExchangeOnlineManagement module, on
Windows, macOS or Linux. AADSTS53003 means a Conditional Access policy blocked the sign-in (often a
managed-device or location rule): ask the Microsoft 365 administrator which rule, and on a device
rule run it on a compliant or registered device.

**Record.** One Markdown file: every object's id, owners, the marker, secret and certificate end
dates, the answers that decided a row (`MFA_ANSWERED_BY`, `SESSION_ANSWERED_BY`), and what stays
OPEN (with `ASSIGNMENT_MODE=direct`, a dated line: rerun `sync-assignments` after every change to
the group). It never holds a secret or a local path. With `RECORD_IN_REPO=yes` it is the site's
`docs/auth/entra-record.md`; otherwise `~/.config/<slug>/entra-record.md`, because it names the
tenant id and the owners' addresses.

**Teardown.** Prints, for each object carrying this site's marker (and the recorded policy id), the
`az` or Graph delete command, in a safe order. It runs none of them and deletes nothing.

## When a step is refused

| Refusal | Meaning | Do |
|---|---|---|
| A line starting `STOP:` | the script refused and changed nothing | tell the person the reason in plain words; fix the cause; never work around it |
| 403 on a Graph call | the runner lacks the role | name the least role (table above), hand the plan output to someone who holds it, record the step OPEN |
| "no Entra ID P1" | a group cannot be assigned to an app | the two paths above, on the person's choice |
| "security defaults are on" | no Conditional Access policy can be added | nothing; `REQUIRE_MFA=no`, M14 N/A with the reason |
| "carries no entra-id-auth marker" | a same-named object may be someone else's | another name; or `ADOPT_EXISTING_APPS=yes` on the person's yes |
| "is not a security group" (or mail-enabled, Microsoft 365, dynamic, nested) | the group picked by id has the wrong shape | pick another group, or let the skill create one |
| AADSTS53003 on Exchange PowerShell | a Conditional Access policy blocked the sign-in (often a managed-device or location rule) | ask the Microsoft 365 administrator which rule; on a device rule, run `grant-mailbox.ps1` on a compliant or registered device |
| "Owner ... was not found" | a mistyped or departed owner in `OWNERS` | correct `OWNERS` (two people in this tenant), rerun the step |
| "owners are the same person" | the two owners match, ignoring case | name a second owner |
| "REQUIRE_MFA is not yes" | `ca` or `ca-enable` where the answer was no | nothing to do; set `REQUIRE_MFA=yes` only on the person's own yes |
| "More than one app is named" | a name clash | pick the right one, rename the other by hand, rerun |
| "policies are named ...: require MFA" | two or more MFA policies share this site's name | keep one in the Entra admin center, remove the others by hand, rerun `ca` |
| "MFA_ANSWERED_BY is empty" or "may hold only" | the answer has no plain "who, when" | write `MFA_ANSWERED_BY='<who>, <YYYY-MM-DD>'` from the person's answer; never invent it |
| "is not a git repository yet" | git cannot keep `.env.local` out of commits | set git user.name and user.email, `git init`, a first commit, rerun |
| 65001 or 90094 at first sign-in | consent missing | rerun `consent <env>` |
| AADSTS50105 at sign-in | the person is not assigned (not in the group, or not synced with `direct`) | add them to the group; with `direct`, rerun `sync-assignments` |
| AADSTS50011 at sign-in | redirect URI mismatch | the address differs from the registration; fix `DOMAIN` or `VERCEL_HOST` and rerun `app <env>` |

## Stronger than a secret, when wanted

The sign-in app can use a certificate instead of a secret through Better Auth's `clientAssertion`
(private_key_jwt). Entra expects an `x5t` (or `x5t#S256`) header on the assertion; Better Auth
1.7.5's built-in signer sets `kid`. This release does not set it up: build and test it before using
it on a live site. A Vercel OIDC federated credential is the other route, also not set up here.
