# The code, file by file

Templates live in `<skill>/templates/`, at the path they take in the site.
`<skill>/scripts/copy-templates.sh` copies them and never overwrites: an existing file is listed
MERGE.

## Settings come from the config

Every site-specific value comes from `entra-site.env` through a placeholder. Each placeholder sits
inside a string literal, so a raw template still parses; the fill escapes it, so a name with `&`
or quotes stays valid code.

| Placeholder | From | Used in |
|---|---|---|
| `__SITE_NAME__` | `SITE_TITLE` | `settings.ts`, the sign-in page |
| `__EMAIL_DOMAINS__` | `EMAIL_DOMAINS` | `settings.ts` (the first administrator and seeded people must match one) |
| `__DOMAIN__`, `__VERCEL_HOST__` | `DOMAIN`, `VERCEL_HOST` | `vercel.json`, trusted origins |
| `__SRC_ROOT__` | detected: `src` or the site root | `vitest.config.mts`, `drizzle.config.ts` |
| `__SESSION_IDLE_MINUTES__`, `__SESSION_MAX_HOURS__` | `SESSION_IDLE_MINUTES`, `SESSION_MAX_HOURS` | `settings.ts` |
| `__ROLE_SOURCE__` | `ROLE_SOURCE` (`site` or `entra`) | `settings.ts`, read by `gate.ts` |
| `__JOIN_MODE__` | `JOIN_MODE` (`listed` or `group`) | `settings.ts`, read by `gate.ts` |
| `__ALLOW_GUESTS__` | `ALLOW_GUESTS` (`yes` or `no`) | `settings.ts`, read by `gate.ts` (the `JOIN_MODE=group` join) |

`settings.ts` parses and range-checks the numbers (idle 15 to 480 minutes and less than the
absolute cap; the cap 1 to 24 hours) and the three words, and throws at import on a bad value, so a
wrong fill fails the build instead of shipping. To change one later, edit `entra-site.env`, then
change the same line in `settings.ts` (and rerun `ca` if the cap changed and MFA is on).

## Copying

A file the site already has is MERGE. The run writes a filled copy of its template (the same
fill as a NEW file) to `~/.config/<slug>/merge/<path>` and prints that path. Merge by hand from that filled copy,
never from the raw template (it still holds the placeholders): carry its guards into the site's
file, keep one file, show the diff, save on a yes.

Install: `npm i --save-exact better-auth@1.7.6 && npm i "drizzle-orm@^0.45.2" postgres zod dotenv` and
`npm i -D drizzle-kit tsx vitest @types/node@^24` (vitest 5 needs `@types/node` 22 or 24+, and
create-next-app pins 20, so the plain line fails with ERESOLVE). Plus `@azure/identity` for a
reader. Tested with better-auth 1.7.5 and 1.7.6, next 16.3.6, drizzle-orm 0.45.3, zod 4, vitest 5.0.1
([controls.md](controls.md), "Tested with"). Better Auth is pinned exactly: `failed-attempts.ts`,
`tenant.ts` and `server.ts` rely on internals checked in those two versions only, and a changed
shape fails quietly (no `refused_other` rows, C13). A site on any other version is moved to
1.7.6 exactly (`detect-site.sh` says so), then runs the tests, the database tests included
(SKILL.md step 6.3), before going live.

## Sign-in core (`src/lib/auth/`)

| File | Does | The guard, and why |
|---|---|---|
| `settings.ts` | site name, email domains, session limits, role source, join mode, public and server-to-server paths | every setting in one place, filled from the config, parsed and range-checked at import |
| `env.ts` | validates every sign-in setting once | one source per setting (C39); production (Vercel, or a production server anywhere) refuses to start without the Entra trio, an https `BETTER_AUTH_URL` and `CRON_SECRET`; `passwordSignInAllowed` keys on a preview or a local build that is not a production build, read from the build itself so a host's runtime `NODE_ENV` cannot turn it on (C27) |
| `server.ts` | the Better Auth instance | `tenantId` pinned (C1); three scopes, no photo (M8); `disableSignUp` (C27); `accountLinking` off; access token encrypted, no refresh token, id token kept plain for `gate.ts` (C19); `SESSION_IDLE_MINUTES` idle (C16); database rate limit (C28); `hooks.before` redirect guard (C22); `hooks.after` logging (C13); the session hook (C4 to C6, C14) |
| `callback-guard.ts` | every sign-in start's `callbackURL`, `errorCallbackURL`, `newUserCallbackURL` | must pass `safeNextPath`, on the server. Better Auth's own check is skipped whenever `isTest()` is true or `advanced.disableOriginCheck` is set (its `create-context.mjs`), so the rule is ours, not the library's (C22) |
| `gate.ts` | who gets a session, as a pure function | tenant again, the id token's `aud` must be this site's client id (C2), identity by `oid`, active; refusals thrown from the session hook become `/sign-in?error=` (a throw in `mapProfileToUser` shows raw JSON). `JOIN_MODE=listed`: a person not on the list is refused. `group`: a first sign-in from an assigned account adds them as a member, the row naming that source; with `ALLOW_GUESTS=no`, an address outside `ORG_EMAIL_DOMAINS` is refused (`refused_not_on_the_list`), which catches a guest, whose address is on their home domain. `ROLE_SOURCE=entra`: reads the id token's `roles` claim and appends a role row when it differs from the list (C8) |
| `gate-store.ts` | the database side of the gate, the log row, removal of refused rows | filters the account by `providerId` (else a password row skips the tenant check); a logging failure never masks a refusal |
| `tenant.ts` | reads `tid`, `aud` and `roles` from the stored id token | second check only; the token came straight from Microsoft's token endpoint over TLS, for our client secret and PKCE verifier (Better Auth does not check its signature on this path; C2) |
| `failed-attempts.ts` | logs forged callbacks and wrong passwords | `onAPIError.onError` never fires for these in 1.7.5; `hooks.after` does |
| `current-person.ts` | the person and role on every request; the `SESSION_MAX_HOURS` cap. `personFromHeaders()` for the proxy, `requirePagePerson()` and `requireAdministratorPage()` for pages, layouts, templates and defaults, `requireCurrentPerson()` and `requireAdministrator()` for handlers | one check, called by the proxy and again first in every page and handler (C7, C17, C26) |
| `directory.ts` | add a person, change a role | last-administrator check and write in one transaction under an advisory lock (C9); every write names who made it |
| `trusted-origins.ts` | origins allowed to POST to `/api/auth` | production, including any production build: the list only (C20); local dev copies on any port (testers were refused otherwise) |
| `route-access.ts` | which paths pass without a cookie | whole segments only; `/api` is never opened as a block (C25) |
| `security-headers.ts` | static headers and the CSP builder | C29, C31, C32 |
| `server-caller.ts` | the cron bearer | constant time; no secret means refused on Vercel (C34) |
| `credentials.ts` | secret and certificate end dates | a warning to administrators 30 days out (M11) |
| `messages.ts` | every word about signing in | codes to fixed words; `error_description` never shown (C23) |
| `client.ts` | the browser client | talks only to this site's `/api/auth` |

## Around it

| File | Does | Why |
|---|---|---|
| `src/proxy.ts` | session gate and CSP nonce | Next 16 name, always on the Node runtime. On every path not in `PUBLIC_PATHS` it reads the person in full with `personFromHeaders()` (session, list, switched on, the cap) before anything renders: `/api/*` without one gets a 401, pages a 307 to `/sign-in`, and no page, layout or handler code runs, whatever RSC headers the request carries (C26). On Next 15 (15.5 or later) the copy writes `middleware.ts` with export `middleware`, and its `config` needs `runtime: "nodejs"`, because the check reads the database. Next 15 is not tested ([adapting.md](adapting.md)); on Next 16 a site's own `middleware.ts` makes it MERGE (fold it in, delete it: Next 16 refuses both); must be in `src/` when the app is (the root one never ran) |
| `src/app/api/auth/[...all]/route.ts` | serves Better Auth | |
| `src/app/sign-in/*` | page, Microsoft button, test form, `safeNextPath` | no live data; fixed words; `next` checked by our own code (C22) |
| `src/app/api/health/route.ts` | `{"ok":true}`; details for the bearer or an admin | it once leaked the settings list (C35) |
| `src/app/api/cron/credential-check/route.ts` | daily renewal warning in the logs | M11 |
| `src/components/auth/session-keep-alive.tsx` | renews an active session every 5 minutes of activity | server pages cannot reset the cookie; idle people are let go |
| `src/db/schema/auth.ts` | Better Auth tables plus `rate_limit` | |
| `src/db/schema/access.ts` | `people`, `person_identities`, `person_assignments`, `sign_in_events` | identity by `tid` + `oid` (C5); append-only |
| `drizzle/access_append_only.sql` | triggers refusing UPDATE, DELETE, TRUNCATE | C10; paste into `drizzle-kit generate --custom --name access_append_only` |
| `src/lib/db.ts` | the Postgres client | only if the site has none; it must export `getDb()` and `Database` |
| `next.config.ts` | static headers (with `X-Robots-Tag`, so noindex holds off Vercel too), `poweredByHeader: false` | a site with any `next.config.{js,mjs,ts,mts}` gets MERGE into that file; never two configs (Next reads the js or mjs one first and ignores the rest) |
| `vitest.config.mts` | the `@` alias and the test folder | without it most test files cannot resolve `@/`; `.mts`, so Vite loads it as ESM with no CommonJS warning on a create-next-app site. A site with its own `vitest.config.*` (or a `vite.config.*` with a `test` block) gets MERGE: Vitest reads the first config it finds, so a second one would be ignored. Add the `@` alias and the `tests/**/*.test.ts` include to the site's own |
| `drizzle.config.ts` | from `drizzle.config.example.ts`, with the schema paths filled for the site's own root | written only when the site has no Drizzle config; else MERGE: add both schema files to its list |
| `vercel.json` | `framework: nextjs`, vercel.app pages to the domain (not `/api/*`, so an old callback completes), noindex, the daily cron | a missing framework preset served a static folder once; with no `VERCEL_HOST` the copy leaves the redirect out (the domain in its place would redirect to itself) |
| `scripts/first-administrator.ts` | the first person, bound by object id | the only way in on day one (C11) |
| `scripts/seed-people.ts` | every person in `~/.config/<slug>/people.json` (written by the `group` and `admin-group` steps), with their role | step 7; appends, skips anyone already listed, binds each by `oid` and tenant (C5); its header gives the flags |
| `scripts/add-person.ts` | one person, from the command line | for a site with no people screen yet; `--oid` and `--tenant` are required, so the identity is bound now, not later by email (C5) |
| `scripts/set-person.ts` | change one person's role, or switch them off or on | appends a row naming who made the change, never edits one (C10); refuses to remove the last administrator (C9). With `ROLE_SOURCE=entra`, a role change is made in Entra instead; the script says so |
| `scripts/dev-test-user.ts` | a `.invalid` test identity with a password | on the local database, or with `--preview` on Preview's own migrated database ([secrets-and-settings.md](secrets-and-settings.md), Previews); refuses when run on Vercel, and refuses any database holding a real person or production's URL |
| `tests/unit/auth/*` | one file per part; `db.integration.test.ts` runs against a database, and `page-checks.test.ts` parses every gated page, layout, template, default and route file (`route.ts`, `.js`, `.tsx`, `.jsx`) in the site's own `app/` folder and fails on one that does not start with its check (a comment does not count; each exported method of a route on its own; a form it cannot read, such as a re-export, fails). It is the second check; the proxy stays the gate. It reads gated metadata files too (`opengraph-image`, `twitter-image`, `icon`, `apple-icon`, `sitemap`, with their `generateImageMetadata` and `generateSitemaps`), and fails a gated `page.mdx`, which cannot check. It reads server actions: every exported function of a `"use server"` file, and each action written inside any other file, starts with the handler check (Wiring 5). The test reads a server action when a signed-in page uses its file: the file sits in or below that page's folder, or the page imports it, directly or through other files. It skips a file used only by public pages, such as `sign-in/actions.ts`, which must then do nothing a stranger may not. It skips the root `layout`, `template`, `default` and metadata files (each serves `/sign-in` too, so each shows nothing private), and never reads `not-found`, `error`, `loading` or `global-error` files, `robots` or `manifest` files, server actions no signed-in page uses, or a Pages Router `pages/` folder: there the proxy is the only gate and it never checks the role, so keep private data out of them; check by eye any action file no signed-in page imports. A `layout`, `template` or `default` inside a route group is gated when any page under its folder is gated; one shared only by public pages is skipped and must show nothing private; one over public and signed-in pages must check, so move the public pages into a route group of their own | every control a test can prove (see controls.md) |
| `examples/protected-page.tsx`, `examples/protected-layout.tsx`, `examples/route-handler.ts` | the first line of every page, the signed-in layout, the first line of every handler | not copied. Every `page`, `layout`, `template` and `default` file on a gated path starts with `await requirePagePerson()`, outside any `try`; `tests/unit/auth/page-checks.test.ts` fails on each one whose default export (or `generateMetadata`) does not start with it, whatever the export's form; a comment does not count. The layout becomes `src/app/(app)/layout.tsx`, with the signed-in pages moved under `(app)/`; never the root layout (nor a root template or default), which also wraps `/sign-in` and would redirect it to itself. The layout is a convenience (keep-alive, renewal warning), not the gate for the pages under it |
| `src/lib/m365/graph-app-client.ts` | the server-side Microsoft 365 reader: `allowedMailboxes()`, `graphGet()`, `latestMessages(mailbox)`, `scrubGraphError()` | copied only when the site reads Microsoft 365 on the server; its own app and certificate, never the sign-in app (M12); only the mailboxes in `M365_READER_MAILBOXES` (M13); Graph ids scrubbed from error text (C36) |

## Wiring

1. Copy; merge any MERGE file. `copy-templates.sh` adds `!.env.example` to `.gitignore` when
   create-next-app's `.env*` would keep the names-only example out of git.
2. A site that already had a Drizzle config: add both schema files to its schema list (and to
   `getDb`'s schema if the site has its own client). A fresh site got `drizzle.config.ts` from the copy.
3. `npx drizzle-kit generate`, then `npx drizzle-kit generate --custom --name access_append_only`,
   paste `drizzle/access_append_only.sql` into that new file, delete the template copy. Generate
   needs no database. Nothing is migrated here: the local database is migrated in SKILL.md step 6,
   after `vercel-env.sh run local` (step 5) has written its `DATABASE_URL` to `.env.local`.
   Production and the preview database are migrated in SKILL.md steps 7.1 and 7.2, each with the
   URL from its owner-only file.
4. Signed-in pages: move every one under `(app)/` (`src/app/page.tsx` becomes
   `src/app/(app)/page.tsx` and still serves `/`), and make `await requirePagePerson()` the first
   line of every `page`, `layout`, `template` and `default` file on a gated path
   (`requireAdministratorPage()` for an administrators-only page; in `generateMetadata` too, which
   renders on its own), as `examples/protected-page.tsx` shows, outside any `try` (`redirect()`
   works by throwing, so a catch would swallow it). A `"use client"` page cannot call it: make
   `page.tsx` a server component that calls it and renders the client one. Then create
   `src/app/(app)/layout.tsx` (no `src/`: `app/(app)/layout.tsx`) from
   `examples/protected-layout.tsx`; a site that already has a layout for its signed-in pages takes
   the example's lines into that one. Never a check in a root-level wrapper (`app/layout.*`,
   `app/template.*`, `app/default.*`): each also wraps `/sign-in`, so its redirect loops and nobody
   can sign in. The test skips those three and the root metadata files, so each shows nothing
   private; a root template that needs the person (a `"use client"` page-transition one, say) moves
   into `(app)/`. A gated `page.mdx` fails the test: import its content into a `page.tsx` that
   checks first.

   The layout is not the gate for its pages. Next.js's own authentication guide says: "A layout also
   does not control whether the rest of the route renders. Route segments and parallel route slots
   are rendered by the router, so a layout that hides or swaps them does not stop them from running
   or from appearing in the RSC Payload." A layout's `redirect()` sets the status, and a page with no
   check of its own still goes out in the body of that 307 to anyone who does not follow it. So the
   proxy reads the person before anything renders, and every page checks again (C26).
5. Every route handler and server action: `requireCurrentPerson()` or `requireAdministrator()` first,
   in each exported method on its own (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`). The proxy never
   checks the role: a method only administrators may use calls `requireAdministrator()` itself. A
   `try` around the check is the example's form only: every catch returns the 401 or 403, or
   rethrows, no `finally` returns, and nothing runs after the `try`. `page-checks.test.ts` reads
   every server action that a signed-in page uses (each exported function of a `"use server"` file,
   and each action written inside any other file) and every action written inside a gated page or
   route (the line after its `"use server"`). A page uses a file when the file sits in or below the
   page's folder, or the page imports it, directly or through other files, under `app/` or elsewhere
   in the source folder; so `app/actions.ts` is read even with `/` public, and only a file used by
   public pages alone (such as `sign-in/actions.ts`) is skipped. It accepts either call, so whether
   an action needs `requireAdministrator()` is checked by eye, and so is any action file no page
   imports.
6. Add any other server-to-server route to `SERVER_TO_SERVER_PATHS`, and give it the bearer check.
7. Move any public page (a landing page) into `PUBLIC_PATHS` deliberately; nothing else is public.
   A public page has no `requirePagePerson()`, and a layout, template or default shared only by
   public pages needs no check and shows nothing private. When `/` is public, `verify-site.sh` reads
   `PUBLIC_PATHS` (or takes `--public <path>`), marks its C25 and C26 rows on `/` N/A and FAILs one
   row until it is given `--probe <a signed-in page>` (SKILL.md step 6.5), and
   `route-access.test.ts` takes `/`'s expectation from `PUBLIC_PATHS`. `page-checks.test.ts` grades
   its own fixtures with a fixed rule, so its self-test holds whatever `PUBLIC_PATHS` says; only its
   run over the site's `app/` uses the site's list.
8. Restyle the sign-in page to the site's design; keep its three rules. Every file in `public/`
   other than `favicon.ico`, `robots.txt`, `icon.svg` and `apple-icon.png` is behind the gate, so a
   logo the sign-in page loads from `public/` shows broken to a stranger. Import it
   (`import logo from "./logo.svg"` with `next/image`, served from `/_next/static`), or add its
   exact path (`"/logo.svg"`) to `PUBLIC_PATHS`, never a whole folder.
9. Only for a site that reads Microsoft 365 on the server: `npm i @azure/identity`, then build the
   route that needs it (for example `src/app/api/mail/latest/route.ts`) like
   `examples/route-handler.ts`: `requireCurrentPerson()` or `requireAdministrator()` first, then
   `latestMessages(<mailbox>)` from `@/lib/m365/graph-app-client`. Never add it to `PUBLIC_PATHS`.
   A `graphGet()` call of your own checks the mailbox against `allowedMailboxes()` first, as
   `latestMessages` does. `graphGet()` scrubs its own errors, both Graph's error replies and a token
   error from `@azure/identity`; any other Microsoft error text goes through `scrubGraphError()`
   before it is stored or shown.
