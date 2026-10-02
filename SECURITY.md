# Security policy

This skill writes to a real Microsoft 365 tenant and a real Vercel project when someone runs it on
their own site. A flaw here can open a site to the wrong people, so treat it as a security issue.

## Supported versions

| Version | Supported |
|---|---|
| Latest 1.x release | yes |
| Older 1.x releases | no; update with the two lines below |

```bash
claude plugin marketplace update entra-id-auth
claude plugin update entra-id-auth@entra-id-auth
```

Run both, in that order. The first fetches the new catalog; without it, the second still reports
the old version as the latest. Then start a new Claude Code session, or type `/reload-plugins`.
Without the plugin (a clone): see README, "Without the plugin".

## Reporting a vulnerability

Report it privately through GitHub:

1. Open [github.com/BespokeWoodcraftStudio/entra-id-auth](https://github.com/BespokeWoodcraftStudio/entra-id-auth).
2. Go to the **Security** tab.
3. Choose **Report a vulnerability**.

If that button is missing, open an issue titled "security contact", with no details at all. A
maintainer will reply there with a private way to send the report.

Never put the details of a vulnerability in a public issue, discussion or pull request.

Helpful to include:

- the file (a script, a template, `SKILL.md`) and the line or step
- the exact command or code path
- what a tenant, site owner or visitor would see happen that should not
- never a real secret, tenant id or personal address; use placeholders

## In scope

| In scope | Out of scope |
|---|---|
| `skills/entra-id-auth/SKILL.md` and its `references/` | Microsoft Entra ID, Microsoft Graph and the Azure CLI themselves |
| the scripts in `skills/entra-id-auth/scripts/` | Vercel and the Vercel CLI |
| the code templates in `skills/entra-id-auth/templates/` | Next.js, Better Auth, Drizzle and other libraries |
| this repository's CI and checks | a site's own code that the skill did not write |

Report a flaw in an out-of-scope product to that product's own security contact.

## What to expect

- A reply acknowledging the report once it has been read.
- An assessment, and questions if something is unclear.
- A fix in a new release when the report is confirmed, recorded in `CHANGELOG.md`.
- Credit in the release notes, if you want it.

This is a small open-source project. No response or fix date is promised.
