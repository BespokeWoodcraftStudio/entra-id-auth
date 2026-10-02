# Secrets and settings

`<skill>/scripts/vercel-env.sh --site <slug> plan` shows every line; `run prod`, `run preview`,
`run local` write them, each only on a yes. Every Vercel command carries `--scope <VERCEL_SCOPE>`,
so it reaches the one team the interview named. Values go in on stdin from a file. Nothing is printed, put on a
command line or committed. A run refuses when the site folder is linked to any Vercel project other
than `VERCEL_PROJECT` (`--force` would overwrite that site's secrets), and when an id or date it
needs is not recorded yet (it never writes a placeholder).

The order for the local database: `run local` (SKILL.md step 5) adds `DATABASE_URL` to
`.env.local` when it is missing, then SKILL.md step 6.1 creates and migrates the database that
`DATABASE_URL` names (its commands are there, not repeated here). A `DATABASE_URL` already in `.env.local` is kept when it names this
machine. `.env.local` is read the way Next.js reads it (the last line wins), so every `DATABASE_URL`
line must name this machine; any other host, or a `host=` or `hostaddr=` option, stops the run (plan
says so first), and nothing is written.

## Every setting

| Name | Production | Preview | Local (.env.local) | Kind | Comes from |
|---|---|---|---|---|---|
| `MICROSOFT_ENTRA_TENANT_ID` | yes | only with a preview registration | yes | Config | `az account show` |
| `MICROSOFT_ENTRA_CLIENT_ID` | production app | preview app | local app | Config | the app step |
| `MICROSOFT_ENTRA_CLIENT_SECRET` | production secret | preview secret, or none | local secret | **Sensitive** | the secret step's file |
| `MICROSOFT_ENTRA_CLIENT_SECRET_EXPIRES` | yes | with the preview secret | yes | Config | the secret step (state file) |
| `BETTER_AUTH_SECRET` | its own | its own | its own | **Sensitive** | `openssl rand -base64 48` |
| `BETTER_AUTH_URL` | `https://<domain>` | `https://<PREVIEW_HOST>` with `stable-host`; otherwise unset, and the code uses the branch address (`VERCEL_BRANCH_URL`) | `http://localhost:<LOCAL_PORT>` | Config | the config |
| `AUTH_TRUSTED_ORIGINS` | domain and `.vercel.app` host | preview host | unset | Config | the config |
| `NEXT_PUBLIC_APP_URL` | `https://<domain>` | unset | `http://localhost:<LOCAL_PORT>` | Config | the config |
| `CRON_SECRET` | its own | its own | its own | **Sensitive** | `openssl rand -base64 48` |
| `ALLOW_PASSWORD_SIGNIN` | `false`, always | `true` only with `PASSWORD_LANE=local+preview` | `true` unless `PASSWORD_LANE=off` | Config | `PASSWORD_LANE` |
| `M365_READER_TENANT_ID`, `_CLIENT_ID`, `_MAILBOXES`, `_CERTIFICATE_EXPIRES` | if a reader | no | no | Config | the reader step |
| `M365_READER_CERTIFICATE_PEM` | if a reader | no | no | **Sensitive** | `reader.pem` |
| `DATABASE_URL` | the production database | its own database holding no production rows; never production's, nor a branch copied from it | a local Postgres, written by `run local` | Sensitive where Vercel allows | production and preview, per `DB_SOURCE`: the one already on the project, the Neon integration, or the person's own. Local: `LOCAL_DATABASE_URL` in the config, default `postgres://localhost:5432/<slug>`; the scripts refuse any host but this machine, in the config and in a line already in `.env.local` |

## Where each secret is kept

| Secret | Kept in | Readable by |
|---|---|---|
| Entra client secret (each environment) | `~/.config/<slug>/entra-client-secret-<env>` (0600) and Vercel Sensitive | the setup machine's owner; Vercel functions |
| Better Auth and cron secrets | `~/.config/<slug>/*-secret-<env>` and Vercel Sensitive | same |
| Reader private key | `~/.config/<slug>/reader.key`, `reader.pem`, Vercel Sensitive | same; Microsoft holds only the public certificate |
| Production database URL | `~/.config/<slug>/database-url-prod` (0600), written by the person from the database console; used only as `DATABASE_URL="$(cat <file>)"` | the setup machine's owner |
| Local copies | `.env.local` in the site (git-ignored, 0600; the script refuses if it is not ignored, or if the folder is not a git repository yet) | the developer |

A Sensitive Vercel value cannot be read back; the owner-only file is the copy. Never paste one into
chat, a ticket, a commit or a log.

## Never build the address from `VERCEL_URL`

`BETTER_AUTH_URL`, `NEXT_PUBLIC_APP_URL` and `AUTH_TRUSTED_ORIGINS` are set explicitly for each
environment. `VERCEL_URL` is the per-deployment address: it changes on every push, it is never a
registered redirect, and Vercel says it cannot be used with Standard Deployment Protection.

## Previews

No production Entra secret on Preview (control C38): a secret on Preview is readable by any
branch's code. What previews get follows `PREVIEW_MODE`:

| `PREVIEW_MODE` | Sign-in on a preview | Entra settings on Preview |
|---|---|---|
| `test-lane` (default) | the test password lane only (`.invalid` accounts), with `PASSWORD_LANE=local+preview` | none |
| `stable-host` | Microsoft, on the one branch address `PREVIEW_HOST` only | its own registration and secret |
| `none` | no sign-in | none |

The test lane on previews starts with no account: sign-up is always refused, and production never
holds a test account. The person makes each one against the preview database, once it is migrated
(SKILL.md step 7.2):
`DATABASE_URL="$(cat ~/.config/<slug>/database-url-preview)" DEV_TEST_PASSWORD='<password>' npx tsx scripts/dev-test-user.ts --preview tester@site.invalid - "Test Person"`
(the URL comes from its owner-only file, so it never lands in shell history; the person types the
password, never the agent). It refuses a database that holds any real
person, any Microsoft account or any bound identity, so it never runs against production or a copy
of it.

Protect previews with Vercel Authentication on **Standard Protection**: every deployment except the
production domains needs a Vercel login. The Hobby plan includes it.

**A preview holds no production personal data.** Any branch's code runs on a preview with the
preview `DATABASE_URL`, so whatever that database holds, every branch can read: the people list,
`sign_in_events` (emails, IP addresses, user agents) and Better Auth's user and account rows (id
tokens in plain text, C19). A Neon branch per preview is a clone of its parent branch, and by
default the parent is the one production runs on (Neon's own page, checked 2026-09-25), so it is a
copy of production's data. Give Preview its own database instead: a second Neon database or
project, or your own, created empty. Its URL goes in `~/.config/<slug>/database-url-preview`
(chmod 600), written by the person, and `run database` sends it to Preview. It is migrated in
SKILL.md step 7.2, and again before every later deploy, with exactly this line:
`DATABASE_URL="$(cat ~/.config/<slug>/database-url-preview)" npx drizzle-kit migrate`. Until then
every preview sign-in fails on a missing table and `dev-test-user.ts --preview` makes no tester. If
you want Neon's branch per preview anyway, set its parent to a separate branch that holds no
production rows, never the production branch; a branch carries its parent's schema, so migrate that
parent the same way.

## A new database: Neon through the Vercel Marketplace

Vercel Postgres no longer exists; new projects use a Marketplace integration. With `DB_SOURCE=neon`,
on a yes, from a scratch folder outside the site (the CLI writes files into the folder it runs in):

```bash
vercel integration add neon --name <slug>-db -e production --no-env-pull --scope <VERCEL_SCOPE>
```

It connects the database to production and sets `DATABASE_URL` (and `DATABASE_URL_UNPOOLED`,
`POSTGRES_URL`). Preview is left out on purpose: it gets its own empty database (Previews, above). The first time, the Marketplace terms need the person's own acceptance in the
browser; the agent cannot accept them. Then the person copies the production connection string
from the Neon console into `~/.config/<slug>/database-url-prod` (chmod 600) themselves.

## Renewal

- The end date of each credential is written to Vercel (`..._EXPIRES`), the state file and the
  setup record (wherever `RECORD_IN_REPO` put it).
- Administrators see a warning in the site 30 days before (`credentials.ts`); the daily cron logs it.
- To renew, each on a yes: `tenant-setup.sh --site <slug> run secret <env>` (appends a new secret),
  `vercel-env.sh --site <slug> run <env>`,
  redeploy, check a sign-in, then delete the old secret:
  `az ad app credential delete --id <app id> --key-id <old key id>` (on a yes).
