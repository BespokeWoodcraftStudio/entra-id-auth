/**
 * Logs the failures the session hook never sees: a Microsoft callback Better
 * Auth itself refuses (a stale or replayed state, a bad code) and a wrong
 * password on the test lane (control C13, OWASP ASVS 7.1.3).
 *
 * `onAPIError.onError` never runs for these in Better Auth 1.7.5. This runs as `hooks.after`, which the
 * router calls with the endpoint's result, an APIError included, in
 * `ctx.context.returned` (better-auth dist/api/dispatch.mjs, runAfterHooks).
 */
import { createAuthMiddleware, isAPIError } from "better-auth/api";

import { recordSignInEvent } from "./gate-store";

/** Refusals the session hook already logged; never log them twice. */
const LOGGED_BY_THE_GATE = new Set([
  "refused_wrong_tenant",
  "refused_not_on_the_list",
  "refused_switched_off",
  "refused_identity_mismatch",
  "refused_password_not_allowed_here",
]);

function errorCodeFromLocation(location: string | null | undefined): string | null {
  if (!location) return null;
  try {
    return new URL(location, "https://site.invalid").searchParams.get("error");
  } catch {
    return null;
  }
}

export const logFailedAttempts = createAuthMiddleware(async (ctx) => {
  const path = ctx.path ?? "";
  const isCallback = path.startsWith("/callback/");
  const isPassword = path === "/sign-in/email";
  if (!isCallback && !isPassword) return;

  const returned = ctx.context.returned;
  if (!isAPIError(returned)) return;

  const headers = (ctx.context as { responseHeaders?: Headers }).responseHeaders;
  const location = headers?.get("location") ?? (returned.headers as Headers | undefined)?.get?.("location");
  const code =
    errorCodeFromLocation(location) ??
    (typeof returned.body?.code === "string" ? returned.body.code : null) ??
    String(returned.status);

  // A successful callback is also a redirect; only an error redirect counts.
  if (isCallback && !errorCodeFromLocation(location) && returned.status === "FOUND") return;
  if (LOGGED_BY_THE_GATE.has(code)) return;

  const body = (ctx.body ?? {}) as { email?: unknown };
  await recordSignInEvent({
    outcome: "refused_other",
    emailAttempted: isPassword && typeof body.email === "string" ? body.email.toLowerCase().slice(0, 320) : null,
    detail: code.slice(0, 100),
    path,
    ipAddress: ctx.request?.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null,
    userAgent: ctx.request?.headers.get("user-agent")?.slice(0, 500) ?? null,
  });
});
