#!/usr/bin/env bash
# The live half of the final check, from outside, as a stranger would see it.
#
#   verify-site.sh <domain> [vercel-host] [--tenant <id>] [--no-post] [--base http://localhost:<port>]
#                  [--preview <preview url>] [--probe <signed-in path>] [--public <path>]... [--marker <text>]
#
# GET checks read only. Unless --no-post is given it also sends sign-in
# requests (a sign-up, a password sign-in, a bare id-token sign-in, Microsoft
# sign-in starts from a foreign origin, with a foreign callback, and from the
# real origin). They create nothing but a short-lived sign-in state row, and
# prove the lock-down from outside. --base runs the same checks against a
# local PRODUCTION build (`next build` then `next start`); only HSTS and the
# vercel.app redirect, which a real host answers, are skipped. Under `next dev`
# the test password lane is on by design, so the C27 rows FAIL there.
# --preview <url> adds C38: a preview deployment asked with no cookie must
# answer Vercel Authentication (401, or a redirect to vercel.com/sso), never
# the site itself.
#
# C25 and C26 ask a signed-in page: --probe <path> names one (default /). The
# body of every refused visit is read too, not only its status: a redirect
# that still carries the page's rendered content is a FAIL. --marker <text>
# names a string that appears only on that page (put one there for the check),
# and any C26 answer that holds it FAILs. A path the site made public is not
# a signed-in page: the public paths are read from src/lib/auth/settings.ts
# (PUBLIC_PATHS) in the current folder when it is there, plus each --public.
# When the probe is public, its C25 and C26 rows are N/A and one row FAILs
# until --probe names a signed-in page.
# Exits non-zero when any row FAILs; N/A is not a failure.
set -euo pipefail
usage() { echo "Usage: verify-site.sh <domain> [vercel-host] [--tenant <id>] [--no-post] [--base http://localhost:<port>] [--preview <preview url>] [--probe <signed-in path>] [--public <path>]... [--marker <text>]"; exit 2; }
# A bare lower-case host name: no https://, no path, no port.
is_host() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; }
# value <flag> <next word>: a flag's value is present and is not another flag.
value() { case "${2:-}" in ""|-*) echo "$1 needs a value."; usage ;; esac; }
case "${1:-}" in ""|-*) usage ;; esac
is_host "$1" || { echo "The domain is a bare host name, for example portal.contoso.com (no https://, no path)."; usage; }
DOMAIN="$1"; shift
VERCEL_HOST=""; TENANT=""; POST=yes; BASE=""; PREVIEW=""; PROBE=""; PUBLIC=""; MARKER=""
# A site path: starts with one /, no space, query, fragment or dot segment.
is_path() { printf '%s' "$1" | grep -Eq '^/([A-Za-z0-9._~%!$&()*+,;=:@-]+(/[A-Za-z0-9._~%!$&()*+,;=:@-]+)*)?$' && ! printf '%s' "$1" | grep -Eq '(^|/)\.\.?(/|$)'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --tenant) value "$1" "${2:-}"; TENANT="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2
      printf '%s' "$TENANT" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || { echo "--tenant is the tenant id (a GUID)."; usage; } ;;
    --no-post) POST=no; shift ;;
    --base) value "$1" "${2:-}"; BASE="${2%/}"; shift 2 ;;
    --preview) value "$1" "${2:-}"; PREVIEW="${2%/}"; shift 2
      case "$PREVIEW" in https://*|http://localhost:*|http://127.0.0.1:*) ;; *) PREVIEW="https://$PREVIEW" ;; esac
      case "$PREVIEW" in
        http://localhost:*|http://127.0.0.1:*) printf '%s' "${PREVIEW#http://*:}" | grep -Eq '^[0-9]{2,5}$' ;;
        *) is_host "${PREVIEW#https://}" ;;
      esac || { echo "--preview is a preview deployment's host or https:// URL, for example contoso-portal-git-main-team.vercel.app (no path)."; usage; } ;;
    --probe) value "$1" "${2:-}"; PROBE="${2%/}"; PROBE="${PROBE:-/}"; shift 2
      is_path "$PROBE" || { echo "--probe is a path on the site that only signed-in people see, for example /dashboard (no host, no query)."; usage; } ;;
    --public) value "$1" "${2:-}"; p="${2%/}"; p="${p:-/}"; shift 2
      is_path "$p" || { echo "--public is a path the site made public (in PUBLIC_PATHS), for example /about."; usage; }
      PUBLIC="$PUBLIC $p" ;;
    --marker) value "$1" "${2:-}"; MARKER="$2"; shift 2 ;;
    -*) usage ;;
    *) [ -z "$VERCEL_HOST" ] || { echo "Only one vercel host: $VERCEL_HOST, then $1."; usage; }
       is_host "$1" || { echo "The vercel host is a bare host name, for example contoso-portal.vercel.app."; usage; }
       VERCEL_HOST="$1"; shift ;;
  esac
done
# Preconditions: each stops with its own line and exit 1, never a silent exit.
command -v curl >/dev/null 2>&1 || { echo "STOP: curl is not installed or not on PATH."; exit 1; }
if [ "$POST" = yes ] && ! node -v >/dev/null 2>&1; then
  echo "STOP: node is not on PATH or does not run (a version manager with no version chosen?). The sign-in rows read the authorize URL with node: install Node (see detect-site.sh), or pass --no-post."
  exit 1
fi
LOCAL=no
if [ -n "$BASE" ]; then
  case "$BASE" in http://localhost:*|http://127.0.0.1:*) LOCAL=yes ;; https://*) ;; *) echo "--base is https://<host> or http://localhost:<port>"; exit 2 ;; esac
else BASE="https://$DOMAIN"; fi
FAILS=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# A refused connection is a FAIL row, not a silent stop of the whole check.
c() { curl --max-time 20 "$@" || true; }
# to_sign_in "<status> <location>": a 307 or 308 to exactly /sign-in on this
# site, with or without a query. /sign-in-help/ or another host does not count.
to_sign_in() {
  case "$1" in
    30[78]\ "$BASE/sign-in"|30[78]\ "$BASE/sign-in?"*) return 0 ;;
    30[78]\ "https://$DOMAIN/sign-in"|30[78]\ "https://$DOMAIN/sign-in?"*) return 0 ;;
  esac
  return 1
}
row() { printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4"; [ "$3" = "FAIL" ] && FAILS=$((FAILS+1)); return 0; }
hdr() { printf '%s' "$HEADERS" | tr -d '\r' | { grep -i "^$1:" || true; } | head -1 | cut -d' ' -f2-; }

# The site's public paths: PUBLIC_PATHS in src/lib/auth/settings.ts (or
# lib/auth/settings.ts) in the current folder, when it is there, plus --public.
for f in src/lib/auth/settings.ts lib/auth/settings.ts; do
  [ -f "$f" ] || continue
  found="$(awk '!on && /PUBLIC_PATHS[^=]*=/ {on=1; sub(/^[^=]*=/, "")} on {print} on && /\]/ {exit}' "$f" | grep -Eo '"/[^"]*"' | tr -d '"' | tr '\n' ' ' || true)"
  PUBLIC="$PUBLIC $found"
  echo "Public paths read from $f: ${found:-none}"
  break
done
# is_public <path>: under a public path, a whole segment at a time (as the
# site's route-access.ts matches it).
is_public() {
  local p
  for p in /sign-in /api/auth $PUBLIC; do
    p="${p%/}"; [ -n "$p" ] || { [ "$1" = / ] && return 0; continue; }
    case "$1" in "$p"|"$p"/*) return 0 ;; esac
  done
  return 1
}
PROBE_GIVEN=yes; [ -n "$PROBE" ] || { PROBE=/; PROBE_GIVEN=no; }
if [ "$PROBE_GIVEN" = yes ] && is_public "$PROBE"; then
  echo "--probe $PROBE is a public path on this site: name a page only signed-in people see."; usage
fi
UNLISTED=/some-page-that-was-added-later

# fetch <path> [curl args...]: GET into $TMP/body; prints "<status> <location>".
fetch() { local pth="$1"; shift; : > "$TMP/body"; c -s -o "$TMP/body" -w '%{http_code} %{redirect_url}' "$@" "$BASE$pth"; }
# leak_why: empty when $TMP/body is what a refused visit carries (nothing, or
# a few bytes of plain text); otherwise why it is not. Next renders a page in
# parallel with its layout, so a redirect() thrown by a layout still sends
# the page's rendered payload in the body of the 307.
leak_why() {
  local n
  if [ -n "$MARKER" ] && grep -qF -- "$MARKER" "$TMP/body"; then printf 'the body holds the page marker (%s bytes)' "$(wc -c < "$TMP/body" | tr -d ' ')"; return 0; fi
  n="$(tr -d ' \t\r\n' < "$TMP/body" | wc -c | tr -d ' ')"
  [ "$n" -gt 0 ] || return 0
  if grep -Eq '__next_f|NEXT_REDIRECT|"children"|<html|<body|^[0-9a-f]+:' "$TMP/body" || [ "$n" -gt 512 ]; then
    printf 'the body carries rendered page content (%s bytes); a refused visit is an empty redirect' "$n"
  fi
}
# gate_row <control> <text> <status line> [allow-404]: PASS only on a redirect
# to /sign-in whose body carries nothing of the page.
gate_row() {
  local ctl="$1" text="$2" code="$3" why
  if to_sign_in "$code"; then
    why="$(leak_why)"
    if [ -z "$why" ]; then row "$ctl" "$text" PASS "$code"
    else row "$ctl" "$text" FAIL "${code% }, but $why: the proxy must check the session itself before any page renders (a layout's redirect is not a gate)"; fi
  elif [ "${4:-}" = allow-404 ] && [ "${code%% *}" = 404 ]; then row "$ctl" "$text" PASS "404 (no page at that path)"
  elif [ "${code%% *}" = 200 ]; then
    why="$(leak_why)"
    row "$ctl" "$text" FAIL "200: the page was served${why:+ ($why)}; the proxy must check the session itself before any page renders"
  else row "$ctl" "$text" FAIL "${code% } (expected a redirect to /sign-in)"; fi
}

echo "| # | Check | Result | Evidence |"
echo "|---|---|---|---|"

PROBE_PUBLIC=no; is_public "$PROBE" && PROBE_PUBLIC=yes
if [ "$PROBE_PUBLIC" = yes ]; then
  row C25 "A signed-out visit to $PROBE goes to /sign-in" N/A "$PROBE is public on this site"
  row C26 "A signed-in page is probed" FAIL "$PROBE is public on this site: re-run with --probe <a page only signed-in people see>"
else
  gate_row C25 "A signed-out visit to $PROBE goes to /sign-in" "$(fetch "$PROBE")"
fi
code="$(fetch "$UNLISTED")"
if to_sign_in "$code"; then row C25 "A route nobody listed is gated too" PASS "$code"; else row C25 "A route nobody listed is gated too" FAIL "$code"; fi
code="$(fetch /sign-in-help)"
# Only a redirect to /sign-in itself passes: a correct gate turns a signed-out
# visit away before routing, so a 404 here means the gate let /sign-in-help
# through (prefix match), and a 308 to /sign-in-help/ (trailingSlash) is not
# the gate's answer at all.
if to_sign_in "$code"; then row C25 "An exclusion is a whole segment (/sign-in-help is not public)" PASS "$code"; else row C25 "An exclusion is a whole segment (/sign-in-help is not public)" FAIL "$code"; fi

# C26: a made-up session cookie must get nothing of a signed-in page. Three
# asks for each cookie name: a plain GET of the probe; a plain GET of a path
# with no page (a redirect, or a 404 once the made-up cookie is past the gate);
# and the request Next's own client sends when it moves between two pages
# under the (app) layout (RSC: 1, with a router state saying that layout is
# already on screen), which renders the page without running the layout at all.
TREE="$(printf '%s' '["",{"children":["(app)",{"children":["entra-id-auth-probe",{"children":["__PAGE__",{}]}]}]}]' \
  | od -An -tx1 -v | tr -d ' \n' | sed 's/../%&/g')"
for ck in better-auth.session_token __Secure-better-auth.session_token; do
  if [ "$PROBE_PUBLIC" = yes ]; then
    row C26 "A made-up $ck on $PROBE serves no page" N/A "$PROBE is public on this site"
    row C26 "A made-up $ck on $PROBE with a page-to-page request serves no page" N/A "$PROBE is public on this site"
  else
    gate_row C26 "A made-up $ck on $PROBE serves no page" "$(fetch "$PROBE" -H "Cookie: $ck=made-up.made-up")"
    code="$(fetch "$PROBE" -H "Cookie: $ck=made-up.made-up" -H 'RSC: 1' -H "Next-Router-State-Tree: $TREE")"
    # Next answers an RSC request without its cache key (_rsc) with a redirect
    # to the same path carrying it: that one is followed once, as its client does.
    case "$code" in
      30[78]\ "$BASE$PROBE?_rsc="*|30[78]\ "$BASE$PROBE?"*"&_rsc="*)
        code="$(c -s -o "$TMP/body" -w '%{http_code} %{redirect_url}' -H "Cookie: $ck=made-up.made-up" -H 'RSC: 1' -H "Next-Router-State-Tree: $TREE" "${code#* }")" ;;
    esac
    gate_row C26 "A made-up $ck on $PROBE with a page-to-page request serves no page" "$code"
  fi
  gate_row C26 "A made-up $ck on $UNLISTED serves no page" "$(fetch "$UNLISTED" -H "Cookie: $ck=made-up.made-up")" allow-404
done

HEADERS="$(c -s -D - -o /dev/null "$BASE/sign-in")"
csp="$(hdr content-security-policy)"
if printf '%s' "$csp" | grep -q "frame-ancestors 'none'"; then row C29 "frame-ancestors 'none'" PASS "present"; else row C29 "frame-ancestors 'none'" FAIL "${csp:-no CSP}"; fi
if printf '%s' "$csp" | grep -q "script-src 'self' 'nonce-" && printf '%s' "$csp" | grep -q "default-src 'self'" && printf '%s' "$csp" | grep -q "object-src 'none'" && printf '%s' "$csp" | grep -q "base-uri 'none'"; then row C31 "Full CSP with a nonce" PASS "default-src, script-src nonce, object-src, base-uri"; else row C31 "Full CSP with a nonce" FAIL "${csp:-none}"; fi
if [ "$(hdr x-frame-options)" = "DENY" ]; then row C29 "X-Frame-Options DENY" PASS "DENY"; else row C29 "X-Frame-Options DENY" FAIL "$(hdr x-frame-options)"; fi
if [ "$(hdr x-content-type-options)" = "nosniff" ]; then row C29 "nosniff" PASS "nosniff"; else row C29 "nosniff" FAIL "$(hdr x-content-type-options)"; fi
if hdr permissions-policy | grep -q "camera=()"; then row C29 "Permissions-Policy" PASS "$(hdr permissions-policy)"; else row C29 "Permissions-Policy" FAIL "missing"; fi
if [ "$(hdr referrer-policy)" = "strict-origin-when-cross-origin" ]; then row C32 "Referrer-Policy" PASS "strict-origin-when-cross-origin"; else row C32 "Referrer-Policy" FAIL "$(hdr referrer-policy)"; fi
if [ -z "$(hdr x-powered-by)" ]; then row C32 "No X-Powered-By" PASS "absent"; else row C32 "No X-Powered-By" FAIL "$(hdr x-powered-by)"; fi
if hdr x-robots-tag | grep -q noindex; then row C33 "noindex on every path" PASS "$(hdr x-robots-tag)"; else row C33 "noindex on every path" FAIL "missing"; fi
if [ "$LOCAL" = yes ]; then row C30 "HSTS" N/A "local http run; the host adds it"
elif hdr strict-transport-security | grep -q max-age; then row C30 "HSTS" PASS "$(hdr strict-transport-security)"
else row C30 "HSTS" FAIL "missing"; fi
if hdr cache-control | grep -Eq "no-store|private"; then row C40 "Sign-in page not cached" PASS "$(hdr cache-control)"; else row C40 "Sign-in page not cached" FAIL "$(hdr cache-control)"; fi

body="$(c -s "$BASE/api/health")"
if [ "$body" = '{"ok":true}' ]; then row C35 "Health says ok and nothing else to a stranger" PASS "$body"; else row C35 "Health says ok and nothing else to a stranger" FAIL "$body"; fi
code="$(c -s -o /dev/null -w '%{http_code}' "$BASE/api/cron/credential-check")"
if [ "$code" = "401" ]; then row C34 "Cron route refuses a call with no bearer" PASS "401"; else row C34 "Cron route refuses a call with no bearer" FAIL "$code"; fi
code="$(c -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong' "$BASE/api/cron/credential-check")"
if [ "$code" = "401" ]; then row C34 "Cron route refuses a wrong bearer" PASS "401"; else row C34 "Cron route refuses a wrong bearer" FAIL "$code"; fi

page="$(c -s "$BASE/sign-in")"
if printf '%s' "$page" | grep -q 'sign-in-password'; then row C27 "The sign-in page shows no test password form" FAIL "the test form is on the page (a production build must not show it)"; else row C27 "The sign-in page shows no test password form" PASS "absent"; fi

if [ -n "$VERCEL_HOST" ] && [ "$LOCAL" = no ]; then
  code="$(c -s -o /dev/null -w '%{http_code} %{redirect_url}' "https://$VERCEL_HOST/sign-in")"
  case "$code" in 30[78]\ "https://$DOMAIN/"*) row C24 "The vercel.app host sends pages to the real domain" PASS "$code" ;; *) row C24 "The vercel.app host sends pages to the real domain" FAIL "$code" ;; esac
fi

if [ -n "$PREVIEW" ]; then
  code="$(c -s -o /dev/null -w '%{http_code} %{redirect_url}' "$PREVIEW/")"
  case "$code" in
    401\ *) row C38 "A preview asks for Vercel Authentication" PASS "$code" ;;
    30[1278]\ https://vercel.com/sso*) row C38 "A preview asks for Vercel Authentication" PASS "$code" ;;
    ""|000\ *) row C38 "A preview asks for Vercel Authentication" FAIL "no answer from $PREVIEW" ;;
    *) row C38 "A preview asks for Vercel Authentication" FAIL "${code% }: the site itself answered a stranger, not Vercel Authentication; turn on Vercel Authentication (Standard Protection) in the project's Deployment Protection" ;;
  esac
fi

if [ "$POST" = yes ]; then
  code="$(c -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $BASE" -H 'Content-Type: application/json' \
    --data '{"email":"probe@example.invalid","password":"not-a-real-password-1","name":"probe"}' "$BASE/api/auth/sign-up/email")"
  case "$code" in 4*) row C27 "Sign-up is refused" PASS "$code" ;; *) row C27 "Sign-up is refused" FAIL "$code" ;; esac
  # A wrong password on a lane that is ON is also a 4xx, so the status alone
  # proves nothing: the lane is off only when Better Auth says it is disabled.
  resp="$(c -s -w ' HTTP%{http_code}' -X POST -H "Origin: $BASE" -H 'Content-Type: application/json' \
    --data '{"email":"probe@example.invalid","password":"not-a-real-password-1"}' "$BASE/api/auth/sign-in/email")"
  case "$resp" in *EMAIL_PASSWORD_DISABLED*|*"HTTP404") row C27 "The password lane is off in production" PASS "${resp##* }, disabled" ;; *) row C27 "The password lane is off in production" FAIL "${resp##* }: the lane answered (not disabled)" ;; esac
  # A bare id token must not make a session: that path skips the code flow,
  # PKCE and state, and an id token read from the database could be replayed.
  # Better Auth 1.7.5 and 1.7.6 answer 404 ID_TOKEN_NOT_SUPPORTED when
  # disableIdTokenSignIn is set; 401 INVALID_TOKEN means the path is open.
  resp="$(c -s -w ' HTTP%{http_code}' -X POST -H "Origin: $BASE" -H 'Content-Type: application/json' \
    --data '{"provider":"microsoft","idToken":{"token":"x"}}' "$BASE/api/auth/sign-in/social")"
  case "$resp" in *ID_TOKEN_NOT_SUPPORTED*HTTP4??) row C3 "A bare id-token sign-in is refused" PASS "${resp##* }, ID_TOKEN_NOT_SUPPORTED" ;; *) row C3 "A bare id-token sign-in is refused" FAIL "${resp##* }: expected ID_TOKEN_NOT_SUPPORTED (set disableIdTokenSignIn: true)" ;; esac
  # Better Auth checks Origin only when the request carries a Cookie header, so
  # the probe sends one; without it every correct site would FAIL here.
  code="$(c -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: https://evil.example' -H 'Cookie: probe=1' -H 'Content-Type: application/json' \
    --data '{"provider":"microsoft","callbackURL":"/"}' "$BASE/api/auth/sign-in/social")"
  case "$code" in 403|400) row C20 "A foreign origin cannot start a sign-in" PASS "$code" ;; *) row C20 "A foreign origin cannot start a sign-in" FAIL "$code" ;; esac
  for cb in 'https://evil.example/' '/\\evil.example' '//evil.example'; do
    body="{\"provider\":\"microsoft\",\"callbackURL\":\"$cb\",\"disableRedirect\":true}"
    code="$(c -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $BASE" -H 'Content-Type: application/json' --data "$body" "$BASE/api/auth/sign-in/social")"
    case "$code" in 403|400) row C22 "The server refuses callbackURL $cb" PASS "$code" ;; *) row C22 "The server refuses callbackURL $cb" FAIL "$code" ;; esac
  done
  url="$(c -s -X POST -H "Origin: $BASE" -H 'Content-Type: application/json' \
    --data '{"provider":"microsoft","callbackURL":"/","disableRedirect":true}' "$BASE/api/auth/sign-in/social" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).url||"")}catch{}})')"
  if [ -n "$url" ]; then
    q() { node -e "const u=new URL(process.argv[1]);process.stdout.write(process.argv[2]==='path'?u.pathname:(u.searchParams.get(process.argv[2])||''))" "$url" "$1"; }
    p="$(q path)"
    if [ -n "$TENANT" ]; then
      if [ "$p" = "/$TENANT/oauth2/v2.0/authorize" ]; then row C1 "Authority pinned to the tenant" PASS "$p"; else row C1 "Authority pinned to the tenant" FAIL "$p"; fi
    else
      case "$p" in /common/*|/organizations/*|/consumers/*) row C1 "Authority pinned to the tenant" FAIL "$p" ;; *) row C1 "Authority pinned to the tenant" PASS "$p" ;; esac
    fi
    sc="$(q scope)"
    if [ "$(printf '%s' "$sc" | tr ' ' '\n' | sort | tr '\n' ' ')" = "email openid profile " ]; then row M8 "The site asks for three scopes only" PASS "$sc"; else row M8 "The site asks for three scopes only" FAIL "$sc"; fi
    if [ "$(q code_challenge_method)" = "S256" ]; then row C3 "PKCE S256" PASS "S256"; else row C3 "PKCE S256" FAIL "$(q code_challenge_method)"; fi
    if [ "$(q redirect_uri)" = "$BASE/api/auth/callback/microsoft" ]; then row M3 "redirect_uri is the canonical callback" PASS "$(q redirect_uri)"; else row M3 "redirect_uri is the canonical callback" FAIL "$(q redirect_uri)"; fi
  else
    row C1 "Microsoft sign-in starts" FAIL "no authorize URL came back"
  fi
fi

echo
echo "Failures: $FAILS"
[ "$FAILS" = 0 ]
