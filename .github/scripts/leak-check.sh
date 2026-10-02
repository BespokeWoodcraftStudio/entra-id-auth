#!/usr/bin/env bash
# Leak check: fails when the repository holds a name, address, id or path that
# has no place in a public repository. It is a denylist, not a secret scanner:
# nothing here should ever hold a real credential, but a comment, an example,
# a test or a commit could still carry something private.
#
# Usage:
#   bash .github/scripts/leak-check.sh            the files in the working tree
#   bash .github/scripts/leak-check.sh --history  every commit: its files, its
#                                                 message, its author and committer
#
# Private words. This public file holds no private word list, not even hashed
# (a bare hash of one word is reversed by guessing). A maintainer who keeps a
# list of words that must never appear (organisation, people, machines) keeps it
# outside this repository and points LEAK_WORDS_FILE at it: one word per line,
# letters and digits only, any case; lines starting with # are skipped. A line
# with anything else (a hyphen, a dot) is split into its letter-and-digit runs,
# and every run is refused, so a shared part such as "tools" in a hyphenated
# repo name flags harmless lines: list only the distinctive part of such a name.
# The check warns on stderr for each such line.
#   LEAK_WORDS_FILE=<path outside the repo> bash .github/scripts/leak-check.sh --history
#
# Identities. --history lists every distinct author and committer. A name is not
# a pattern this file can refuse, so a maintainer checks the list, and before the
# first push sets LEAK_IDENTITY to the one allowed identity, "Name <address>":
# any other author or committer then fails (GitHub's own web-flow identity is
# also allowed).
#
# Scans every file except .git, node_modules and test-harness/.work. This file
# is scanned too, so it spells no pattern out as plain text. Prints file:line
# and the matched text only. Exit 0 when clean, 1 on any hit, 2 on bad usage.
#
# Runs on macOS (bash 3.2, BSD grep) and Linux (GNU grep).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="$HERE/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$HERE/../.." && pwd)"
MODE=tree
# message mode: a folder of commit messages and identities, written by --history.
TEXT_KIND=files

while [ $# -gt 0 ]; do
  case "$1" in
    --history) MODE=history ;;
    --root) ROOT="$(cd "$2" && pwd)"; shift ;;
    --messages) TEXT_KIND=messages ;;
    -h | --help) sed -n '2,29p' "$SELF_PATH"; exit 0 ;;
    *) echo "leak-check: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "${LEAK_WORDS_FILE:-}" ] && [ ! -r "$LEAK_WORDS_FILE" ]; then
  echo "leak-check: LEAK_WORDS_FILE is set but cannot be read." >&2
  exit 2
fi

# --history: run the tree check on every commit's files, then on a folder that
# holds every commit's message and its author and committer lines.
if [ "$MODE" = history ]; then
  cd "$ROOT"
  git rev-parse --git-dir >/dev/null 2>&1 || { echo "leak-check: not a git repository." >&2; exit 2; }
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "leak-check: this is a shallow clone, so older commits cannot be read. Fetch the whole history (actions/checkout with fetch-depth: 0)." >&2
    exit 2
  fi
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  FAIL=0
  COUNT=0
  mkdir -p "$WORK/messages"
  for c in $(git rev-list --all); do
    COUNT=$((COUNT + 1))
    short="$(git rev-parse --short "$c")"
    mkdir -p "$WORK/tree"
    git archive --format=tar "$c" | tar -xf - -C "$WORK/tree"
    if ! out="$(bash "$SELF_PATH" --root "$WORK/tree" 2>&1)"; then
      printf 'In commit %s:\n%s\n\n' "$short" "$out"
      FAIL=1
    fi
    rm -rf "$WORK/tree"
    {
      git log -1 --format='author: %an <%ae>%ncommitter: %cn <%ce>' "$c"
      git log -1 --format='%B' "$c"
    } > "$WORK/messages/commit-$short.txt"
  done
  if ! out="$(bash "$SELF_PATH" --root "$WORK/messages" --messages 2>&1)"; then
    printf 'In commit messages, authors and committers:\n%s\n\n' "$out"
    FAIL=1
  fi
  IDENTITIES="$(git log --all --format='%an <%ae>%n%cn <%ce>' | sort -u)"
  echo "Authors and committers in history:"
  printf '%s\n' "$IDENTITIES" | sed 's/^/  /'
  if [ -n "${LEAK_IDENTITY:-}" ]; then
    others="$(printf '%s\n' "$IDENTITIES" | grep -vxF -e "$LEAK_IDENTITY" -e 'GitHub <noreply@''github.com>' || true)"
    if [ -n "$others" ]; then
      printf 'LEAK: an author or committer other than LEAK_IDENTITY:\n%s\n\n' "$(printf '%s\n' "$others" | sed 's/^/  /')"
      FAIL=1
    fi
  fi
  if [ "$FAIL" -ne 0 ]; then
    echo "History holds what the tree check refuses. Rebuild it as one commit before any push; see CONTRIBUTING.md, 'Once, when the repository is first made public'."
    exit 1
  fi
  echo "leak-check: history clean ($COUNT commits, their messages, authors and committers)."
  exit 0
fi

cd "$ROOT"
LIB="skills/entra-id-auth/scripts/lib.sh"
FAIL=0

# Every file to scan, NUL separated, as ./path.
list_files() {
  find . \
    \( -path ./.git -o -name node_modules -o -path ./test-harness/.work \) -prune \
    -o -type f -print0
}

# grep over the tree: file:line:match, one match per line, text files only.
# Case-insensitive; scan_cs is the case-sensitive form.
scan() {
  list_files | xargs -0 grep -noIiE "$1" 2>/dev/null || true
}
scan_cs() {
  list_files | xargs -0 grep -noIE "$1" 2>/dev/null || true
}

report() {
  local label="$1" hits="$2"
  [ -n "$hits" ] || return 0
  printf 'LEAK: %s\n' "$label"
  printf '%s\n' "$hits" | sed 's/^\.\//  /'
  FAIL=1
}

# 1. Private words (only when LEAK_WORDS_FILE is given), internal ids and local
#    paths. Every run of letters and digits in a file is compared, ignoring case.
scan_private_words() {
  [ -n "${LEAK_WORDS_FILE:-}" ] || return 0
  # shellcheck disable=SC2016 # perl code: its variables are perl's, not the shell's.
  list_files | xargs -0 perl -e '
    open(my $wf, "<", $ENV{LEAK_WORDS_FILE}) or die "cannot read LEAK_WORDS_FILE\n";
    my %w;
    my $ln = 0;
    while (my $x = <$wf>) {
      $ln++;
      next if $x =~ /^\s*#/;
      (my $y = $x) =~ s/^\s+|\s+$//g;
      print STDERR "leak-check: LEAK_WORDS_FILE line $ln holds more than letters and digits; each part is refused on its own\n" if length($y) && $y =~ /[^A-Za-z0-9]/;
      for my $t ($x =~ /([A-Za-z0-9]+)/g) { $w{lc $t} = 1; }
    }
    close $wf;
    for my $f (@ARGV) {
      next if -B $f;
      open(my $fh, "<", $f) or next;
      my $n = 0;
      while (my $l = <$fh>) {
        $n++;
        for my $t ($l =~ /([A-Za-z0-9]+)/g) { print "$f:$n:$t\n" if $w{lc $t}; }
      }
      close $fh;
    }' || true
}
report "a word from the private list" "$(scan_private_words)"
# Internal ticket and decision ids. The [-] classes keep this file from matching itself.
IDS='\bD[-]1[0-9]\b|\bT[-]20[0-9]{2}[-]|\bL[123][-][0-9]|\bK1[-]|\bFU[-]|\bW[0-9]{2}\b'
report "an internal id" "$(scan "$IDS")"
# A macOS or Linux home path. Case-sensitive, so Microsoft Graph's /users/ is not a hit.
report "a local home path" "$(scan_cs '/Use[r]s/[A-Za-z]|/ho[m]e/[a-z]')"

# 2. Names allowed in named files only. Commit messages may carry them anywhere.
allow_only() {
  local label="$1" pattern="$2" allowed="$3" line file hits=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%:*}"
    file="${file#./}"
    case " $allowed " in
      *" $file "*) ;;
      *) hits="${hits}${line}"$'\n' ;;
    esac
  done <<EOF_ALLOW
$(scan "$pattern")
EOF_ALLOW
  report "$label" "${hits%$'\n'}"
}
if [ "$TEXT_KIND" = files ]; then
  OWNER_RE='bespoke[w]oodcraftstudio'
  # The copyright holder is read from LICENSE, so changing that one line is enough.
  # When the holder is the repository owner, the owner check below covers it.
  HOLDER=""
  if [ -f LICENSE ]; then
    HOLDER="$(sed -nE 's/^Copyright \(c\) [0-9]{4}(-[0-9]{4})? +(.+[^ ]) *$/\2/p' LICENSE | head -n 1)"
  fi
  if [ -n "$HOLDER" ] && ! printf '%s\n' "$HOLDER" | grep -qixE "$OWNER_RE"; then
    HOLDER_RE="$(printf '%s' "$HOLDER" | sed -E 's/[][\.*^$+?(){}|/]/\\&/g')"
    allow_only "the copyright holder's name outside LICENSE" "$HOLDER_RE" "LICENSE"
  fi
  allow_only "the repository owner's name outside the files that carry it" \
    "$OWNER_RE" \
    "LICENSE README.md SETUP.md AGENTS.md .github/ISSUE_TEMPLATE/config.yml .claude-plugin/plugin.json .claude-plugin/marketplace.json SECURITY.md CONTRIBUTING.md CHANGELOG.md docs/DESIGN.md skills/entra-id-auth/SKILL.md"
fi

# 3. Email addresses not on a placeholder domain. The reserved .example and
#    .invalid top-level domains (RFC 2606) can never be real addresses. Commit
#    messages and identities may also use the GitHub and Anthropic no-reply addresses.
#    git@github.com is GitHub's SSH login in a clone URL, not a mailbox.
EMAIL='[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}'
PLACEHOLDER_DOMAINS='@([a-z0-9-]+\.)*(contoso\.com|fabrikam\.com|example\.com)$|\.(example|invalid)$|:git@github\.com$'
EMAIL_LABEL="an email address that is not on contoso.com, fabrikam.com, example.com, .example or .invalid"
if [ "$TEXT_KIND" = messages ]; then
  PLACEHOLDER_DOMAINS="$PLACEHOLDER_DOMAINS"'|@users\.noreply\.github\.com$|:(noreply|support)@github\.com$|:noreply@anthropic\.com$'
  EMAIL_LABEL="$EMAIL_LABEL, or a GitHub no-reply address (commit with the one under GitHub Settings > Emails)"
fi
report "$EMAIL_LABEL" "$(scan "$EMAIL" | grep -viE "$PLACEHOLDER_DOMAINS" || true)"

# 4. GUIDs that are not placeholders or Microsoft's public Graph ids.
#    Allowed: all zeros; one hex digit repeated (1111..., 2222... test
#    patterns); all zeros but the last group's tail (numbered stub ids); and
#    every GUID lib.sh assigns to a constant (Microsoft Graph's app id and
#    permission ids, the same in every tenant).
GUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
GRAPH_IDS=""
if [ -f "$LIB" ]; then
  GRAPH_IDS="$(grep -E "^[A-Z_]+=\"$GUID\"" "$LIB" | grep -oE "$GUID" | tr 'A-F' 'a-f' | tr '\n' ' ' || true)"
fi
guid_hits=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  g="$(printf '%s' "${line##*:}" | tr 'A-F' 'a-f')"
  case " $GRAPH_IDS " in *" $g "*) continue ;; esac
  if printf '%s\n' "$g" | grep -qE '^0{8}-0{4}-0{4}-0{4}-0{8}[0-9a-f]{4}$'; then continue; fi
  d="${g:0:1}"
  if [ -z "$(printf '%s' "$g" | tr -d "$d-")" ]; then continue; fi
  guid_hits="${guid_hits}${line}"$'\n'
done <<EOF_GUID
$(scan "$GUID")
EOF_GUID
report "a GUID that is not a placeholder or a Microsoft Graph id from lib.sh" "${guid_hits%$'\n'}"

if [ "$FAIL" -ne 0 ]; then
  echo
  echo "Replace each hit with a placeholder (contoso.com, example.com, 00000000-0000-0000-0000-000000000000)"
  echo "or with the reason in plain words. See CONTRIBUTING.md, 'No private data'."
  exit 1
fi
echo "leak-check: clean."
