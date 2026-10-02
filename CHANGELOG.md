# Changelog

All notable changes to this project are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.7] - 2026-10-01

First public release. (Earlier version numbers were never published.)

### What it does

- Adds Microsoft Entra ID sign-in to a Next.js website on Vercel, end to end: security groups,
  app registrations, enterprise apps with assignment required, consent for `openid profile email`
  only, an optional MFA policy, the Next.js and Better Auth code, the Vercel settings and a final
  control check.
- Looks first, asks only what it could not find out, shows every change as a plan, and runs each
  step only on a yes.
- Installs as a Claude Code plugin from this repository's own marketplace, or runs from a copy of
  `skills/entra-id-auth/` in any agent. `SETUP.md` is the one file an AI agent follows to set up
  a machine.

### Questions it asks

- MFA, with a default that follows what the tenant already has (security defaults, an existing
  policy, or none).
- Session length: idle (15 to 480 minutes) and absolute, one value for the code and the MFA
  policy's sign-in frequency.
- Whether guests may sign in. With `ALLOW_GUESTS=no` and `JOIN_MODE=group`, a first sign-in from
  an address outside the organisation's domains is refused and logged.
- The sign-in group: a new one, or an existing one picked by id. A picked group is never changed:
  no members or owners are added, and its administrators must already be in it.
  `LIST_GROUP_MEMBERS` (all or admins) decides whether its people go on the site's own list, so
  the default `JOIN_MODE=listed` does not refuse them.
- Where site roles live: the site's own list, or an Entra group.
- Previews: the test lane, one stable branch host, or none. Previews get their own empty database,
  never production's and never a Neon branch copied from it. `dev-test-user.ts --preview` makes a
  made-up test account there, with guards.
- The database: the one on the project, a new Neon one, or your own.
- Where the setup record is kept: in the site's repository only when it is private or you say so.

### Also in this release

- A path for tenants without Entra ID P1: the group becomes the roster, each member is assigned to
  the app directly, and a rerunnable step keeps them in step.
- Optional app-role administrators, and a takeover guard: a group, app or policy with the same
  name that this skill did not make stops the run.
- Least roles: each step names the smallest Entra role it needs.
- Every signed-in page, route handler and server action checks the person itself, and the proxy
  checks the session before anything renders. `tests/unit/auth/page-checks.test.ts` fails on a
  page, layout, template, default or handler under `app/`, or server action that a signed-in page
  uses, that does not check first (found by folder or by imports, under `app/` or elsewhere in the
  source folder, so a public landing page does not hide an unchecked action). `verify-site.sh` sends a made-up session cookie and fails on any
  page content in the reply (control C26).
- `preflight.sh` reads the linked project's own domains to decide whether the sign-in address and
  "add it to Vercel" are asked, counts a picked group's members the way the setup lists them
  (guests, other domains, nested groups, the administrators who are not in it), and refuses a
  group of a kind it cannot use.
- Every Microsoft Graph list is read page by page, and a list that cannot be read in full never
  drives a removal.
- Better Auth is installed exactly at 1.7.6 (1.7.5 also tested). Next.js 15 needs 15.5 or later.
- `SETUP.md` sets up a machine from macOS, Linux or WSL, in Claude Code (terminal, desktop app or
  editor) or another agent, with the right restart for each. It finds and replaces a marketplace
  or clone that points at another repository only on a yes, and removes a hand-made copy of the
  skill only on a yes.
- Plugin and marketplace manifests, CI (manifest validation, skill shape, shell checks, scripts in
  plan mode against stubs, template unit and database tests on Better Auth 1.7.5, 1.7.6 and the
  newest 1.7.x, and a leak check over the files and every commit), Dependabot, and docs for
  Microsoft 365 administrators.

[Unreleased]: https://github.com/BespokeWoodcraftStudio/entra-id-auth/compare/v1.0.7...HEAD
[1.0.7]: https://github.com/BespokeWoodcraftStudio/entra-id-auth/releases/tag/v1.0.7
