/**
 * The open-redirect guard, on the server (control C22).
 *
 * The sign-in page runs `?next=` through safeNextPath before it hands it to
 * the Microsoft button, but that is the browser. Anyone can POST to
 * /api/auth/sign-in/social with their own callbackURL, and Better Auth 1.7.5's
 * own check lets `/\evil.com` through (it resolves off-site in every browser),
 * so every sign-in start is checked here too,
 * before Better Auth sees it: each redirect target must be a same-site path
 * that safeNextPath accepts. Absolute URLs are refused, even to this site; the
 * site's own buttons only ever send paths.
 */
import { APIError, createAuthMiddleware } from "better-auth/api";

import { safeNextPath } from "@/app/sign-in/safe-next-path";

const GUARDED_PATHS = new Set(["/sign-in/social", "/sign-in/email", "/sign-in/oauth2", "/link-social"]);
const TARGET_FIELDS = ["callbackURL", "errorCallbackURL", "newUserCallbackURL"] as const;

/** The first unsafe redirect target in a sign-in body, or null when all are safe. */
export function unsafeRedirectTarget(body: unknown): string | null {
  if (!body || typeof body !== "object") return null;
  for (const field of TARGET_FIELDS) {
    const value = (body as Record<string, unknown>)[field];
    if (value === undefined || value === null) continue;
    if (typeof value !== "string" || safeNextPath(value) === undefined) return field;
  }
  return null;
}

export const refuseUnsafeRedirects = createAuthMiddleware(async (ctx) => {
  if (!GUARDED_PATHS.has(ctx.path ?? "")) return;
  const field = unsafeRedirectTarget(ctx.body) ?? unsafeRedirectTarget(ctx.query);
  if (field) {
    throw new APIError("FORBIDDEN", { code: "INVALID_CALLBACK_URL", message: `Refused: ${field} must be a path on this site.` });
  }
});
