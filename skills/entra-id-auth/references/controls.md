# The control checklist

The final check of every site this skill sets up: M for the Microsoft 365 side, C for code and
platform. The scripts and the template comments cite these ids ("control M5"), so they never change.

- **How it is checked:** `verify-tenant.sh` (tenant), `verify-site.sh` (live site, from outside),
  a unit test (file under `tests/unit/auth/`), or by hand.
- **Result:** PASS, FAIL, WARN (works, needs a follow-up), UNVERIFIED (the check could not be read;
  say who can read it), N/A (the control does not apply to this site; say why). PASS (decided)
  means an answer the person gave and the config recorded settles the row; quote its
  `..._ANSWERED_BY` or the setting. A FAIL is fixed before the site is called done. N/A and PASS
  (decided) are not failures.

## Microsoft 365

| # | Control | Target | Checked by |
|---|---|---|---|
| M1 | Single tenant | `signInAudience = AzureADMyOrg` on every sign-in app | verify-tenant |
| M2 | Code flow only | implicit id and access tokens off; no SPA or public-client redirects; not a fallback public client | verify-tenant |
| M3 | Exact redirects, one registration per environment | production: `https://<domain>` and `https://<project>.vercel.app` callbacks only (the domain's alone when it is the `.vercel.app` host); local: `http://localhost:<port>` only, on its own app; preview only on its own app | verify-tenant, verify-site (redirect_uri) |
| M4 | Assignment required | `appRoleAssignmentRequired = true` on every enterprise app | verify-tenant |
| M5 | The group is the only door | `ASSIGNMENT_MODE=group`: the sign-in group, plus the administrators group with `ROLE_SOURCE=entra`; no direct users. `direct` (no P1): PASS (decided) when the direct assignments on each enterprise app equal the group's members, with the counts | verify-tenant |
| M6 | Group shape | security, not mail, static, not role-assignable, cloud-only | verify-tenant |
| M7 | Two owners | on each app registration, each enterprise app and the group | verify-tenant |
| M8 | Three scopes | `openid profile email` on the registration, the grant and the live authorize request | verify-tenant, verify-site |
| M9 | Tenant-wide consent | one `AllPrincipals` grant, exactly those three scopes; no per-user grants | verify-tenant |
| M10 | No application permissions on a sign-in app | `appRoleAssignments` = 0; the reader app also 0 (its reach is Exchange RBAC) | verify-tenant |
| M11 | Credential life | sign-in secret under 12 months (`SECRET_MONTHS`, default 11; the scripts refuse more than 12), end date recorded, warned 30 days out in the site and the daily check; reader uses a certificate, no secret | verify-tenant, credentials.test |
| M12 | One credential, one job | server-side Microsoft 365 work uses its own registration; the sign-in secret reads no mail | verify-tenant |
| M13 | Mailbox scope | Exchange RBAC for Applications, `Application Mail.Read`, named mailboxes only; proof InScope True then False | by hand (Exchange script output) |
| M14 | MFA, only on the person's yes | `REQUIRE_MFA=yes`: a Conditional Access policy for these apps and the group requires MFA, sign-in frequency `SESSION_MAX_HOURS`; sign-ins show `multiFactorAuthentication`. `no` (including no P1, security defaults on, or already covered by a tenant-wide policy): nothing is created and both M14 rows are N/A, quoting `MFA_ANSWERED_BY` and what preflight found, except that a policy left from an earlier yes makes the policy row WARN (remove it, or set yes) | verify-tenant (policy if readable, sign-in log; N/A when `REQUIRE_MFA` is not yes) |
| M15 | Device condition | the tenant's own device policy applies; a compliant-device rule is the organisation's tenant-wide choice; record it | by hand |
| M16 | No guests, no nested groups | 0 nested groups; 0 guests, or PASS (decided) with the guest count when `ALLOW_GUESTS=yes` | verify-tenant |
| M17 | Objects say what they are | app notes, enterprise app notes and group descriptions carry the marker `entra-id-auth:<DOMAIN>` and name the site, the owners and where the secret lives; the setup record exists where `RECORD_IN_REPO` put it (`docs/auth/entra-record.md` in the site, or `~/.config/<slug>/entra-record.md`) and holds no local path | verify-tenant |
| M18 | Service principal lock | `servicePrincipalLockConfiguration` enabled, all properties, set by the app step itself (not left to the tenant default) | verify-tenant |
| M19 | Nothing extra in the token | no group claim, no optional claims, no exposed API | verify-tenant |
| M20 | App roles | `ROLE_SOURCE=entra`: each sign-in registration defines exactly one app role, `Administrator` (value `administrator`, users only), assigned only to the administrators group or, with no P1, to named people. N/A when `ROLE_SOURCE=site` (then no app role is defined, and any is a FAIL) | verify-tenant |

## Code and platform

| # | Control | Target | Checked by |
|---|---|---|---|
| C1 | Tenant-pinned authority | `tenantId` set, never `common`; the live authorize URL is `/<tenant id>/oauth2/v2.0/authorize` | verify-site |
| C2 | id token trusted for the right reason | On the code flow (the only sign-in path left open, C3) Better Auth does not check the id token's signature, audience or issuer. The token is trusted because it came straight from Microsoft's tenant-pinned token endpoint over TLS, in exchange for our code, our client secret and our PKCE verifier (OpenID Connect Core 3.1.3.7, item 6: TLS server validation may stand in for the signature check). On top of that, `gate.ts` refuses a token whose `aud` is not this site's client id, and a foreign `tid` (C4); `oid` is required (C5) | gate.test (`aud`); verify-site (C1, C3) |
| C3 | Code flow, PKCE, single-use state | S256 on the live authorize URL; a bare id-token sign-in (`idToken` in the body of `/sign-in/social`) is refused with 404 `ID_TOKEN_NOT_SUPPORTED`, because it skips the code flow, PKCE and state (`disableIdTokenSignIn: true` in `server.ts`) | verify-site |
| C4 | Tenant checked again before a session | the session hook refuses a foreign `tid` | gate.test, db.integration.test |
| C5 | Identity by object id | person found by Entra `tid` + `oid`; email matches once, to bind; a second account claiming a bound email is refused | gate.test, db.integration.test |
| C6 | The site's own list | no session unless listed and the newest assignment is active; with `JOIN_MODE=group` a group member is added on first sign-in, and the row names that as its source; with `ALLOW_GUESTS=no` that join refuses an address outside the organisation's domains | gate.test |
| C7 | Checked on every request | the proxy, every page, layout, template and default (`requirePagePerson()`) and every handler read person and role | current-person.ts; page-checks.test |
| C8 | Roles | administrator writes behind `requireAdministrator`; with `ROLE_SOURCE=entra` the role comes from the id token's `roles` claim at sign-in, recorded as an append-only row | current-person.ts; gate.test |
| C9 | Never zero administrators | check and write in one transaction under an advisory lock | db.integration.test (race) |
| C10 | Append-only access record | UPDATE, DELETE, TRUNCATE refused on all four access tables: `people`, `person_identities`, `person_assignments`, `sign_in_events` | db.integration.test (each of the four tables, each of the three statements) |
| C11 | First administrator | script refuses once an admin exists and off the org domain; binds the object id | db.integration.test |
| C12 | Sign-in log | every decided sign-in: outcome, email tried, tenant and object id seen, path (Better Auth's route pattern, `/callback/:id`), IP, user agent | db.integration.test |
| C13 | Failed attempts logged | a forged callback and a wrong password each leave a `refused_other` row; a try refused by the rate limit (429) leaves a `rate_limit` row, not a sign-in row | db.integration.test |
| C14 | Refused sign-in leaves no user rows | user and account rows removed; the log row kept | db.integration.test |
| C15 | Session cookie | `__Secure-` prefix, HttpOnly, Secure, SameSite=Lax, DB-backed | library; `useSecureCookies` |
| C16 | Session length (Setting) | idle `SESSION_IDLE_MINUTES` (default 60), renewed by activity; absolute `SESSION_MAX_HOURS` (default 12); `settings.ts` holds the configured numbers | settings.ts; current-person.ts; the grep below |
| C17 | Removal in Microsoft reaches a session | the `SESSION_MAX_HOURS` absolute cap (the next sign-in goes back through Microsoft: group, account) plus the people-list switch-off, which is instant. No hourly membership check, no Graph application permission (M10 stays 0). Report PASS (decided), quoting `SESSION_ANSWERED_BY`, once the cap is proven in the site | db.integration.test (a session backdated past the cap is refused, its row deleted, a `refused_session_expired` row logged); settings.ts; current-person.ts |
| C18 | Sign-out | deletes the session row and cookie | library |
| C19 | Provider tokens at rest | the access token is stored encrypted; no refresh token is asked for or kept (no offline_access). The id token is kept in plain text on purpose: `gate.ts` reads its `tid` and `aud`. That is safe: it holds only what the user row already holds (name, email, `tid`, `oid`), and it cannot be replayed, since a bare id-token sign-in is refused (C3). Better Auth's `dist/oauth2/link-account.mjs` (1.7.5 and 1.7.6), which the callback route calls, encrypts `accessToken` and `refreshToken` with `setTokenUtil` and stores `idToken` as it came | server.ts |
| C20 | Trusted origins | production: the listed origins only; a foreign origin cannot start a sign-in | trusted-origins.test, verify-site |
| C21 | CSRF | Better Auth origin check, SameSite=Lax, Server Actions origin check | library, framework |
| C22 | Safe `next` and callbacks | refuses `//`, backslash, encoded slashes, control characters, other origins; on the page and again on the server for every sign-in start's `callbackURL`, `errorCallbackURL`, `newUserCallbackURL` (Better Auth skips its own check in test mode or with `disableOriginCheck`) | safe-next-path.test, callback-guard.test, db.integration.test, verify-site |
| C23 | Fixed error words | `?error=` mapped to fixed words; `error_description` never shown | messages.test |
| C24 | Canonical host | `<project>.vercel.app` pages 307 to the domain; `/api/*` left alone. N/A when `DOMAIN` is the `.vercel.app` host (`VERCEL_HOST` empty, no redirect written) | verify-site |
| C25 | Everything gated by default | only `/sign-in`, `/api/auth`, named server-to-server routes and static files pass without a cookie; whole segments only. A signed-out `/sign-in-help` must redirect to `/sign-in`; a 404 there means the gate let it through | route-access.test, verify-site |
| C26 | No page content without a person | the proxy reads the person in full (`personFromHeaders()`: session, list, switched on, the cap) on every gated path before anything renders; every `page`, `layout`, `template` and `default` on a gated path calls `requirePagePerson()` (or `requireAdministratorPage()`) first; every route handler and every server action calls `requireCurrentPerson` or `requireAdministrator` (page-checks.test reads handlers under `app/` and every server action a signed-in page uses, whatever its folder or route group: the file sits in or below that page's folder, or the page imports it, directly or through other files; it skips a file used only by public pages, such as `sign-in/actions.ts`. An action file no page imports, and which of the two calls an action needs, are checked by eye). A layout alone is not a gate: Next renders it and its page side by side, so a page with no check of its own goes out in the body of the layout's redirect | verify-site (a made-up session cookie on the probe page, `/` or `--probe <path>`, sent plain and as a page-to-page RSC request: the body is read, and any page content, a 200 or the `--marker` text is a FAIL; on an unlisted path, a redirect or a 404, never a 200); page-checks.test; the three greps below |
| C27 | Test password lane | on only where `PASSWORD_LANE` allows (a Vercel preview, or `next dev`); a production build keeps it off on any host whatever `NODE_ENV` it runs with; `.invalid` only; no Microsoft account; sign-up always refused (db.integration.test: a POST to `/api/auth/sign-up/email` is refused and makes no user). Live: `/sign-in/email` answers `EMAIL_PASSWORD_DISABLED` (a 4xx alone proves nothing: a wrong password on a lane that is on is also 4xx), and the page has no test form | password-lane.test, gate.test, db.integration.test (sign-up), verify-site |
| C28 | Rate limit | database store, shared by every instance; 5 a minute on password sign-in | server.ts |
| C29 | Framing and sniffing | `frame-ancestors 'none'`, `X-Frame-Options DENY`, `nosniff`, `Permissions-Policy` | security-headers.test, verify-site |
| C30 | HSTS | present (Vercel default) | verify-site |
| C31 | Full CSP | nonce-based: `default-src 'self'`, `script-src 'nonce-...' 'strict-dynamic'`, `object-src 'none'`, `base-uri 'none'`, `form-action` self and Microsoft | security-headers.test, verify-site |
| C32 | Referrer and fingerprint | `Referrer-Policy: strict-origin-when-cross-origin`; no `X-Powered-By` | security-headers.test, verify-site |
| C33 | No indexing | `X-Robots-Tag: noindex...` on every path, from next.config (any host) and vercel.json | security-headers.test, verify-site |
| C34 | Server-to-server secret | bearer compared in constant time; no secret means refused on Vercel | server-caller.test, verify-site |
| C35 | Health | `{"ok":true}` to anyone; details to the bearer or an administrator, never a value | health.test, verify-site |
| C36 | Upstream error text scrubbed | Graph error ids removed before storing | graph-app-client.ts |
| C37 | Sensitive Vercel settings | the Entra secret, `BETTER_AUTH_SECRET`, `CRON_SECRET`, the reader key are Sensitive; database ones too where Vercel allows, else recorded | `vercel env ls` (names and types) |
| C38 | Preview isolation | previews hold their own `BETTER_AUTH_SECRET` and `CRON_SECRET` and no production Entra secret; a preview holds no production personal data (its own database, not production's and not a branch copied from it); previews behind Vercel Authentication (Standard Protection) | `vercel env ls preview`; by hand: the preview `DATABASE_URL`'s source (not production's, and with `DB_SOURCE=existing` not an integration that also feeds Preview, such as a Neon branch per preview made from production's branch; the script reads only production's names), whether that database is migrated (SKILL.md step 7.2), and the project's Deployment Protection: `verify-site.sh <domain> --preview <a preview URL>` adds a C38 row that passes only when the preview, asked with no cookie, answers 401 or redirects to `vercel.com/sso`, never 200 from the site (or by hand: `curl -sI <a preview URL>`) |
| C39 | One source per setting | every sign-in setting read through `lib/auth/env.ts` (paths under the source root: `src/`, or the site root with no `src/`); allowed exceptions, each with its reason in the file: `server-caller.ts` (tests stub it), `lib/db.ts` (`DATABASE_URL`, `VERCEL`), `proxy.ts` or `middleware.ts` (`NODE_ENV`, `VERCEL_ENV` for the CSP only) | by hand (grep `process.env`) |
| C40 | Sign-in page not cached | `Cache-Control` on `/sign-in` is `private` or `no-store` | verify-site |

## How to run it

From the site folder. `<skill>` is the folder holding SKILL.md; write its full path.

```bash
bash <skill>/scripts/verify-tenant.sh --site <slug>                                  # M rows
bash <skill>/scripts/verify-site.sh <domain> <project>.vercel.app --tenant <tenant id>   # live C rows (leave out the vercel.app host when it is the domain; C24 is then N/A)
npx vitest run tests/unit/auth                                                        # unit rows
# the database tests: SKILL.md step 6.3 (create, migrate, run, drop a throwaway database)
vercel env ls production; vercel env ls preview                                       # C37, C38 (names and types only)
R=src; [ -d src/app ] || R=.                                                          # the source root: src, or . with no src folder
grep -rn "process.env" "$R" --include='*.ts' --include='*.tsx' --exclude-dir=node_modules --exclude-dir=.next --exclude-dir=scripts --exclude-dir=tests --exclude='*.config.*' --exclude='*.d.ts' | grep -v "lib/auth/env.ts:\|server-caller.ts:\|lib/db.ts:\|proxy.ts:\|middleware.ts:"   # C39: expect nothing
grep -nE "SESSION_(IDLE_MINUTES|MAX_HOURS)" "$R/lib/auth/settings.ts"                 # C16, C17: the numbers equal the config's
grep -n "SESSION_MAX_AGE_SECONDS" "$R/lib/auth/current-person.ts"                     # C16, C17: enforced on every request
# C26 pages: every page, layout, template and default outside /sign-in (and outside PUBLIC_PATHS) calls requirePagePerson() itself. page-checks.test does this in the unit run; by hand, expect nothing (or only the root layout, template and default, public pages, and group layouts over public pages only).
find "$R/app" \( -name 'page.*' -o -name 'layout.*' -o -name 'template.*' -o -name 'default.*' \) -not -path '*/sign-in/*' -exec grep -L "requirePagePerson\|requireAdministratorPage" {} +
# C26 handlers: each route handler outside api/auth, api/health and api/cron must check the person. Expect nothing.
find "$R/app" -name 'route.*' -not -path '*/api/auth/*' -not -path '*/api/health/*' -not -path '*/api/cron/*' -exec grep -L "requireCurrentPerson\|requireAdministrator" {} +
# C26 server actions: page-checks.test reads every one that a signed-in page uses, except a file used only by public pages (such as sign-in/actions.ts). List every "use server" file; for each that no signed-in page imports or that only public pages use, check by eye that every exported async function starts with await requireCurrentPerson() or await requireAdministrator().
grep -rlE "^[[:space:]]*['\"]use server['\"]" "$R" --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --exclude-dir=node_modules --exclude-dir=.next
bash <skill>/scripts/verify-site.sh <domain> --preview <a preview URL>             # C38: 401, or a redirect to vercel.com/sso; never 200
# With / public: add --probe <a signed-in page> to the live run, and --marker <a phrase only that page shows>
```

Report the whole table, one row per control, with the evidence. Counts, ids and dates only: never
a person's name beyond what a row needs, never a secret.

## Tested with

The templates and their tests were run end to end (a fresh create-next-app site, the templates
copied and wired as SKILL.md steps 4 and 5 say, step 6 run as written, against a throwaway local
Postgres) with:

| Part | Version |
|---|---|
| Next.js | 16.3.6 (App Router) |
| better-auth | 1.7.5 and 1.7.6 |
| drizzle-orm | 0.45.3 |
| vitest | 5.0.1 |
| Node.js | 24 |
| PostgreSQL | 17 |

Other versions inside the ranges in [adapting.md](adapting.md) are expected to work, but are not
tested. Next.js 15 is supported through `middleware.ts` and is not tested.
