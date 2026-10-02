/**
 * Server-to-server callers (Vercel cron, an uptime check) carry
 * `Authorization: Bearer $CRON_SECRET`. Compared in constant time. With no
 * secret configured it is allowed only on a local copy (VERCEL_ENV unset and
 * not a production build); a preview or production deploy with no secret is a
 * mistake and is refused (control C34).
 *
 * Reads process.env directly so tests can stub it per case.
 */
import { timingSafeEqual } from "node:crypto";

function constantTimeEquals(a: string, b: string): boolean {
  const left = Buffer.from(a, "utf8");
  const right = Buffer.from(b, "utf8");
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

export function isAuthorizedServerCall(authorizationHeader: string | null): boolean {
  const secret = process.env.CRON_SECRET;
  if (!secret) {
    return process.env.VERCEL_ENV === undefined && process.env.NODE_ENV !== "production";
  }
  if (!authorizationHeader) return false;
  return constantTimeEquals(authorizationHeader, `Bearer ${secret}`);
}
