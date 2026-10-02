# Contributing

Thank you for helping. Read [`docs/DESIGN.md`](docs/DESIGN.md) section 2 first: a change that
looks like an obvious improvement may already have a reason against it written down.

## Run the checks locally

| Check | Command | What it proves |
|---|---|---|
| plugin and marketplace | `claude plugin validate . --strict` and `claude plugin validate .claude-plugin/plugin.json --strict` | both manifests and the skill load in Claude Code |
| skill shape | `bash .github/scripts/check-skill.sh` | name equals folder, portable frontmatter, `SKILL.md` under 500 lines, every `references/` link resolves |
| shell | `bash -n` on every script, then `shellcheck -x -P SCRIPTDIR` on each | no syntax errors, no shellcheck findings |
| scripts in plan mode | `bash tests/scripts/run.sh` | every script runs in plan mode against stub `az`, `vercel` and `gh` |
| templates | `cd test-harness && npm ci && npm test` | the code templates, filled with placeholders, pass their unit tests and type-check |
| templates, database | `cd test-harness && TEST_DATABASE_URL=postgres://localhost:<port>/<empty db> npm run test:db` | the real Better Auth pipeline against Postgres: append-only tables, the last-administrator lock, the first administrator, the sign-in log, refused sign-ups and bare id tokens, the session cap, both join modes and both role sources |
| leak | `bash .github/scripts/leak-check.sh` and `bash .github/scripts/leak-check.sh --history` | placeholder-only addresses and ids, no local path, and the owner's name only where allowed, in the tree and in every commit's files, message, author or committer; `--history` lists every author and committer, and with `LEAK_IDENTITY` set refuses any other. Private names are caught only with `LEAK_WORDS_FILE`, which a maintainer runs locally before merging an outside pull request (never a repository secret: a fork's pull request gets no secrets) |

Run `claude plugin validate` with a throwaway config folder, so it never touches your own settings:

```bash
CLAUDE_CONFIG_DIR="$(mktemp -d)" claude plugin validate . --strict
```

The database test needs an empty, throwaway Postgres on this machine. `db.sh` refuses an address
that is not on this machine, and a database holding any table other than the test's own (a rerun
on its own tables still works). With no `TEST_DATABASE_URL` it runs nothing and says so.

CI runs all seven on every pull request, on every push to `main`, and weekly. The shell checks
cover the stub `az`, `vercel` and `gh` too. It runs the template
tests three times: against the locked versions (`better-auth` exactly 1.7.6, the version sites
install), against 1.7.5 (which setup also accepts on an existing site), and against the newest
1.7.x, so a new patch is tested the week it ships, before the pin moves.

## No private data

| Never | Use instead |
|---|---|
| a real organisation, person or domain | `Contoso`, `contoso.com`, `fabrikam.com`, `example.com` |
| a real email address | `alex@contoso.com`, `owner@example.com`, `someone@org.example`, `test@site.invalid` |
| a real tenant, client or object id | `00000000-0000-0000-0000-000000000000` |
| a real secret, token or database address | an obvious placeholder such as `<client-secret>` |
| a local path or account name | `<path to the site>` |
| an internal ticket or decision number | the reason itself, in plain words |

Commit with your GitHub no-reply address (GitHub Settings > Emails > Keep my email addresses
private). The history leak check refuses any other address in an author, committer or message.

Never call a real tenant, Microsoft Graph, Vercel or a live website from a script, test or CI job.
Every Microsoft 365 and Vercel step in tests runs in plan mode against the stubs in
`tests/scripts/stubs/`.

## Pull requests

- One change per pull request: one fix, one feature or one doc update.
- Every write a script makes goes through plan first and runs only after a yes.
- Keep `SKILL.md` under 500 lines; put detail in `references/`.
- No em or en dashes. Short lines and tables over paragraphs.
- Say what you tested and how.

## Versioning

- [Semantic versioning](https://semver.org/): a fix is a patch, a new question or step is a minor,
  a change that breaks an existing site's config or code is a major.
- The version lives only in `.claude-plugin/plugin.json`: never in `marketplace.json`, and never
  in `SKILL.md` (`check-skill.sh` fails if `SKILL.md` carries a version that differs).
- Every release bumps it and adds a `CHANGELOG.md` entry. Claude Code updates an installed plugin
  only when that number changes.
- The plugin's `description` is the same sentence in `plugin.json` and in `marketplace.json`
  (`claude plugin details` shows the marketplace one). Change both together.
- Releases are cut by the maintainers of `BespokeWoodcraftStudio/entra-id-auth`.
- The Better Auth version sites install is pinned exactly, in the skill (`detect-site.sh`, `verify-site.sh`,
  `references/`, template comments), in `README.md` and in `test-harness/package.json` and its lock. A bump moves every one of them in the same pull
  request. Dependabot ignores `better-auth` for that reason.

## Releasing

| # | Step |
|---|---|
| 1 | Bump `version` in `.claude-plugin/plugin.json`; add the `CHANGELOG.md` entry with today's date |
| 2 | All seven checks pass locally, including `leak-check.sh --history` (a maintainer with a private word list sets `LEAK_WORDS_FILE` to it) |
| 3 | Push to `main`; CI is green |
| 4 | Tag `v<version>` on that commit and push the tag; the CHANGELOG links point at it |

## Once: making the repository public

Before the first push. Setting `git config`
alone changes only later commits: every commit already made keeps its author, committer, files
and message, and all of them are public after the push. So the history is rebuilt, in place, as
one root commit under the repository identity.

| # | Step |
|---|---|
| 1 | The owner confirms the copyright holder in `LICENSE` (change that one line if needed; `leak-check.sh` reads the holder from it, so nothing else changes). Set the date of the `CHANGELOG.md` entry to the publish day, so the one root commit is the release commit. The owner also checks the owning account's public profile name, which anyone who clicks the owner link sees |
| 2 | Commit every change: `git status --porcelain` prints nothing, `git for-each-ref` lists only `refs/heads/main`, and `git stash list` is empty |
| 3 | Rebuild the history in place: the commands below |
| 4 | The proof: `git rev-list --all \| wc -l` prints `1`; `git log --all --format='%an <%ae> \| %cn <%ce>'` shows only the repository identity; `git fsck --unreachable --no-reflogs` prints nothing; `LEAK_WORDS_FILE=<private list> LEAK_IDENTITY="$NAME <$EMAIL>" bash .github/scripts/leak-check.sh --history` passes, and passes again with no word list |
| 5 | Create the repository, then turn on private vulnerability reporting: `gh api -X PUT repos/BespokeWoodcraftStudio/entra-id-auth/private-vulnerability-reporting` (or Settings > Security) |
| 6 | Push, confirm CI is green, and tag the root commit `v<the version in .claude-plugin/plugin.json>`, the one release the CHANGELOG links to |
| 7 | Walk the front door once for real, before anyone is given the line: in a fresh `CLAUDE_CONFIG_DIR="$(mktemp -d)"`, tell Claude Code "Go to https://github.com/BespokeWoodcraftStudio/entra-id-auth and do the setup". Check that it reads the raw `SETUP.md` link in README. Also run `bash skills/entra-id-auth/scripts/preflight.sh` once in a folder linked to a real Vercel project and check that `domains on this project` lists that project's own domains (the stubs cannot prove the real `vercel api` call). Check that `claude plugin marketplace add BespokeWoodcraftStudio/entra-id-auth`, the install and `claude plugin details entra-id-auth@entra-id-auth` work (one skill). Delete that folder after |

The rebuild, step 3. `EMAIL` is the account's GitHub no-reply address, shown under GitHub
Settings > Emails ("Keep my email addresses private"): the account's numeric id, a `+`, the
account name, then `@users.noreply.github.com`. The line below keeps the no-reply address this
folder already has; only when it has none does it fall back to the plain form, which names no
person and passes the leak check.

```bash
NAME=BespokeWoodcraftStudio
EMAIL="$(git config user.email || true)"
case "$EMAIL" in *@users.noreply.github.com) ;; *) EMAIL="${NAME}@users.noreply.github.com" ;; esac
git config user.name "$NAME"
git config user.email "$EMAIL"
git checkout --orphan first-public
git add -A
git commit -m "entra-id-auth: first public release"
git branch -D main
git branch -m main
git reflog expire --expire=now --all
git gc --prune=now
git log --all --format='%an <%ae> | %cn <%ce>'
```

The commit message names no private build or organisation. Every later commit subject says what
changed in plain words ("Version 1.1.0: check pages before they render"), never an internal
process label such as a review round. The `git config` lines stay, so every
later commit in this folder carries the repository identity too. Nothing of the old history is
left to push: no branch, no reflog, no loose or packed object.
