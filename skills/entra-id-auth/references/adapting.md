# A site that is not built like the tested stack

`<skill>/scripts/detect-site.sh <folder>` says FITS, ADAPT (with the list) or STOP (exit 1, with the
reason on the STOP line). The Entra side (groups, apps, consent, Conditional Access where the person
said yes, reader, verify-tenant) is the same for every site; only the code changes. When a site
does not fit, the tenant half and the control checklist still apply, and the skill says exactly
which part it will not do.

## The supported stack

| Part | Supported | Otherwise |
|---|---|---|
| Next.js | 16.x App Router: tested | 15.5 or later on 15: ADAPT, writes `middleware.ts` on the Node runtime, not tested, maintenance ends about 2026-10-21. 15.0 to 15.4: upgrade to 15.5 or 16 first (the gate reads the database, which needs middleware on the Node runtime, and SKILL.md step 6.2's `next typegen` first shipped in 15.5). 14 or older, or Pages Router only: STOP for the code |
| Better Auth | 1.7.6 (install line), 1.7.5 also tested | already installed: merge into the one instance; any other version: moved to 1.7.6 exactly (`detect-site.sh` says so), then every test, the database tests included (SKILL.md step 6.3), before going live. Another auth library: STOP until the person plans the move |
| Database | Postgres, Drizzle `^0.45.2`, `postgres` or `pg` or Neon driver | Prisma: ADAPT (below), not tested |
| Node | 22.12+ on 22, 24, or 26 and later (24 recommended; `engines: "24.x"`) | 20 or older: STOP with the fix |
| Host | Vercel | another host: code and tenant steps run; Vercel steps print the names to set in that host's store |
| Setup machine | macOS or Linux, bash, `az`, `vercel`, `node`, `psql` | Windows: through WSL only (below) |
| Tenant | Microsoft 365 with Entra ID; P1 for groups on the app and for Conditional Access | no P1: the roster path (`ASSIGNMENT_MODE=direct`); single tenant only (no B2C, no External ID, no multi-tenant) |

## Line by line

| Differs | Adapt | Or stop because |
|---|---|---|
| A fresh site: "no ORM yet", "install better-auth" | the install line in `code.md` covers both; nothing else to adapt | |
| No `"@/*"` path in `tsconfig.json` | add `"paths": {"@/*": ["./src/*"]}` (or `./*` with no `src/`); `vitest.config.mts` uses the same root | |
| The site has its own vitest config (`vitest.config.*`, or a `vite.config.*` with a `test` block) | the copy lists it MERGE (Vitest reads only the first config it finds): add the `@` alias and `tests/**/*.test.ts` to it, from the filled copy the run prints | |
| Not a git repository yet (create-next-app drops `.git` when git has no user.name or user.email) | set git user.name and user.email, `git init`, a first commit, then re-run; the scripts refuse to write `.env.local` until git ignores it | |
| Next.js 15.5 or later on 15 | the copy writes `src/middleware.ts` with export `middleware`; its `config` needs `runtime: "nodejs"` (check it is there), because the gate reads the person from the database and the Edge runtime cannot. The rest copies. Not tested | 15.0 to 15.4: upgrade first |
| A `next.config.js`, `.mjs` or `.mts` (common after an upgrade from 13 or 14) | the copy lists `next.config.ts` MERGE into that file: carry its headers and `poweredByHeader: false` into the site's own config, and never add a second one (Next reads the js or mjs one first, so the other's headers never apply) | |
| Next.js 16 with the site's own `middleware.ts` (or `.js`) | the copy lists `proxy.ts` MERGE: fold the site's middleware into the filled `proxy.ts`, then delete `middleware.ts` (Next 16 stops the build when both exist) | |
| Next.js 14 or older | upgrade first | the CSP nonce and async request APIs differ too much to carry by hand |
| No `src/` folder | nothing to do by hand: `copy-templates.sh` (SKILL.md step 4) writes `templates/src/*` to the project root, the gate file beside `app/`, and fills the vitest and Drizzle paths for that root | |
| Pages Router only | | the gate, layout and sign-in page are App Router; write them fresh from `code.md`, keep `src/lib/auth/*` |
| Prisma instead of Drizzle | write the two schema files as Prisma models, use Better Auth's Prisma adapter, rewrite `gate-store.ts`, `current-person.ts`, `directory.ts` queries; keep `gate.ts` and every test of it | |
| Neon serverless driver | keep it; make `src/lib/db.ts` export `getDb()` and `Database`; advisory locks need a transaction, which the HTTP driver lacks: use the WebSocket `Pool` for `directory.ts` | |
| Another auth library (NextAuth, Clerk, MSAL in the browser) | remove it; never run two | the site's sessions and users move to Better Auth; plan that migration with the owner first |
| Better Auth already set up | merge the options in `server.ts` into the existing instance; keep one | |
| Not on Vercel | the tenant steps and the code run as usual; `vercel-env.sh plan` still prints every name and where it goes, and the person sets them in the host's own secret store (the values come from the owner-only files, never through chat). `VERCEL_ENV` is unset: production means a production build or `NODE_ENV=production`, and the test lane and localhost origins are off there by design (the build mode is read from the build, so a host that runs a production build with `NODE_ENV=development` cannot turn them on); leave `VERCEL_HOST` empty so no vercel.app redirect is written; noindex already comes from next.config; add HSTS at the host; set settings in the host's secret store; never set `VERCEL_ENV` by hand (`preview` would open the test lane) | |
| Not Node or not React | | the tenant side and `controls.md` still apply; the code must be written for that stack, using `gate.ts` as the specification |
| A multi-tenant or guest audience | | this skill is single tenant by design (M1); a site for outsiders needs a different design |

## Windows

The scripts are bash and are not written for PowerShell or `cmd`. On Windows, run the whole setup
inside WSL (Ubuntu, for example): install `az`, `vercel`, `node`, `psql` and `git` there, keep the
site's folder inside the WSL file system, and start the agent from a WSL terminal. The one
PowerShell file, `grant-mailbox.ps1` for the optional mail reader, runs wherever an Exchange
Administrator has PowerShell 7 (Windows, macOS or Linux).
