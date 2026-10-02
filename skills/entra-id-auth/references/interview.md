# The interview

Nineteen questions in four rounds. Most are answered by detection and only shown back as a
confirmation. Ask one round at a time, in plain words, with no variable names in what the person
reads.

| Round | Questions | About |
|---|---|---|
| 1. Where | Q1 to Q5 | the tenant, the domains, the site's name and address (Q17 comes first when the folder is not linked to a Vercel project) |
| 2. Who | Q6 to Q11 | who may sign in, owners, administrators, where roles live |
| 3. What it does | Q12 to Q14 | the second sign-in step, session length, reading mail on the server |
| 4. Where it runs | Q15 to Q19 | previews, the test lane, Vercel (Q17), the database, the setup record |

## How every question is asked

- A title in plain words, then three short lines: **Why we ask**, **What it is about**, **What the
  answer gives us**.
- Choices, with the recommended one marked, and a blank: "In your own words: ____".
- **Who else could answer**: the person who could, if the one at the keyboard cannot.
- A question that detection already answered is shown as "Found: `<value>`. Right? (yes / change)".
  The line **Skipped when** names that detection.
- Answers go into `~/.config/<slug>/entra-site.env` only after the summary screen's one yes.

## Detected first (read only, never asked)

| Value | How |
|---|---|
| Tenant id and name, signed-in admin | `az account show`, Graph `/organization` |
| Verified domains, the default one | Graph `/organization?$select=verifiedDomains` |
| The admin's directory roles | Graph `/me/memberOf` (directory roles) |
| Entra ID P1 or P2 present | Graph `/subscribedSkus`, a service plan `AAD_PREMIUM*` |
| Security defaults on | Graph `/policies/identitySecurityDefaultsEnforcementPolicy` |
| An existing tenant-wide MFA policy | Graph `/identity/conditionalAccess/policies` (when readable) |
| Names already taken (apps, groups, policy), and whether each carries this site's marker | Graph filters on `displayName` |
| A picked group's members, counted the way setup lists them (Q7) | Graph `/groups/<id>/members/microsoft.graph.user?$select=id,accountEnabled,userType,mail,userPrincipalName&$top=999`, every page: enabled members, guests, and addresses off Q2's domains, each counted; plus `/groups/<id>/members/microsoft.graph.group?$select=id` for nested groups. The exact command: `bash <skill>/scripts/preflight.sh --group <id>` prints the counts and the Q7 sentence; by hand: [site-config.md](site-config.md), Look up |
| Site stack | `detect-site.sh`: Next version, router, ORM, drivers, auth libraries, Node, tsconfig alias, `.env.local` ignored |
| Vercel team, project, `.vercel.app` host | `.vercel/project.json`, `vercel whoami`, `vercel project ls` |
| Domains on this project (Q4, Q5), and its `.vercel.app` host | `vercel api /v9/projects/<projectId from .vercel/project.json>/domains` (a read). `vercel domains ls` lists every domain in the team, not only this project's: context, never a Q4 or Q5 skip |
| Database already on the project | `vercel env ls` (names only, never values) |
| Site repo visibility | `gh repo view --json visibility` when available; else unknown |

## Round 1: Where

### Q1. Is this your organisation: `<tenant name>`, `<default domain>`?

- **Why we ask:** everything this setup creates lives in one Microsoft 365 tenant.
- **What it is about:** the tenant the Azure CLI is signed in to right now.
- **What the answer gives us:** the tenant every later step is pinned to; any other is refused.

| Choice | |
|---|---|
| Yes, this one (recommended) | `TENANT_ID` = the signed-in tenant |
| No, another one | stop; the person signs in to the right tenant (`az login --tenant <domain> --allow-no-subscriptions`), then step 1 runs again |
| In your own words: ____ | |

- **Who else could answer:** the Microsoft 365 administrator.
- **Skipped when:** never skipped; always shown as a confirmation.
- **Sets:** `TENANT_ID`.

### Q2. Which email domains may people use?

- **Why we ask:** the first administrator and everyone added must be on a domain your organisation
  owns.
- **What it is about:** the verified domains in Microsoft 365.
- **What the answer gives us:** the list every address is checked against.

| Choice | |
|---|---|
| All verified domains except `*.onmicrosoft.com` (recommended) | |
| Only the default domain | |
| In your own words: ____ | a comma list of verified domains |

When the tenant has no domain but its `*.onmicrosoft.com` one, show it as the default instead:
"Found: `<tenant>.onmicrosoft.com` (your tenant has no other domain). Right? (yes / change)". The
list is never empty: every script refuses an empty one before it reads or writes anything.

- **Who else could answer:** the Microsoft 365 administrator.
- **Skipped when:** the tenant has one verified domain besides `*.onmicrosoft.com`, or none besides
  it (then that one, shown as a confirmation).
- **Sets:** `EMAIL_DOMAINS`.

### Q3. What is the site called?

- **Why we ask:** the name shows on the sign-in page, the Microsoft consent screen and the tile in
  My Apps, and it names every object created.
- **What it is about:** the name people will see.
- **What the answer gives us:** the display name of the group, the app registrations and the
  enterprise apps, and a short lower-case slug for files.

| Choice | |
|---|---|
| `<Detected name>` (recommended: the Vercel project or `package.json` name, in title case) | |
| In your own words: ____ | |

- **Who else could answer:** the site owner.
- **Skipped when:** never; the detected name is offered as the default.
- **Sets:** `SITE_TITLE`, `APP_NAME`, `SITE` (the slug), `GROUP_NICK`.

### Q4. What is the production address?

- **Why we ask:** Microsoft sends people back to one exact address, and the cookie and the trusted
  origin name it too.
- **What it is about:** the host people type to reach the live site, with no `https://`.
- **What the answer gives us:** the address every registration and the code are pinned to.

| Choice | |
|---|---|
| `<detected custom domain>` (recommended when there is one) | |
| `<project>.vercel.app` | when the site has no custom domain yet; then `VERCEL_HOST` stays empty (no redirect is written) |
| In your own words: ____ | |

- **Who else could answer:** whoever manages the site's DNS.
- **Skipped when:** the project's own domains (not the team's list) hold exactly one custom domain
  that Vercel has verified, and no wildcard stands in for it; shown as a confirmation. Not skipped
  when the folder is not linked, the read fails, or the only custom domain is attached but not yet
  verified (say so: whoever manages DNS has to finish it). When the folder is not linked, Q17 is
  asked first (right before this question) so that Q4 and Q5 name a real project; then run
  `bash <skill>/scripts/preflight.sh --vercel-project <Q17's project> --vercel-scope <its team>`
  to read that project's own domains, and decide Q4 and Q5 as for a linked folder.
- **Sets:** `DOMAIN`, and `VERCEL_HOST` (the `.vercel.app` host in the project's own domains;
  `<project>.vercel.app` only when that read is not available). When `DOMAIN`
  is the `.vercel.app` host, `VERCEL_HOST` stays empty: the same host in both stops every script,
  and control C24 reads N/A.

### Q5. Add `<DOMAIN>` to the Vercel project now?

- **Why we ask:** the address must serve the site before Microsoft can send anyone back to it.
- **What it is about:** running `vercel domains add` for you.
- **What the answer gives us:** permission for that one write, or a note that DNS is handled elsewhere.

| Choice | |
|---|---|
| Yes (recommended) | runs `vercel domains add <DOMAIN>` in step 5, on its own yes |
| No, I will add it | recorded OPEN |
| In your own words: ____ | |

- **Who else could answer:** whoever manages the site's DNS.
- **Skipped when:** the project's own domains already hold it as a verified production address, or
  `DOMAIN` is the `.vercel.app` host. A domain the team owns but this project does not have is
  asked: `vercel domains ls` is not the project's list. Attached but not verified: tell the person
  (DNS is theirs to fix) and treat Q5 as no. A redirect or branch domain: tell the person and let
  them choose.
- **Sets:** nothing in the file; a step in the plan.

## Round 2: Who

Open the round with the first half of Q10: "Who is the first administrator of the site?" Ask for
their work address, and their name as the site should show it (offer the display name that
`az ad user show` returns). Q6, Q7 and Q9 name that person in their choices, so show them with the
address filled in. When the round reaches Q10, only the second half is asked: any other
administrators. The first administrator is never asked twice.

### Q6. Who may sign in: a new group, or one you already have?

- **Why we ask:** Microsoft lets only the members of one security group through to this site.
- **What it is about:** whether this setup creates that group or uses an existing one.
- **What the answer gives us:** the group, and how it reaches the app.

| Choice | |
|---|---|
| A new group named `<Site>` (recommended) | `GROUP_NAME` |
| An existing group: `<name or id>` | `GROUP_ID`; checked for shape; never renamed or re-described, and no members or owners are added to it. The administrators (Q10) must already be members: add them yourself, or let the setup make a new group |
| In your own words: ____ | |

When the person names an existing group by name, find its id first
([site-config.md](site-config.md), Look up, "An existing group's id"); more than one hit: say how
many and ask which one, by id. Then check it now (`bash <skill>/scripts/preflight.sh --group <id> --domains <Q2's answer, comma list> --admins
<the first administrator>`, the read in "Detected first"; Q7 uses the same counts). When Q10 later
adds administrators, run it again with all of them in `--admins`. The group step refuses a group
that is not a plain security group, one that holds any nested group, one that holds any guest,
enabled or disabled, while guests are not allowed, and one an administrator is not in. Preflight
prints a "for Q6, say" line for each; say it here, before Q7 and Q8, only when preflight prints it
(ask Q8 now when the guest line offers it):

- Type: "This group is a Microsoft 365, mail-enabled or dynamic group. It cannot be used: pick a
  security group, or let the setup make a new group." (When its type could not be read, preflight
  adds "(or it could not be checked)" after "dynamic group".) Microsoft 365 groups are what a Team
  makes, so this one is common.
- Guests: "This group holds `<g>` guest(s). With guests not allowed (recommended), it cannot be used:
  allow guests (Q8 yes, asked now), remove them from the group, or let the setup make a new group."
  (At Q11 preflight prints it only while Q8 is no, and without "asked now".)
- Administrators: "`<k>` administrators are not in this group yet: add them to it yourself, or let
  the setup make a new group." With one: "1 administrator is not in this group yet: add them to it
  yourself, or let the setup make a new group."
- Nested groups: "This group holds other groups inside it. It cannot be used as it is: add those
  people directly, or let the setup make a new group." (When the nested groups could not be read,
  preflight adds "(or they could not be checked)" after "inside it".) Microsoft does not honour a
  nested group's members for sign-in, which is why.

A count that could not be read is not a 0: count again before going on.

Without Entra ID P1 a group cannot be assigned to an app. Then say so and offer: (a) get P1 first,
or (b) the roster path (`ASSIGNMENT_MODE=direct`): the group is still the list of who may sign in,
and the `sync-assignments` step assigns each member to the app directly. Say this part in these
words: "Without P1, removing someone from the group does not stop them until someone runs
sync-assignments again. To remove someone at once, take them off the site's list too."

When preflight could not read the licence list (P1 unknown), say so and ask the Microsoft 365
administrator. Until they confirm P1, take the roster path (`ASSIGNMENT_MODE=direct`): it works
with or without P1.

- **Who else could answer:** the Microsoft 365 administrator.
- **Skipped when:** never.
- **Sets:** `GROUP_ID` or `GROUP_NAME`; `ASSIGNMENT_MODE` (`group` with P1, `direct` without).

### Q7. Who are the first members?

- **Why we ask:** they need to be in the group, and on the site's own list, to get in on day one.
- **What it is about:** work addresses of the people who should sign in first.
- **What the answer gives us:** the starting roster; it is also written to `people.json` to seed the
  site.

| Choice | |
|---|---|
| Just the first administrator (Q10) (recommended) | |
| These addresses: ____ | a comma list |
| In your own words: ____ | |

When Q6 picked an existing group, use the counts from Q6, then ask this instead: "This group has
`<n>` enabled people who can go on the site's list (`<o>` addresses off your email domains are left
off unless guests are allowed, Q8). With the default setting, the site lets in only people on its
own list. Put them all on the list now?" Leave out the bracket when `<o>` is 0, and say "1 enabled
person" for a count of 1. When Q8 is already yes (from Q6), `<n>` includes the enabled guests and
the off-domain members, and the bracket is left off; say instead how many of them are guests and
how many are off your domains, as preflight's "among them" part does. Preflight's "for Q7" line
gives these counts; the question asked is the one here.

Preflight counts against Q2's answer when given `--domains`; without it (and before
`entra-site.env` exists) it counts against every verified domain except `*.onmicrosoft.com`, and says
so. After the summary's yes, `preflight.sh --site <slug>` counts the group again against the recorded
domains and the recorded Q8 (`ALLOW_GUESTS`): with guests allowed, its `<n>` takes in the enabled
guests and the off-domain members, with no bracket, and matches the roster `tenant-setup.sh --site
<slug> plan group` prints. When that `<n>` differs from the one in the summary, tell the person the
new number before any write.

| Choice | |
|---|---|
| Yes, all `<n>` of them (recommended) | `LIST_GROUP_MEMBERS=all`: the `group` step reads the group's user members into `people.json` |
| Only the administrators | `LIST_GROUP_MEMBERS=admins`: every other member is refused by the site until an administrator adds them |
| Add each member on their first sign-in | `LIST_GROUP_MEMBERS=admins` and `JOIN_MODE=group`, after its warning (defaults, below) |
| In your own words: ____ | |

- **Who else could answer:** the site owner.
- **Skipped when:** never. For a new group it asks for addresses; for an existing group, the
  question above.
- **Sets:** `MEMBERS` (new group), or `LIST_GROUP_MEMBERS` (existing group; required then).

### Q8. May guests sign in?

- **Why we ask:** guests are people from outside your organisation's own accounts.
- **What it is about:** whether a guest account in the group is allowed.
- **What the answer gives us:** whether setup accepts guest addresses, whether the site lets one join,
  and how control M16 reads.

| Choice | |
|---|---|
| No (recommended) | setup refuses guest addresses; a guest in the group fails M16; the site refuses a first sign-in from any address outside Q2's domains, even when members join on first sign-in |
| Yes | M16 reads PASS (decided) and reports the count; the site may add a guest who joins on first sign-in |
| In your own words: ____ | |

- **Who else could answer:** the Microsoft 365 administrator.
- **Skipped when:** never.
- **Sets:** `ALLOW_GUESTS`.

### Q9. Who are the two owners of everything this setup creates?

- **Why we ask:** if the only owner leaves, nobody can fix or remove the group or the apps.
- **What it is about:** two people responsible for the group, the registrations and the enterprise
  apps.
- **What the answer gives us:** the owners written onto every object.

| Choice | |
|---|---|
| You (`<signed-in admin>`) and the first administrator (Q10) (recommended) | |
| These two: ____ | |
| In your own words: ____ | |

If the two are one person, ask for a second.

- **Who else could answer:** the Microsoft 365 administrator.
- **Skipped when:** never; shown with the default filled in.
- **Sets:** `OWNERS`.

### Q10. Any other administrators?

The first administrator was asked at the top of this round. Show it as "First administrator:
`<address>`" and ask only about others.

- **Why we ask:** nobody can sign in until at least one person is on the site's own list as
  administrator, and one alone is a single point of failure.
- **What it is about:** the people who manage the site itself once it is live.
- **What the answer gives us:** the first row on the site's list, and any further administrators.

| Choice | |
|---|---|
| No, just `<address>` (recommended) | |
| These too: ____ | a comma list |
| In your own words: ____ | |

- **Who else could answer:** the site owner.
- **Skipped when:** never (the first half is asked at the top of the round, the second half here).
- **Sets:** `FIRST_ADMIN`, `FIRST_ADMIN_NAME`, `EXTRA_ADMINS`.
- **Then, when Q6 picked an existing group:** run `bash <skill>/scripts/preflight.sh --group <id>
  --domains <Q2> --admins <the first administrator and these, comma list>` now, and say any
  "for Q6" line before Q11.

### Q11. Where should "who is an administrator" live?

- **Why we ask:** it decides who manages administrators and how fast a removal takes effect.
- **What it is about:** a table in the site's database, or a second Entra group with an app role.
- **What the answer gives us:** which one the code reads.

| Choice | |
|---|---|
| The site's own list (recommended) | every change records who made it; applies on the next click |
| A new Entra group, `<Site> Administrators` | IT manages it in Entra; read from the sign-in token. With P1, a change applies at the next sign-in. Without P1, see below |
| An existing Entra group: `<name or id>` | `ADMIN_GROUP_ID`; checked for shape; never renamed or re-described, and no members or owners are added to it. The administrators (Q10) must already be members: add them yourself, or let the setup make a new group |
| In your own words: ____ | |

With either Entra group and P1, say this in these words before the person picks it: "Anyone added
to the administrators group in Entra can sign in to this site, even if they are not in the sign-in
group, and becomes a site administrator at their next sign-in. Only people who may manage the site
belong in it, and each of them must also be in the sign-in group." The setup checks that last part:
it stops when an administrator is outside the sign-in group, and the MFA policy (Q12) covers both
groups.

Without P1 (the roster path, Q6), the administrators group is not assigned to the app: each
administrator gets the Administrator role directly, and only `sync-assignments` changes that. Say
this instead, in these words: "Without P1, a change to the administrators group applies only after
someone runs sync-assignments. To remove an administrator at once, take them off the site's list
too."

When the person names an existing group, find its id as in Q6, then check it now, before Q12:
`bash <skill>/scripts/preflight.sh --admin-group <id> --domains <Q2's answer> --admins <the first
administrator and Q10's others, comma list>`. It prints the same type, guest, nested-group and
administrators lines as Q6, headed "for Q11, say", and no Q7 line: say each one it prints. It
must also differ from Q6's group.

- **Who else could answer:** the Microsoft 365 administrator.
- **Skipped when:** never.
- **Sets:** `ROLE_SOURCE` (`site` or `entra`); with `entra`, `ADMIN_GROUP_NAME` or `ADMIN_GROUP_ID`.

## Round 3: What it does

### Q12. Should people confirm each sign-in with a second step?

- **Why we ask:** it changes how everyone signs in to this site, so it is your call.
- **What it is about:** a code or a phone approval on top of the Microsoft password, for this site's
  sign-in only.
- **What the answer gives us:** whether a Conditional Access policy is made for this site.

The policy covers only this site's own apps and its groups (the sign-in group, and the
administrators group when Q11 picked one in Entra), with no exclusions. It never
touches other apps or the admin portals, so it cannot lock anyone out of the tenant.

The choices depend on what preflight found:

| What preflight found | What is offered | Default |
|---|---|---|
| No P1 | no site policy is possible; say whether security defaults are on | nothing to choose |
| P1 unknown (the licence list could not be read) | ask the Microsoft 365 administrator whether the tenant has P1 | no, until they confirm P1; then this question is asked again |
| Security defaults on | no site policy is possible while they are on; this skill never turns them off | nothing to choose |
| A tenant-wide MFA policy already covers these people | "already covered" or a site policy anyway | already covered |
| P1, nothing covers these people | yes (recommended by Microsoft) or no | yes: report-only for a week, then `ca-enable` on its own yes |

Always add "In your own words: ____".

- **Who else could answer:** the Microsoft 365 administrator.
- **Skipped when:** never. With no P1 or security defaults on it is shown as information, and the
  answer is recorded.
- **Sets:** `REQUIRE_MFA` (`yes` only for a site policy; `no` for no, already covered, or not
  possible), `MFA_ANSWERED_BY='<who>, <YYYY-MM-DD>'`.

### Q13. How long may someone stay signed in?

- **Why we ask:** it sets when Microsoft is asked to check the person and the group again.
- **What it is about:** two numbers: how long an idle tab stays signed in, and the longest any
  session lasts.
- **What the answer gives us:** the values in the code and, with MFA, the policy's sign-in frequency.

| Choice | |
|---|---|
| 60 minutes idle, 12 hours at most (recommended) | |
| 30 minutes idle, 8 hours at most | |
| 60 minutes idle, 24 hours at most | |
| In your own words: ____ | idle minutes 15 to 480, less than the cap; the cap 1 to 24 hours |

- **Who else could answer:** the site owner, or the security lead.
- **Skipped when:** never.
- **Sets:** `SESSION_IDLE_MINUTES`, `SESSION_MAX_HOURS`, `SESSION_ANSWERED_BY='<who>, <YYYY-MM-DD>'`.

### Q14. Does the site's server need to read Microsoft 365 mail?

- **Why we ask:** reading a mailbox on the server needs a separate app, a certificate and an
  Exchange administrator.
- **What it is about:** the site itself (not a signed-in person) reading named mailboxes.
- **What the answer gives us:** whether the `reader` steps run, and which mailboxes they reach.

| Choice | |
|---|---|
| No (recommended) | |
| Yes, these mailboxes: ____ | read only; nothing else in the tenant |
| In your own words: ____ | |

- **Who else could answer:** the site's developer.
- **Skipped when:** never.
- **Sets:** `NEEDS_M365_SERVER`, `MAILBOXES`.

## Round 4: Where it runs

### Q15. How should people sign in on preview deployments?

- **Why we ask:** each preview gets a new address on every push, and Microsoft needs every address
  registered in advance.
- **What it is about:** sign-in before a change reaches production.
- **What the answer gives us:** whether a preview-only registration is made.

| Choice | |
|---|---|
| The test sign-in lane only (recommended) | made-up `.invalid` password accounts; no Microsoft sign-in on previews. Previews start with no account: each tester's account is made with `scripts/dev-test-user.ts --preview` against the preview database, which it refuses if that database holds any real person |
| Microsoft sign-in on one stable branch address: ____ | its own registration and secret |
| No sign-in on previews | previews build and deploy; people test sign-in locally |
| In your own words: ____ | |

- **Who else could answer:** the site's developer.
- **Skipped when:** never.
- **Sets:** `PREVIEW_MODE` (`test-lane`, `stable-host`, `none`), `PREVIEW_HOST`.

### Q16. Where may the test sign-in lane run?

- **Why we ask:** a password lane lets testers sign in without a Microsoft account; production never
  has it.
- **What it is about:** local development and previews.
- **What the answer gives us:** where `ALLOW_PASSWORD_SIGNIN` may be true.

| Choice | |
|---|---|
| Local and previews (needed after "test sign-in lane" in Q15) | |
| Local only (recommended after "one stable branch address" or "no sign-in" in Q15) | |
| Off | |
| In your own words: ____ | |

- **Who else could answer:** the site's developer.
- **Skipped when:** Q15 was "test sign-in lane" (then local and previews, shown as a
  confirmation).
- **Sets:** `PASSWORD_LANE` (`local+preview`, `local`, `off`).

### Q17. Which Vercel team and project?

- **Why we ask:** settings are written to exactly one project; the wrong one would change another
  site.
- **What it is about:** the team and project this site deploys from.
- **What the answer gives us:** where every setting is written.

| Choice | |
|---|---|
| `<linked team> / <linked project>` (recommended; only when the folder is linked) | |
| One of the projects preflight listed ("projects you can see") | when the folder is not linked: linked in step 5, on a yes |
| Another: ____ | linked in step 5, on a yes; a project that does not exist yet is made in Vercel first |
| In your own words: ____ | |

- **Who else could answer:** the site's developer.
- **Skipped when:** the folder is linked (`.vercel/project.json` names the team and project);
  shown as a confirmation. When it is not linked, ask it in Round 1, before Q4 and Q5.
- **Sets:** `VERCEL_SCOPE`, `VERCEL_PROJECT`, `VERCEL_HOST` (left empty when Q4's address is the
  `.vercel.app` host).

### Q18. Where does the database live?

- **Why we ask:** the people list and every session are stored in Postgres.
- **What it is about:** the production and preview databases.
- **What the answer gives us:** where `DATABASE_URL` comes from.

| Choice | |
|---|---|
| The one already on the project (recommended when found) | |
| A new Neon database through the Vercel Marketplace (recommended otherwise) | free plan; the first time, you accept the Marketplace terms yourself |
| My own Postgres: I will put its address in a private file | |
| In your own words: ____ | |

- **Who else could answer:** the site's developer.
- **Skipped when:** never; shown as a confirmation when one is found.
- **Sets:** `DB_SOURCE` (`existing`, `neon`, `other`).

### Q19. Keep the setup record in the site's repository?

- **Why we ask:** the record holds the tenant id and the owners' addresses; a public repository
  would publish them.
- **What it is about:** the one file that says what was created, when, and when it expires.
- **What the answer gives us:** where the record is written.

| Choice | |
|---|---|
| Yes, in `docs/auth/entra-record.md` (recommended when the repository is private) | |
| No, on this computer in `~/.config/<slug>/` (recommended when public or unknown) | |
| In your own words: ____ | |

- **Who else could answer:** the site's developer.
- **Skipped when:** never; the default follows the detected visibility.
- **Sets:** `RECORD_IN_REPO`.

## Shown as defaults, not asked

Listed on the summary screen; changed only if the person asks.

| Key | Default | Note |
|---|---|---|
| `SECRET_MONTHS` | 11 | 1 to 12; Microsoft advises under 12 |
| `LOCAL_PORT` | 3000 | `.env.local`'s `BETTER_AUTH_URL` names it |
| `LOCAL_DATABASE_URL` | `postgres://localhost:5432/<slug>` | this machine only; never `[::1]`. Connects as the OS user with no password; when the server does not accept that (a Linux package makes only the `postgres` role), write `postgres://<user>:<password>@localhost:5432/<slug>` |
| `LIST_GROUP_MEMBERS` | all | set by Q7 and required when a group is picked by id; ignored for a new group |
| `HIDE_FROM_MY_APPS` | no | yes hides the tile in My Apps |
| `JOIN_MODE` | listed | a group member not on the site's list is refused |

`JOIN_MODE=group` adds a group member to the site's list on their first sign-in. Warn before
accepting it: "Then anyone a Groups Administrator adds to the group can use the site, with no one
at the site agreeing. With guests allowed (Q8), that includes people from other organisations."
With an administrators group in Entra (Q11) and P1, add: "The same goes for the administrators
group: anyone added to it gets in as a site administrator, with no one at the site agreeing, even if
they are not in the sign-in group." (Without P1 the administrators group reaches the app only
through `sync-assignments`, which gives the role only to those also in the sign-in group.) It needs
its own yes after that warning.

## Validation, before any write

Any failure reopens that question. Two passes:

- **Before the summary**, every check that is a read: each address resolves (`az ad user show`),
  and a picked group gets preflight's lines at Q6 and Q11 (type, guests, nested groups,
  administrators not in it), and again at Q10 for Q6's group, with every administrator in
  `--admins`. The rest of this list the agent checks from the answers themselves.
- **After the summary's yes**, `tenant-setup.sh --site <slug> plan` (SKILL.md step 3) needs
  `entra-site.env`, so it runs then. It checks the same things again, plus the roster resolved to
  object ids and the owners. A STOP there reopens only that question; its new answer goes on a new
  summary, and that yes rewrites `entra-site.env`. Nothing in the tenant, Vercel, the database or
  the site is written until both passes are clean.

In the full plan, a later step that only waits on an id an earlier step of the same plan makes (no
`GROUP_ID`, `ADMIN_GROUP_ID` or enterprise app recorded yet) is not a failure and reopens nothing.

- Every address resolves (`az ad user show`) to an enabled member account; a guest only when Q8 is
  yes.
- Every administrator address (Q10) is on a domain in `EMAIL_DOMAINS`; setup refuses one that is
  not. A member (Q7) off those domains reopens Q7 when Q8 is no. When Q8 is yes it is allowed: the
  plan warns, and seeding (SKILL.md step 7.4) adds `--allow-other-domains`.
- The two owners are two different people, compared ignoring case.
- An existing group (Q6, Q11) is security-enabled, not mail-enabled, not a Microsoft 365 group, not
  dynamic, has no nested groups, and holds no guests, enabled or disabled, when Q8 is no. A count
  that could not be read fails too: rerun the plan, and say the count was not read, not that the
  group holds them.
- An existing sign-in group (Q6) and an existing administrators group (Q11) are two different
  groups.
- With an existing sign-in group (Q6), the first administrator and every extra administrator are
  already its members; with an existing administrators group (Q11), every administrator is a member
  of it too. The plan reports each as a count; one missing reopens the question.
- Hosts (`DOMAIN`, `VERCEL_HOST`, `PREVIEW_HOST`) are lower case, with no scheme, no path, no port
  and no wildcard.
- `VERCEL_HOST` differs from `DOMAIN`. When `DOMAIN` is the `.vercel.app` host, `VERCEL_HOST` is
  empty.
- `PREVIEW_HOST` differs from both `DOMAIN` and `VERCEL_HOST`.
- Every `EMAIL_DOMAINS` entry is a bare host (lower case, no `@`, no scheme), and the list is never
  empty.
- The slug matches `^[a-z0-9][a-z0-9-]*$`.
- `SESSION_IDLE_MINUTES` is 15 to 480, `SESSION_MAX_HOURS` is 1 to 24, and the idle minutes are
  less than the absolute cap.
- `SECRET_MONTHS` is 1 to 12.
- `MFA_ANSWERED_BY` and `SESSION_ANSWERED_BY` say who and when: letters, digits, spaces and
  `. , - ( ) @ ' :` only.
- `PREVIEW_MODE=stable-host` has a `PREVIEW_HOST`; `PREVIEW_MODE=test-lane` needs
  `PASSWORD_LANE=local+preview` (the reverse is allowed).

What is reported back: counts, never lists of names.

## The summary screen

Fill this in and show it as one message. One yes writes `entra-site.env`.

```text
Setting up Microsoft sign-in for <SITE_TITLE>

Where
  Q1  Organisation       <tenant name> (<default domain>)             found
  Q2  Email domains      <n> domains                                  found | you
  Q3  Site name          <SITE_TITLE>  (slug <SITE>)                  found | you
  Q4  Address            https://<DOMAIN>   also <VERCEL_HOST> (none when DOMAIN is it)   found | you
  Q5  Add the domain     yes | no | already there

Who
  Q6  Sign-in group      new "<GROUP_NAME>" | existing (<id>)         assigned by group | directly (no P1: rerun sync-assignments after every change to either group)
  Q7  First members      <n> people | all <n> enabled group members (<o> off your domains left off; none when Q8 is yes) | administrators only | join on first sign-in
  Q8  Guests             no | yes
  Q9  Owners             2 people
  Q10 Administrators     1 first administrator + <n> more
  Q11 Roles live in      the site's list | new Entra group "<ADMIN_GROUP_NAME>" | existing Entra group (<id>)

What it does
  Q12 Second step        yes, report-only first | no | already covered | not possible (<why>)
  Q13 Session            <idle> minutes idle, <max> hours at most
  Q14 Server reads mail  no | <n> mailboxes

Where it runs
  Q15 Previews           test lane | <PREVIEW_HOST> | none
  Q16 Test lane          local and previews | local | off
  Q17 Vercel             <team> / <project>
  Q18 Database           existing | new Neon | your own
  Q19 Setup record       in the repo | on this computer

Defaults: secret 11 months, local port 3000, local database postgres://localhost:5432/<slug>,
tile shown in My Apps, only listed people get in.

What will be created (each step still asks before it runs)
  Entra:   <n> groups, <n> app registrations, <n> enterprise apps, <n> client secrets,
           <0|1> Conditional Access policy, <0|1> reader app
  Vercel:  <n> settings across production, preview and local; <domain>; <database>
  Site:    <n> new files, <n> files to merge

Write these answers? (yes / change something)
```
