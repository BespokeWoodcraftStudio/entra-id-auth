# Setup, for an AI agent

A person sent you here and asked you to "do the setup". This file is the whole job. Follow it top
to bottom. Afterwards the person can add Microsoft Entra ID sign-in to a website by saying
"set up Entra ID sign-in on this site".

The person may send you here again later. Check each step first, skip what is already done, and
only fill gaps and update.

## Ground rules

- Never print, echo or ask for a token, password or secret. Never use `sudo`.
- Change nothing in Microsoft 365, Vercel or any website during this setup. Setting up a site is
  the skill's job, later, and it asks first.
- Before each install, sign-in or settings change, ask the person one yes or no question, one tool
  per question. On a no, skip it and carry on.
- If your shell has no keyboard (no TTY), tell the person exactly what to type, click or approve.
  Run each sign-in in the background and read its output for the code or link.
- The Claude config folder is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`. Use it wherever `~/.claude`
  appears below.

## 1. Check (read only)

Run these, then show the person one short table: item, OK or missing, and who fixes it (you or
them).

```bash
pwd; uname -s; uname -m; echo "config: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
claude --version
ls /opt/homebrew/bin/brew /usr/local/bin/brew 2>/dev/null
for t in brew git az vercel node npx psql createdb dropdb openssl curl; do printf '%s: ' "$t"; command -v "$t" || echo MISSING; done
node -v
git config --global user.name; git config --global user.email
pg_isready -h localhost -p 5432
psql -h localhost -p 5432 -d postgres -Atc "select current_user, rolcreatedb from pg_roles where rolname = current_user"
az account show --query "{tenant:tenantId, user:user.name}" -o json
vercel whoami
claude plugin marketplace list --json; claude plugin list
ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/entra-id-auth" 2>/dev/null
```

Then, only if you are Claude Code, find the copy of Claude Code that runs this session:

```bash
b="${CLAUDE_CODE_EXECPATH:-}"; p=$PPID
while [ -z "$b" ] && [ "${p:-1}" -gt 1 ]; do
  c="$(readlink "/proc/$p/exe" 2>/dev/null || ps -o comm= -p "$p")"
  [ "$c" = claude ] && c="$(ps -o args= -p "$p" | awk '{print $1}')"
  case "$c" in */claude) b="$c" ;; esac
  p="$(ps -o ppid= -p "$p" | tr -d ' ')"
done
echo "session: ${CLAUDE_CODE_ENTRYPOINT:-unknown}, binary: ${b:-none}"
[ -n "$b" ] && "$b" --version
```

Keep two things from this for later steps: the folder `pwd` printed, and where you run.

Decide where you run by the first column that tells: the session line, then the binary path, and
only when both say nothing, whether `claude` is found. A desktop app or editor user may also have
`claude` on the PATH, so a found `claude` never outranks the session line.

| Where you run | 1. Session line | 2. Else, the binary path | 3. Else |
|---|---|---|---|
| a terminal | `cli` | any other path | `claude` is found |
| the Claude desktop app | starts with `claude-desktop` | holds `Application Support/Claude` | |
| an editor extension (VS Code, Cursor and others) | `claude-vscode` | holds an editor's `extensions` folder | |
| another agent | you are not Claude Code | | |

What counts as OK:

- Node 22.12 or later on 22, 24, or 26 and later (24 recommended). What `brew install node`
  installs today is fine.
- A Postgres server (15 or later) answering on localhost:5432, with `psql`, `createdb` and `dropdb`
  on the PATH, and the `psql` line printing the person's user with `t` (it may create databases).
  The skill's local test connects as that user with no password. `psql` alone is only a client;
  the server must be installed and running. Postgres is only needed for the skill's local test of
  a site, so a missing one does not block this setup; say what is missing in the table.
- `az` signed in to the person's own Microsoft 365 tenant, and `vercel` signed in.
- The `ls -d` line prints nothing. A printed folder is a hand-made copy of the skill; step 4 says
  what to do with it.
- `brew` is only needed on macOS. If `command -v brew` says MISSING but the `ls` line printed a
  path, Homebrew is installed but not on the PATH: see "Homebrew not on the PATH" in step 2, and
  never give the install line again.
- On a Mac without the command line developer tools, `git` is only a stand-in: `command -v git`
  finds it, and the `git config` line then opens a macOS dialog offering to install the tools.
  Tell the person it is expected: they may say yes, or close it and let the Homebrew install in
  step 2 add the tools.
- `claude` MISSING while you are Claude Code: you run from the desktop app or an editor
  extension, whose own copy of Claude Code is not on the PATH. Do not install it. Steps 4 to 6
  use the binary the session line printed; "`claude` not on the PATH" in step 4 says how.
- `uname -s` prints something starting `MINGW`, `MSYS` or `CYGWIN` (Windows through Git Bash):
  stop here and change nothing. This setup runs only in WSL. Tell the person: "Open PowerShell as
  administrator, run `wsl --install`, and restart the computer. Then open the Ubuntu app, install
  Claude Code there, start `claude` in a folder there, and say: Go to
  https://github.com/BespokeWoodcraftStudio/entra-id-auth and do the setup."
- On Linux or Windows (WSL), there are no brew lines. Give the person the install commands from
  each tool's official install page (or the system's package manager) to run in their own
  terminal, because they need `sudo`. Then run step 1 again.

## 2. Install what is missing (one yes per tool)

- **Homebrew missing on macOS:** the person installs it in Terminal, because it asks for their Mac
  password. Give them this line:

  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

  When it finishes, it prints "Next steps" with lines that put `brew` on the PATH. Without them
  `brew` is not found. Ask them to run these two in the same Terminal (on an Intel Mac, use
  `/usr/local/bin/brew` in place of `/opt/homebrew/bin/brew`):

  ```bash
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ```

  Then give them the restart below, word for word, and stop here.

  **The restart.** A session keeps the PATH it started with, so a new tool is found only after a
  restart. Give the person the line for where you run (step 1), word for word, with `<folder>`
  filled in from step 1's `pwd` and `<editor>` or `<agent>` named:

  | Where you run | Tell the person |
  |---|---|
  | a terminal | "Type /exit, open a new Terminal window, run `cd '<folder>'`, then `claude --continue`, and say: carry on with the setup." |
  | the Claude desktop app | "Quit the Claude app fully (Cmd+Q), open it again, open this conversation from the sidebar, and say: carry on with the setup." |
  | an editor extension | "Quit <editor> fully (Cmd+Q, not only the window), open it again on <folder>, reopen this conversation from the Claude panel's history, and say: carry on with the setup." |
  | another agent | "Close <agent>, open a new terminal window, start <agent> again in <folder>, and say: Go to https://github.com/BespokeWoodcraftStudio/entra-id-auth and do the setup. (It checks each step and skips what is done.)" |

  End every restart message except the "another agent" row (it already carries the line) with
  this sentence, word for word: "If it no longer knows the setup,
  start a new conversation in <folder> and say: Go to
  https://github.com/BespokeWoodcraftStudio/entra-id-auth and do the setup." A repeat run checks
  each step and skips what is done.

  In the desktop app or an editor, if `brew` is still MISSING after the restart although a new
  Terminal window finds it, the app did not read `~/.zprofile`. Ask one yes, add the same `eval`
  line to `~/.zshrc`, and give the restart again.

- **Homebrew not on the PATH** (step 1's `ls` printed a path, `brew` is MISSING): do not install
  it again. Ask the person to run the two lines just above in Terminal, with the path step 1
  printed, then give them the restart above, word for word.

- **Each tool, only if missing:**

  ```bash
  brew install azure-cli
  brew install vercel
  brew install node
  brew install postgresql@17 && brew link --force postgresql@17 && brew services start postgresql@17
  ```

  Install Postgres only when none is installed at all. If one is installed but not answering,
  offer to start it instead (`brew services start <that formula>`, or open Postgres.app).

- **Postgres answers, but the person's user is refused or cannot create databases** (common with
  a Linux distribution's package, which makes only the `postgres` user): the person runs this in
  their own terminal, because it needs `sudo`:

  ```bash
  sudo -u postgres createuser --createdb "$USER"
  ```

  Or tell them the skill will ask for a database address with a user and password instead.

- **Node too old** (older than 22.12, or a 23 or 25). Run `command -v node` to see where it comes
  from, then ask one yes and give the person the matching line to run in their own Terminal:

  | Where `node` comes from | The fix |
  |---|---|
  | nvm (a path under `.nvm`) | `nvm install 24 && nvm alias default 24` |
  | fnm, volta, asdf or mise | that manager's install of Node 24, set as its default (`fnm install 24 && fnm default 24`, `volta install node@24`, `mise use -g node@24`, or asdf's install then `asdf set -u nodejs <version>` (asdf older than 0.16: `asdf global nodejs <version>`)) |
  | Homebrew's `node` | `brew upgrade node` |
  | a Homebrew keg such as `node@20` (the path holds `node@`) | `brew install node@24`, then in `~/.zprofile` (or wherever the old keg is put on the PATH) change `node@20` to `node@24` |
  | Linux or WSL (apt, dnf, pacman) | the NodeSource lines for Node 24 from https://github.com/nodesource/distributions (they need `sudo`, so the person runs them), or nvm as above, which needs no `sudo` |

  A version manager that comes first on the PATH decides which `node` runs: set its default
  rather than installing another copy. Then give the person the restart above, word for word,
  because this session keeps the old PATH and still sees the old Node.

- **git name or email missing:** ask for them, then set them with `git config --global`.

- A failed install: stop and show the error. Never work around it with `sudo`.

- If a tool you just installed is still not found, or `node -v` still shows the old version, give
  the person the restart above, word for word. If `node -v` in their new Terminal window is still
  old, the fix did not take: check which `node` comes first on the PATH.

## 3. Sign in (one yes each)

These are for when the skill runs. Doing them now saves time later.

- **Microsoft.** Ask for the person's work domain (for example `contoso.com`). Then run in the
  background:

  ```bash
  az login --tenant <their domain> --allow-no-subscriptions
  ```

  A browser opens and they sign in with their work account. Confirm with `az account show`. If it
  fails with AADSTS53003, a Conditional Access policy in their organisation blocked this sign-in
  (often a managed-device or location rule). Tell them plainly to ask their Microsoft 365
  administrator which rule it was. If it is a device rule, the skill's Microsoft steps must run on
  a managed computer.

- **Vercel.** Run `vercel login` in the background. Show them the link and code it prints. Confirm
  with `vercel whoami`.

## 4. Install or update the skill (one yes covers this step)

This repository is a Claude Code plugin marketplace called `entra-id-auth`. It is public, so no
GitHub sign-in is needed.

- If `claude plugin list` shows `entra-id-auth@<another marketplace>` (an older or forked copy),
  tell the person, ask one yes, then run `claude plugin uninstall entra-id-auth@<that marketplace>`.
  Two copies with one name both load, and the older one can answer "set up Entra ID sign-in".

- If step 1's `ls -d` line printed a folder, it is an older hand-made copy of the skill (README,
  "Without the plugin"). It is never updated by the plugin and it also loads. Tell the person, ask
  one yes, then remove it:

  ```bash
  rm -rf "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/entra-id-auth"
  ```

  On a no, they keep the copy method: do not install the plugin. Run the "Not Claude Code?" block
  below, then README's replace line (`rm -rf` of that folder, then `cp -R` from
  `~/entra-id-auth`), skip steps 5 and 6, and say so in step 7.

- If `entra-id-auth` is not in `claude plugin marketplace list --json`:

  ```bash
  claude plugin marketplace add BespokeWoodcraftStudio/entra-id-auth
  ```

- If it is already there, first check where it points: its `repo` (or `url` or `path`) in that
  list must name `BespokeWoodcraftStudio/entra-id-auth`. A fork keeps the name `entra-id-auth`,
  so the name alone proves nothing. If it names anything else, tell the person which repository
  it is, ask one yes, then run the line below (it also uninstalls that copy's plugin) and carry on
  with the add above and the install below, as on a first run. Adding this repository on top of
  it is refused.

  ```bash
  claude plugin marketplace remove entra-id-auth
  ```

- If it is already there and points here, do not add it again, because a repeat add switches off
  automatic updates. Run:

  ```bash
  claude plugin marketplace update entra-id-auth
  ```

- Then, if `entra-id-auth@entra-id-auth` is not in `claude plugin list`:

  ```bash
  claude plugin install entra-id-auth@entra-id-auth
  ```

  If it is there already: `claude plugin update entra-id-auth@entra-id-auth`.

- If `marketplace add` fails: an SSH message ("Host key verification failed", "Permission denied
  (publickey)") only means the HTTPS try failed first and Claude Code then tried SSH. Do not
  change SSH settings, and never run `ssh -T` or `ssh-keyscan`. To see why HTTPS failed, run:

  ```bash
  GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/BespokeWoodcraftStudio/entra-id-auth.git HEAD
  ```

  "could not read Username" or "repository not found": the name is mistyped, or the repository is
  private or not published yet; check the name exactly as written above. A proxy, certificate or
  connection error: the network, which the person or their IT fixes. Tell the person which it is
  and stop. If it prints a commit id, HTTPS works now (the first try hit a passing network
  fault): run the `marketplace add` line once more. If it fails the same way again, tell the
  person and stop.

- **`claude` not on the PATH** (step 1): run steps 4 to 6 exactly as written with the binary the
  session line printed, in double quotes, in place of `claude`, for example
  `"<that path>" plugin marketplace list --json`. The path may hold a space. Write it out in every
  command, because your shell may not keep a variable from one command to the next. Typing
  `/plugin marketplace add ...` in the desktop app or an editor does not work there.

- **No binary either** (the session line printed `none`, or `--version` failed): read the files in
  place of the list commands, and the person uses the app's own plugin screen.
  - Marketplaces: the keys of `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/known_marketplaces.json`,
    each with its `source` (`source.repo`, `source.url` or `source.path`).
  - Plugins: `.plugins` in `.../plugins/installed_plugins.json` maps each plugin id to a list of
    install records, one per scope. Read `version` and `installPath` from the record whose
    `scope` is `user`. With `jq` (or read the file):

    ```bash
    jq -r '[.plugins["entra-id-auth@entra-id-auth"][]? | select(.scope=="user")][0] | .version, .installPath' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
    ```

  - An `entra-id-auth@<another marketplace>` key: tell the person, ask one yes, and they uninstall
    that copy (editor: `/plugins`, Plugins, `entra-id-auth@<that marketplace>`, Uninstall;
    desktop app: + > Plugins, that copy, Uninstall).
  - `entra-id-auth` already a marketplace whose source does not name
    `BespokeWoodcraftStudio/entra-id-auth`: tell the person which repository it is, ask one yes,
    and they remove that marketplace in the plugin screen (Marketplaces, `entra-id-auth`, Remove),
    then add and install as below.
  - `entra-id-auth` already a marketplace that points here: they update it in the plugin screen
    and do not add it again. Otherwise they add the marketplace
    `BespokeWoodcraftStudio/entra-id-auth`, then install `entra-id-auth` for themselves (user
    scope).

  | Where you run | The plugin screen |
  |---|---|
  | an editor extension | type `/plugins`, open Marketplaces, enter `BespokeWoodcraftStudio/entra-id-auth`, then Plugins, `entra-id-auth`, Install for you. In VS Code this link does both: `vscode://anthropic.claude-code/install-plugin?plugin=entra-id-auth&marketplace=BespokeWoodcraftStudio/entra-id-auth` |
  | the desktop app | + > Plugins > Add plugin, enter `BespokeWoodcraftStudio/entra-id-auth`, then install `entra-id-auth` |

  Then read the two files again for step 6.

**Not Claude Code?** Keep a copy of this repository at `~/entra-id-auth`, outside every website
(not a temporary folder: the skill is read from it later):

```bash
if [ -e ~/entra-id-auth/.git ]; then
  u="$(git -C ~/entra-id-auth config --get remote.origin.url 2>/dev/null | sed -E 's#^(https?://)[^/]*@#\1#')"
  l="$(printf '%s' "${u%/}" | tr '[:upper:]' '[:lower:]')"
  case "$l" in
    https://github.com/bespokewoodcraftstudio/entra-id-auth|https://github.com/bespokewoodcraftstudio/entra-id-auth.git|git@github.com:bespokewoodcraftstudio/entra-id-auth|git@github.com:bespokewoodcraftstudio/entra-id-auth.git|ssh://git@github.com/bespokewoodcraftstudio/entra-id-auth|ssh://git@github.com/bespokewoodcraftstudio/entra-id-auth.git)
      git -C ~/entra-id-auth pull --ff-only ;;
    *)
      echo "FOREIGN: ${u:-no origin}"; false ;;
  esac
elif [ -e ~/entra-id-auth ] || [ -L ~/entra-id-auth ]; then
  echo "NOT-A-REPO: $HOME/entra-id-auth"; false
else
  git clone https://github.com/BespokeWoodcraftStudio/entra-id-auth ~/entra-id-auth
fi
```

The block pulls only when the folder's origin is this repository (over HTTPS or SSH, in any
letter case). It reads the origin as stored, so a `url.<x>.insteadOf` rewrite in the person's git
config neither refuses this repository nor prints a rewritten URL. If it prints `FOREIGN:` (another
repository) or `NOT-A-REPO:` (a folder or file that is not a git clone), nothing was pulled: tell the
person what the folder holds, ask one yes, move it aside to a name that is free
(`mv ~/entra-id-auth ~/entra-id-auth.old-$(date +%Y%m%d%H%M%S)`), and run the block again, which
then clones. When the origin matches but `git pull --ff-only` fails (offline, local edits, a
diverged copy), show git's message, say the copy was left as it was, and stop.

When the person wants a site set up, work from the site's folder, read
`~/entra-id-auth/skills/entra-id-auth/SKILL.md` and follow it exactly. Skip steps 5 and 6.

## 5. Automatic updates

Third-party marketplaces do not update on their own by default. Read
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`. If
`extraKnownMarketplaces.entra-id-auth.autoUpdate` is not `true`, ask the person, in these words:
"New versions of this skill will install on their own. It runs with your Microsoft 365 admin and
Vercel sign-ins, and it still shows every change before it makes it. Turn automatic updates on?"
Recommend yes only if they trust the owner of this repository. On a yes, add
`"autoUpdate": true` beside `source` in that entry. Keep every other key exactly as it is. They
will see a permission prompt, because it is a protected file. If they want it on but decline the
file edit, tell them the other way: type `/plugin` (in an editor `/plugins`; in the desktop app
+ > Plugins), open Marketplaces, pick entra-id-auth, choose "Enable auto-update". If they do not
want it on, tell them how to update by hand later: run
`claude plugin marketplace update entra-id-auth`, then
`claude plugin update entra-id-auth@entra-id-auth`, in that order.

## 6. Confirm

```bash
claude plugin marketplace list --json
claude plugin list --json
claude plugin details entra-id-auth@entra-id-auth
```

Report that the marketplace `entra-id-auth` points at `BespokeWoodcraftStudio/entra-id-auth`;
from the entry whose `id` is `entra-id-auth@entra-id-auth`, that it is enabled and its version;
that the details show one skill, `entra-id-auth`; that no other `entra-id-auth@...` entry is
left; and that step 1's `ls -d` line now prints nothing (no hand-made copy in the user skills
folder). Always name the full id: the bare name can resolve to another copy. With no binary (step 4),
read the same from the files: the marketplace's `source` in `known_marketplaces.json`; the
`version` in the `user` record of `.plugins["entra-id-auth@entra-id-auth"]` (a list, one record
per scope) in `installed_plugins.json`; `true` under `enabledPlugins` in `settings.json`; and no
other `entra-id-auth@...` key in either. You cannot load the new skill into this session
yourself: only the person can, by typing `/reload-plugins` or starting a new session.

If they want a site set up in this same session without reloading, take the `installPath` of
`entra-id-auth@entra-id-auth` (from its entry in `claude plugin list --json`, or from the `user`
record in `installed_plugins.json`, with the `jq` line in step 4)
and, from the site's folder, read `<installPath>/skills/entra-id-auth/SKILL.md` and follow it
exactly.

## 7. Tell the person, in these words or close

- "Setup is done. Type /reload-plugins now, or start a new conversation." (Other agents: "Setup
  is done." Claude Code with the copy method kept in step 4: "Setup is done. Start a new Claude
  Code session in the site's folder.")
- Claude Code: "To add Microsoft sign-in to a website: open a Claude Code conversation in the
  website's folder and say: set up Entra ID sign-in on this site."
- Other agents: "To add Microsoft sign-in to a website: in the website's folder, tell your agent:
  Read ~/entra-id-auth/skills/entra-id-auth/SKILL.md and follow it for this site."
- "It looks at the site and your Microsoft 365 first without changing anything, asks you a few
  questions, then shows every step and runs it only when you say yes."

Finish with a short summary: what you installed, updated or signed in, what you skipped, and
anything still missing and who fixes it.
