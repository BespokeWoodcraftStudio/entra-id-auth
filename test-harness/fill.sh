#!/usr/bin/env bash
# Fills fresh copies of skills/entra-id-auth/templates with obvious contoso
# placeholder values, one copy per settings variant, in test-harness/.work.
# The unit tests then run against every copy (see vitest.config.mts), so every
# ROLE_SOURCE and JOIN_MODE pair, and both ALLOW_GUESTS values under
# JOIN_MODE=group, are proven on every run.
#
# Nothing here calls Microsoft, Vercel or a database.
#
# Usage: bash fill.sh   (npm test runs it first)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$(cd "$HERE/../skills/entra-id-auth/templates" && pwd)"
WORK="$HERE/.work"

# The placeholders copy-templates.sh fills on a real site (DESIGN.md section 9),
# set to values that are plainly not real.
export F_SITE_NAME="Contoso Portal"
export F_EMAIL_DOMAINS="contoso.com,fabrikam.com"
export F_DOMAIN="portal.contoso.com"
export F_VERCEL_HOST="contoso-portal.vercel.app"
export F_SRC_ROOT="src"
export F_SESSION_IDLE_MINUTES="60"
export F_SESSION_MAX_HOURS="12"

# name:ROLE_SOURCE:JOIN_MODE:ALLOW_GUESTS. Four copies cover every pair a site can
# be set up with; the two JOIN_MODE=group copies take each ALLOW_GUESTS value,
# the only mode where that setting decides a sign-in. A fifth, site-home, is the
# first one with "/" added to PUBLIC_PATHS, as a site with a public landing page
# has it: its whole unit run (page-checks.test.ts included) must pass too.
VARIANTS="site-listed:site:listed:no entra-group:entra:group:no site-group:site:group:yes entra-listed:entra:listed:no site-home:site:listed:no"

rm -rf "$WORK"
mkdir -p "$WORK"

for v in $VARIANTS; do
  IFS=: read -r name role join guests <<<"$v"
  dest="$WORK/$name"
  mkdir -p "$dest"
  cp -R "$TEMPLATES/." "$dest/"
  export F_ROLE_SOURCE="$role" F_JOIN_MODE="$join" F_ALLOW_GUESTS="$guests"

  # shellcheck disable=SC2016 # perl reads $ENV itself; the shell must not expand it.
  find "$dest" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.json' -o -name '*.sql' -o -name '.env.example' \) -print0 |
    xargs -0 perl -pi -e '
      s/__SITE_NAME__/$ENV{F_SITE_NAME}/g;
      s/__EMAIL_DOMAINS__/$ENV{F_EMAIL_DOMAINS}/g;
      s/__DOMAIN__/$ENV{F_DOMAIN}/g;
      s/__VERCEL_HOST__/$ENV{F_VERCEL_HOST}/g;
      s/__SRC_ROOT__/$ENV{F_SRC_ROOT}/g;
      s/__SESSION_IDLE_MINUTES__/$ENV{F_SESSION_IDLE_MINUTES}/g;
      s/__SESSION_MAX_HOURS__/$ENV{F_SESSION_MAX_HOURS}/g;
      s/__ROLE_SOURCE__/$ENV{F_ROLE_SOURCE}/g;
      s/__JOIN_MODE__/$ENV{F_JOIN_MODE}/g;
      s/__ALLOW_GUESTS__/$ENV{F_ALLOW_GUESTS}/g;
    '

  if [ "$name" = site-home ]; then
    perl -pi -e 's|PUBLIC_PATHS = \["/sign-in", "/api/auth"\] as const|PUBLIC_PATHS = ["/", "/sign-in", "/api/auth"] as const|' "$dest/src/lib/auth/settings.ts"
    grep -q 'PUBLIC_PATHS = \["/", ' "$dest/src/lib/auth/settings.ts" || { echo "STOP: site-home did not get / in PUBLIC_PATHS (settings.ts changed?)" >&2; exit 1; }
  fi

  # Every placeholder a template uses must be one this harness (and so the
  # skill) knows. A new one left unfilled fails here, not on someone's site.
  if left="$(grep -rnoE '__[A-Z][A-Z0-9_]*__' "$dest" || true)" && [ -n "$left" ]; then
    echo "STOP: placeholders left unfilled in $name:" >&2
    echo "${left//$dest\//}" >&2
    exit 1
  fi

  # A tsconfig per copy, so "@/..." resolves to that copy's own src.
  cat >"$dest/tsconfig.json" <<JSON
{
  "extends": "../../tsconfig.json",
  "compilerOptions": { "paths": { "@/*": ["./src/*"] } },
  "include": ["src/**/*.ts", "src/**/*.tsx", "tests/**/*.ts", "scripts/**/*.ts", "examples/**/*.ts", "examples/**/*.tsx", "next.config.ts"]
}
JSON
  echo "filled $name (ROLE_SOURCE=$role, JOIN_MODE=$join, ALLOW_GUESTS=$guests)"
done
