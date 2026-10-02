# For the Microsoft 365 administrator

Someone in your organisation is adding Microsoft sign-in to a website with this skill. You may be
asked to run a step, or to grant a role for one. This page says what each step needs, what it
creates, and how to check or remove it yourself.

```mermaid
flowchart LR
  L["Look<br/>read only"] --> G["Groups"] --> A["App registrations<br/>and secrets"] --> E["Enterprise apps,<br/>assignment, consent"] --> C["MFA policy<br/>only on a yes"]
```

Every step prints its exact commands first and runs only after a yes from the person doing the
setup. You can read the plan before anything changes.

## Least role per step

| Step | Least role | What it does |
|---|---|---|
| Look | any member | reads the tenant id, verified domains, licences, security defaults, existing MFA policies and names already taken; writes nothing. Reads a member cannot make are reported as refused; Global Reader sees them all |
| Groups | Groups Administrator | creates the sign-in group, and the administrators group if site roles live in Entra; adds the first members and two owners to a group it creates. A group you pick is used as it is: no members or owners added |
| App registrations and secrets | Application Developer | one registration per environment, each with its own client secret. The creator becomes an owner. Not needed if your tenant lets members register apps |
| Enterprise apps, assignment, consent | Cloud Application Administrator | sets assignment required, assigns the group (or each person, without P1), grants tenant-wide consent for `openid`, `profile` and `email` only. Without P1, removing someone from the group does not remove their assignment until the `sync-assignments` step runs again |
| MFA policy | Conditional Access Administrator | only if the site owner says yes; covers only this site's apps and this site's groups (the sign-in group, and the administrators group when site roles live in Entra, since that group can sign in too), with no exclusions; report-only first |
| Mailbox reader | Exchange Administrator | only if asked for; read-only Exchange access to named mailboxes; no Microsoft Graph permission |

The skill never asks for Global Administrator or Privileged Role Administrator.

## Licences

| Licence | Needed for | Without it |
|---|---|---|
| Entra ID P1 (or Microsoft 365 Business Premium, E3, E5) | assigning a group to the app; the MFA policy | the group becomes a roster and each person is assigned to the app directly; no site MFA policy (security defaults still apply if on) |
| Entra ID P2 | nothing | |
| Exchange Online | the mailbox reader only | no reader |

## What it creates

Every object carries the site's name. Groups and apps it creates also carry the marker
`entra-id-auth:<domain>` in their description or notes, where `<domain>` is the site's address.
The MFA policy carries no marker: it is recognised by the policy id kept in the site's setup record.

| Object | Name | Marker in | When |
|---|---|---|---|
| Sign-in security group | `<Site>` | description | unless an existing group is chosen; static, security, not mail-enabled |
| Administrators group | `<Site> Administrators` | description | only if site roles live in Entra. With P1, anyone added to it can sign in and is a site administrator at their next sign-in, even if they are not in the sign-in group. Without P1, each administrator is assigned to the app directly, so a change to this group applies only after the `sync-assignments` step runs again; to remove an administrator at once, also take them off the site's own list |
| App registration, production | `<Site>` | notes | always; single tenant, exact https redirect addresses |
| App registration, local | `<Site> (local)` | notes | always; localhost only |
| App registration, preview | `<Site> (preview)` | notes | only for one stable preview address |
| Client secret | one per registration | | always; 11 months by default, 12 at most |
| Enterprise app | one per registration, same name | notes | always; assignment required |
| App role `Administrator` | on each sign-in registration (production, local, preview), same role id | | only if site roles live in Entra |
| Conditional Access policy | `<Site>: require MFA` | none; recognised by the policy id in the setup record | only on a yes; report-only until switched on |
| Reader app | `<Site> server reader` | notes | only if the server reads named mailboxes; certificate, no secret |

An existing group chosen by the site owner is used as it is: its description, members and owners
are never changed.
An object with the same name but without this site's marker stops the run.

## What it never does

| Never | |
|---|---|
| Deletes a tenant object | a `teardown` step only prints the commands |
| Turns off security defaults, or changes a tenant-wide policy | it reports what already applies |
| Registers a wildcard or http redirect address | localhost excepted, for the local registration |
| Asks for more than `openid`, `profile` and `email` for sign-in | |
| Adds group claims to the token | membership is checked on the server |
| Prints, logs or commits a secret | secrets go to owner-only files and to Vercel |
| Lists people by name in its output | counts only |
| Takes over an object it did not make | stops and asks |

## Review it by hand

In the Microsoft Entra admin center ([entra.microsoft.com](https://entra.microsoft.com)). Menu names
move over time; the search box finds each page.

| To check | Where |
|---|---|
| The groups, members and owners | Groups > All groups > search `<Site>` > Members, Owners, Properties (description) |
| The registrations, redirect addresses, secrets | App registrations > All applications > search `<Site>` > Authentication; Certificates & secrets |
| Who can sign in | Enterprise applications > search `<Site>` > Properties (Assignment required: Yes) > Users and groups |
| Consent | Enterprise applications > `<Site>` > Security > Permissions (three delegated scopes) |
| Sign-ins | Enterprise applications > `<Site>` > Activity > Sign-in logs |
| The MFA policy | Conditional Access > Policies > `<Site>: require MFA` (Report-only or On) |
| The reader's mailbox access | Exchange Online PowerShell: `Get-ManagementRoleAssignment -RoleAssigneeType ServicePrincipal` |

## Remove it by hand

Remove in this order, so nothing is left pointing at a deleted object:

| # | Remove | Where | Note |
|---|---|---|---|
| 1 | The MFA policy | Conditional Access > Policies > `<Site>: require MFA` > Delete | |
| 2 | The reader's Exchange access | Exchange Online PowerShell: `Remove-ManagementRoleAssignment`, then `Remove-ManagementScope` and `Remove-ServicePrincipal` | only if a reader was made |
| 3 | The enterprise apps | Enterprise applications > `<Site>` > Properties > Delete | one per registration |
| 4 | The app registrations | App registrations > `<Site>` > Delete | restorable for 30 days from Deleted applications |
| 5 | The groups | Groups > `<Site>` > Delete | only groups this skill created; a deleted security group cannot be restored |

The site owner can also run the skill's `teardown` step, which prints these commands for one site
in this order. It never runs them.

The Vercel settings and the site's code belong to the site owner, not to the tenant.

## Renewals

| Credential | Lasts | Warning | Renew |
|---|---|---|---|
| Client secret, each registration | 11 months by default | site administrators see a notice 30 days before; a daily check logs it | the skill's `secret` step adds a new secret; the Vercel settings are updated; the site is redeployed and a sign-in checked; then the old secret is removed under Certificates & secrets |
| Reader certificate | one year (self-signed) | same notice | a new certificate is added, then the old one removed |

Who can renew: either owner of the app registration, or a Cloud Application Administrator. Each
secret's end date is recorded in the site's setup record and in its Vercel settings.

If a secret expires, sign-in stops for that environment until a new one is set. Nothing else in
the tenant is affected.
