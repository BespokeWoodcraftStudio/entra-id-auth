# AGENTS.md

**Asked to "do the setup"?** Follow [`SETUP.md`](SETUP.md).

**Setting up a site?** Follow [`skills/entra-id-auth/SKILL.md`](skills/entra-id-auth/SKILL.md),
from the site's folder, and nothing else in this repository.

**Changing this repository?** The rules below.

## Rules for changing this repository

| Rule | Detail |
|---|---|
| No private data, no real ids | no organisation, person, domain, email address, tenant id, client id, internal ticket id or local path, in any file, comment or test |
| Placeholders only | `contoso.com`, `fabrikam.com`, `example.com`, `org.example`, `.invalid`, and the all-zero GUID `00000000-0000-0000-0000-000000000000` |
| Plan, then run | every write in `skills/entra-id-auth/scripts/` goes through the plan step first and runs only in run mode, after a yes |
| Nothing real in tests or CI | stubs for `az`, `vercel` and `gh` in `tests/scripts/stubs/`; never a real tenant, Graph, Vercel or website call |
| Shell | every script passes `bash -n` and `shellcheck` with no findings |
| Runbook size | `SKILL.md` stays under 500 lines; detail goes in `references/` |
| Portable skill | frontmatter keys only `name`, `description`, `license`, `compatibility`, `metadata`; `name` equals the folder |
| Releases | bump `version` in `.claude-plugin/plugin.json` (the only place it lives) and add a `CHANGELOG.md` entry on every release |
| Writing | no em or en dashes; short lines and tables |
| Design first | read [`docs/DESIGN.md`](docs/DESIGN.md) section 2 before changing a key choice |

## Checks to run before every commit

The seven checks in [`CONTRIBUTING.md`](CONTRIBUTING.md), "Run the checks locally", every one,
because a release goes straight to `main` and every install reads `main`:

```bash
CLAUDE_CONFIG_DIR="$(mktemp -d)" claude plugin validate . --strict
CLAUDE_CONFIG_DIR="$(mktemp -d)" claude plugin validate .claude-plugin/plugin.json --strict
bash .github/scripts/check-skill.sh
find skills/entra-id-auth/scripts tests/scripts .github/scripts test-harness -path test-harness/node_modules -prune -o -type f \( -name '*.sh' -o -path 'tests/scripts/stubs/*' \) -exec sh -c 'for f; do bash -n "$f" || exit 1; done' _ {} +
find skills/entra-id-auth/scripts tests/scripts .github/scripts test-harness -path test-harness/node_modules -prune -o -type f \( -name '*.sh' -o -path 'tests/scripts/stubs/*' \) -exec shellcheck -x -P SCRIPTDIR {} +
bash tests/scripts/run.sh
(cd test-harness && npm ci && npm test)
(cd test-harness && TEST_DATABASE_URL=postgres://localhost:<port>/<empty db> npm run test:db)
bash .github/scripts/leak-check.sh
bash .github/scripts/leak-check.sh --history
```

The database test needs a throwaway Postgres on this machine. `db.sh` refuses an address that is
not on this machine, and a database holding any table other than the test's own, because the
test pushes its schema with `--force`, which can drop any other table.

The public history starts at one root commit under the repository identity (the in-place rebuild
in [`CONTRIBUTING.md`](CONTRIBUTING.md), "Once: making the repository public"), and
this folder's `git config user.name` and `user.email` are that identity. `--history` must pass,
with no word list and with one; if it fails, never push.

The same seven checks run in CI: [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
More in [`CONTRIBUTING.md`](CONTRIBUTING.md). The public repo is `BespokeWoodcraftStudio/entra-id-auth`.
