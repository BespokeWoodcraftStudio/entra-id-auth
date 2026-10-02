# Lessons the templates already carry

Each one cost a lockout, a leak or a round of review on a real site. The fix is already in the templates.

| Lesson | What happened | The fix in this skill |
|---|---|---|
| A new address needs three things at once | Adding a domain without the redirect URI, `BETTER_AUTH_URL` and `AUTH_TRUSTED_ORIGINS` together locked the owner out | the app step, `vercel-env.sh` and the config all name `DOMAIN`; change them together |
| Local copies on another port were refused | "Invalid origin" | `trusted-origins.ts` trusts the caller's own localhost origin outside production |
| A refusal thrown in `mapProfileToUser` shows raw JSON | the callback calls it outside its try | refuse in `databaseHooks.session.create.before` |
| `onAPIError.onError` never runs for a wrong password or a bad callback (1.7.5) | failed attempts left no trace | `hooks.after` (`failed-attempts.ts`), proven by test |
| A password row with a null id token skipped the tenant check | account rows not filtered by provider | `providerId = 'microsoft'` in every account read |
| Without `disableSignUp`, anyone could sign up as a listed admin's address on a preview | | always `disableSignUp: true` |
| The gate file at the project root never ran | with `src/`, it must sit in `src/` | `src/proxy.ts` |
| A hand-kept list of protected prefixes went stale in one loop | the home page `/` was ungated | everything gated except named public paths |
| `/api` opened as a block let health leak the settings list | | name each server-to-server route |
| `/\evil.com` resolves off-site | the library's check was relied on | `safeNextPath` in our own code |
| `session.ipAddress` is `""`, not null | a typed column refused it | an empty string is stored as null |
| `error_description` can carry anything | | fixed words per code; round-trip failures say "try again" |
| Nobody can be added before the first administrator exists | | `scripts/first-administrator.ts` |
| Assignment required was switched on after launch | until then any tenant account could authenticate | set in the first `sp` step, before anyone signs in |
| Exchange PowerShell and admin tools can be refused with AADSTS53003: a Conditional Access policy blocked the sign-in, often a managed-device or location rule | | the reader step writes a script the administrator runs where their policy allows (on a device rule, a compliant or registered device); ask the Microsoft 365 administrator which rule applies |
| A Sensitive Vercel value cannot be pulled back | | the owner-only file in `~/.config/<slug>/` is the copy |
| The Vercel framework preset must be `nextjs` | the first deploy served a static folder | `vercel.json` sets it |
| Migrations shipped unapplied once | a deploy went out ahead of its migration | diff `drizzle/` against the last deployed commit and migrate before every deploy |
| A production build run with `NODE_ENV=development` opened the test lane | a test run turned it on with `NODE_ENV=development next start` | the lane and localhost origins read the build mode, which Next.js fixes at build time |
| Better Auth checks `Origin` only when a `Cookie` header is present, and skips callback checks in test mode | the first live probe for C20 failed on a correct site; a test showed `/\evil.example` accepted | the probe sends a cookie; `callback-guard.ts` checks every redirect target itself |
| A `plan` then `run` script that ends on `[ plan ] && ...` exits 1 after a good run | every successful run looked like a failure | each script ends with `exit 0`; the verify scripts exit 1 only on a FAIL |
| `vercel env add --force` writes to whatever project the folder is linked to | a folder linked to another site would overwrite its secrets | `vercel-env.sh` refuses unless the link is `VERCEL_PROJECT` |
| Entra only puts `email` in the token when the account has a mail address | sign-in fails with `email_not_found` | messages say so; every person needs a mailbox or a mail attribute |
