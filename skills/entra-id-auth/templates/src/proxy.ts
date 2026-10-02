/**
 * The first page check, and the CSP.
 *
 * Next.js 16 names this file proxy.ts (export `proxy`) and always runs it on
 * the Node.js runtime; it refuses a `runtime` line here, so the template has
 * none. On Next.js 15 (15.5 or later) name it middleware.ts, the export
 * `middleware`, and add runtime: "nodejs" to `config` at the end: the check
 * below reads the database, which the Edge runtime cannot. With a src folder
 * it must sit in src/, beside app/; one at the project root never runs.
 *
 * It runs on every request except Next's own static files, so every page gets
 * a fresh CSP nonce. On every path that is not public it reads the person in
 * full before anything renders: the session in the database, the person on
 * the list and switched on, the session under its absolute limit
 * (personFromHeaders in current-person.ts). A made-up, expired or refused
 * session gets a 307 to /sign-in (a 401 on /api/*) and no page, layout or
 * handler code runs, whatever RSC headers the request carries (control C26).
 *
 * It is not the only check. Every page, layout, template and default file on
 * a gated path calls requirePagePerson() first (page-checks.test.ts fails on one whose
 * default export does not start with it), and every exported method of every
 * route handler calls requireCurrentPerson() or requireAdministrator() first.
 * A layout's redirect alone protects nothing: Next renders a layout and its
 * page in parallel, so a page with no check of its own is sent in the body of
 * the layout's 307.
 */
import { getSessionCookie } from "better-auth/cookies";
import { NextResponse, type NextRequest } from "next/server";

import { isPublicPath, isStaticAsset } from "@/lib/auth/route-access";
import { buildCsp, newNonce } from "@/lib/auth/security-headers";

// Kept a plain function returning a promise: the Next 15 copy renames this
// exact line to `export function middleware(`.
export function proxy(request: NextRequest): Promise<NextResponse> {
  return gate(request);
}

/**
 * A cookie with the session cookie's name is only a hint: the person behind
 * it is read in full. current-person.ts is loaded on first use, so a public
 * path (sign-in, health) never loads the database code and still answers when
 * the sign-in settings are broken.
 */
async function signedIn(request: NextRequest): Promise<boolean> {
  if (!getSessionCookie(request)) return false;
  const { personFromHeaders } = await import("@/lib/auth/current-person");
  return (await personFromHeaders(request.headers)) !== null;
}

async function gate(request: NextRequest): Promise<NextResponse> {
  const { pathname, search } = request.nextUrl;
  if (isStaticAsset(pathname)) return NextResponse.next();

  if (!isPublicPath(pathname) && !(await signedIn(request))) {
    // An API caller gets a plain 401, not an HTML sign-in page it cannot use.
    if (pathname.startsWith("/api/")) {
      return NextResponse.json({ error: "not_signed_in" }, { status: 401, headers: { "Cache-Control": "no-store" } });
    }
    const signIn = new URL("/sign-in", request.url);
    const next = `${pathname}${search}`;
    // Path and query only; nextUrl never carries another host. The sign-in
    // page still runs it through safeNextPath before using it.
    if (next !== "/") signIn.searchParams.set("next", next);
    return NextResponse.redirect(signIn);
  }

  if (pathname.startsWith("/api/")) return NextResponse.next();

  const nonce = newNonce();
  const csp = buildCsp({
    nonce,
    development: process.env.NODE_ENV === "development",
    preview: process.env.VERCEL_ENV === "preview",
  });
  const requestHeaders = new Headers(request.headers);
  requestHeaders.set("x-nonce", nonce);
  requestHeaders.set("Content-Security-Policy", csp);
  const response = NextResponse.next({ request: { headers: requestHeaders } });
  response.headers.set("Content-Security-Policy", csp);
  return response;
}

// Everything except Next's own static files. Prefetches are gated too: the
// gate matters more than skipping a header on a prefetch. On Next 15, as
// middleware.ts, add runtime: "nodejs" as the first line inside this object.
export const config = {
  matcher: ["/((?!_next/static(?:/|$)|_next/image(?:/|$)|favicon\\.ico$).*)"],
};
