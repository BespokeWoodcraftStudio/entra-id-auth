# The site's config file

`~/.config/<slug>/entra-site.env` on the machine doing the setup. It holds the interview's answers
and nothing secret. It is the one contract between the interview, the scripts and the templates.
`entra-state.env` beside it holds the ids the steps create. Both are owner-only (`chmod 600`) and
never committed. The questions that fill it: [interview.md](interview.md).

## File rules

The scripts source it as shell. So:

- Free text (a name, a list) goes in single quotes. A `'` inside is written `'\''`.
- Ids (`TENANT_ID`, `GROUP_ID`, `ADMIN_GROUP_ID`) are GUIDs; the scripts refuse anything else and
  lower-case them.
- Only this file decides: a setting left in the shell's environment (for example `REQUIRE_MFA`) is
  ignored.
- `DOMAIN`, `VERCEL_HOST`, `PREVIEW_HOST` are bare lower-case host names: no `https://`, no path,
  no port, no wildcard.
- Lists (`EMAIL_DOMAINS`, `MEMBERS`, `OWNERS`, `EXTRA_ADMINS`, `MAILBOXES`) are comma separated,
  with no spaces.
- It is written once, after the summary screen's yes. A later change is made in the file, then the
  step it affects is planned and run again.

## Look up, never ask

| Value | How |
|---|---|
| Tenant id, signed-in admin | `az account show --query "{tenant:tenantId,user:user.name}"` |
| Tenant name and verified domains | `az rest --method get --url "https://graph.microsoft.com/v1.0/organization?\$select=displayName,verifiedDomains"` |
| The admin's directory roles | `az rest --method get --url "https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?\$select=displayName"` |
| Entra ID P1 or P2 | `az rest --method get --url "https://graph.microsoft.com/v1.0/subscribedSkus"`, any enabled service plan named `AAD_PREMIUM*` |
| Security defaults | `az rest --method get --url "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy" --query isEnabled` |
| A tenant-wide MFA policy | `az rest --method get --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies"`: an enabled policy granting `mfa` to all users, or to a group holding these people (needs a Conditional Access reader role; a refusal means unknown) |
| Owners (default) | the signed-in admin and the first administrator; asked again if they are one person |
| Vercel team and project, `.vercel.app` host | `.vercel/project.json`, `vercel whoami`, `vercel project ls` |
| Domains on the project, and its `.vercel.app` host | `vercel api /v9/projects/<projectId from .vercel/project.json>/domains --scope <team>` (a read); an unlinked folder: `preflight.sh --vercel-project <name> --vercel-scope <team>` once Q17 is answered |
| Domains in the team (not all on this project; context only) | `vercel domains ls` |
| A database already on the project | `vercel env ls` (names only: `DATABASE_URL`, `POSTGRES_URL`) |
| Site repo visibility | `gh repo view --json visibility -q .visibility` |
| An existing group's id, from its name (Q6, Q11) | `az ad group list --display-name "<name>" --query "[].{id:id,mail:mailEnabled,sec:securityEnabled}" -o tsv`: one line per group of that name. More than one: say how many, and ask which one, by id |
| An existing group's shape | `az ad group show --group <id> --query "{sec:securityEnabled,mail:mailEnabled,types:groupTypes}"` |
| A picked group's members, counted as setup lists them (Q7) | `bash <skill>/scripts/preflight.sh --group <id>` (add `--site <slug>` once the file exists, so it counts against `EMAIL_DOMAINS`), or the block below the table: counts only, never a name or an address |
| A person's object id | `az ad user show --id <address> --query id -o tsv` |

A picked group's members (Q7), by hand, when preflight cannot run. `<id>` is the group, `<domains>` is `EMAIL_DOMAINS`. It prints three
counts: enabled members on those domains (the `<n>` that goes on the list), enabled guests, and
enabled members off those domains. With guests allowed (Q8 yes), the other two go on the list too:
add them to `<n>`. Disabled accounts are never listed. The guest check at Q6 counts every guest,
disabled ones too: the second line below. Graph gives at most 999 users a
page: when the same URL with `--query '"@odata.nextLink"'` prints a URL, count that page too and add.

```bash
az rest --method get --url "https://graph.microsoft.com/v1.0/groups/<id>/members/microsoft.graph.user?\$select=id,accountEnabled,userType,mail,userPrincipalName&\$top=999" \
  --query "value[].[accountEnabled, userType, mail || userPrincipalName]" -o tsv \
  | awk -F'\t' -v d=",<domains>," 'tolower($1)!="true"{next} $2=="Guest"{g++; next} {a=tolower($3); sub(/.*@/,"",a); if (index(d, "," a ",")) n++; else o++} END{print "on the list:", n+0, "guests:", g+0, "off your domains:", o+0}'
az rest --method get --url "https://graph.microsoft.com/v1.0/groups/<id>/members/microsoft.graph.user?\$select=id,userType&\$top=999" --query "length(value[?userType=='Guest'])"   # every guest, enabled or disabled (Q6)
az rest --method get --url "https://graph.microsoft.com/v1.0/groups/<id>/members/microsoft.graph.group?\$select=id" --query "length(value)"   # nested groups; setup never reads into them
```

## A full example

Every key. Placeholders only.

```bash
# Where
SITE=contoso-portal                         # slug: ^[a-z0-9][a-z0-9-]*$
SITE_TITLE='Contoso Portal'                 # shown to people
APP_NAME='Contoso Portal'                   # Entra display name (the marker is added to notes, not the name)
DOMAIN=portal.contoso.com                   # production address, no https://
VERCEL_SCOPE=contoso                        # the Vercel team slug
VERCEL_PROJECT=contoso-portal
VERCEL_HOST=contoso-portal.vercel.app       # the project's .vercel.app host; empty when DOMAIN is that host (no custom domain) or when not on Vercel (no redirect is written)
EMAIL_DOMAINS=contoso.com                   # comma list of verified domains
SITE_DIR=<path to the site>
TENANT_ID=                                  # filled from Q1; every tenant script refuses any other tenant

# Who may sign in: an existing group ...
GROUP_ID=                                   # used as is: no members or owners added; the administrators must already be in it
LIST_GROUP_MEMBERS=                         # with GROUP_ID, required: all puts the group's enabled users on the site's list (people.json); admins, administrators only
# ... or a new one
GROUP_NAME='Contoso Portal'
GROUP_NICK=contoso-portal
ASSIGNMENT_MODE=group                       # group (needs Entra ID P1) or direct (no P1: each roster member assigned)
MEMBERS='alex@contoso.com,sam@contoso.com'  # users only; nested groups are not honoured
ALLOW_GUESTS=no                             # no: setup refuses guests, and with JOIN_MODE=group the site refuses an address outside EMAIL_DOMAINS
OWNERS='admin@contoso.com,owner@contoso.com'   # two different people
FIRST_ADMIN=owner@contoso.com
FIRST_ADMIN_NAME='Contoso Owner'
EXTRA_ADMINS=                               # comma list; empty for none

# Roles inside the site
ROLE_SOURCE=site                            # site (the site's own list) or entra (an app role on an admin group)
ADMIN_GROUP_NAME=                           # with entra: 'Contoso Portal Administrators'
ADMIN_GROUP_ID=                             # with entra and an existing group
JOIN_MODE=listed                            # listed, or group (a group member is added on first sign-in; needs its own yes)

# The second sign-in step
REQUIRE_MFA=no                              # yes only on the person's own yes; then the ca step makes the policy
MFA_ANSWERED_BY='<name>, <YYYY-MM-DD>'      # who answered, and when; the scripts refuse it empty or a placeholder

# Session length
SESSION_IDLE_MINUTES=60                     # 15 to 480, less than SESSION_MAX_HOURS
SESSION_MAX_HOURS=12                        # 1 to 24; also the Conditional Access sign-in frequency
SESSION_ANSWERED_BY='<name>, <YYYY-MM-DD>'

# Server-side Microsoft 365 (only if the site reads mail on the server)
NEEDS_M365_SERVER=no
MAILBOXES=                                  # comma list of primary addresses
EXCHANGE_ROLE='Application Mail.Read'       # read only; the scripts refuse anything but "Application <Thing>.Read"

# Where it runs
PREVIEW_MODE=test-lane                      # test-lane, stable-host or none
PREVIEW_HOST=                               # with stable-host: the one branch address
PASSWORD_LANE=local+preview                 # local+preview, local or off; production never; test-lane needs local+preview
DB_SOURCE=neon                              # existing, neon or other
RECORD_IN_REPO=no                           # yes: docs/auth/entra-record.md in the site; no: ~/.config/<slug>/entra-record.md

# Defaults, changed only if asked
LOCAL_PORT=3000
LOCAL_DATABASE_URL=                         # empty = postgres://localhost:5432/<slug> as the OS user; add user:password@ if the server needs it; host localhost or 127.0.0.1, never [::1]
SECRET_MONTHS=11                            # 1 to 12
ADOPT_EXISTING_APPS=no                      # yes only after the person agrees a same-named object without the marker is reshaped
HIDE_FROM_MY_APPS=no
```

## people.json

`~/.config/<slug>/people.json`, owner-only. The `group` and `admin-group` steps write it from the
members they resolved (for a group picked by id with `LIST_GROUP_MEMBERS=all`, its user members too); the site's `scripts/seed-people.ts` reads it in step 7. It holds no secret,
but it is personal data: never committed, never printed.

```json
[
  { "oid": "00000000-0000-0000-0000-000000000001", "email": "owner@contoso.com", "name": "Contoso Owner", "role": "administrator" },
  { "oid": "00000000-0000-0000-0000-000000000002", "email": "alex@contoso.com", "name": "Alex Example", "role": "member" }
]
```

| Field | Meaning |
|---|---|
| `oid` | the Entra object id; the site binds the person by it |
| `email` | the user principal name, lower case |
| `name` | the display name, for the site's list |
| `role` | `administrator` (the first administrator, `EXTRA_ADMINS`, the admin group) or `member` |
