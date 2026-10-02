/**
 * Which origins may POST to /api/auth (Better Auth's CSRF origin check).
 *
 * Production: exactly AUTH_TRUSTED_ORIGINS plus the site's own address, each
 * `https://host` or `https://host:port` and nothing else: an http:// entry or
 * a wildcard (Better Auth would honour `*`) is dropped.
 * Outside production a listed entry may also be http://, never a wildcard. A
 * copy on this machine also trusts its own localhost origin, whatever the
 * port, because testers run on other ports and would be refused otherwise. A preview trusts its own branch address. Pure, so it is tested
 * as a table (control C20).
 */
import { isProduction, type AuthEnv } from "./env";

/** One DNS label: letters, digits, inner hyphens. No `*`, no `_`, no path. */
const LABEL = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?";
const HOST_PORT = `${LABEL}(?:\\.${LABEL})*(?::\\d{1,5})?`;
const HTTPS_ORIGIN = new RegExp(`^https:\\/\\/${HOST_PORT}$`, "i");
const ANY_ORIGIN = new RegExp(`^https?:\\/\\/${HOST_PORT}$`, "i");
const LOCAL = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?$/;

export function trustedOriginsFor(env: AuthEnv, requestOrigin: string | null | undefined, baseUrl: string, builtForProduction?: boolean): string[] {
  // A production build never trusts a localhost origin, whatever NODE_ENV it runs with.
  const production = isProduction(env, builtForProduction);
  const shape = production ? HTTPS_ORIGIN : ANY_ORIGIN;
  const listed = (env.AUTH_TRUSTED_ORIGINS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => shape.test(s));
  const own = new URL(baseUrl).origin;
  const out = new Set<string>([own, ...listed]);
  if (production) return [...out];
  if (env.VERCEL_ENV === "preview") {
    if (env.VERCEL_BRANCH_URL) out.add(`https://${env.VERCEL_BRANCH_URL}`);
    if (env.VERCEL_URL) out.add(`https://${env.VERCEL_URL}`);
    return [...out];
  }
  if (requestOrigin && LOCAL.test(requestOrigin)) out.add(requestOrigin);
  return [...out];
}
