/**
 * The Better Auth server instance: Microsoft Entra ID sign-in, pinned to one
 * tenant, behind the site's own people list.
 *
 * Every line that is not Better Auth's default names the control it meets
 * (references/controls.md in the entra-id-auth skill).
 *
 * Three doors, in order:
 *  1. Microsoft: single-tenant app, assignment required, the group assigned,
 *     and Conditional Access MFA only where the site owner said yes (all in
 *     the tenant, set up by the skill's scripts).
 *  2. The session hook below: tenant again, the person by object id, active.
 *  3. Every protected request: current-person.ts reads person and role again.
 */
import { APIError, betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";

import { account, rateLimit, session, user, verification } from "@/db/schema/auth";
import { getDb } from "@/lib/db";

import { refuseUnsafeRedirects } from "./callback-guard";
import { authBaseUrl, authEnv, microsoftConfigured, passwordSignInAllowed } from "./env";
import { logFailedAttempts } from "./failed-attempts";
import { decideSignIn } from "./gate";
import { gateLookups, recordSignInEvent, removeRefusedAuthRows } from "./gate-store";
import { PASSWORD_LANE_MESSAGE, REFUSAL_MESSAGE } from "./messages";
import { ALLOW_GUESTS, JOIN_MODE, ORG_EMAIL_DOMAINS, ROLE_SOURCE, SESSION_IDLE_SECONDS, SESSION_RENEW_AFTER_SECONDS } from "./settings";
import { trustedOriginsFor } from "./trusted-origins";

const env = authEnv();
const baseURL = authBaseUrl(env);

export const auth = betterAuth({
  baseURL,
  secret: env.BETTER_AUTH_SECRET,

  // Control C20: production trusts exactly the listed origins; see trusted-origins.ts.
  trustedOrigins: (request) => trustedOriginsFor(env, request?.headers?.get("origin"), baseURL),

  database: drizzleAdapter(getDb(), {
    provider: "pg",
    schema: { user, session, account, verification, rateLimit },
  }),

  // Control C28: counters in the database, shared by every serverless instance.
  rateLimit: {
    enabled: true,
    storage: "database",
    window: 60,
    max: 100,
    customRules: {
      "/sign-in/email": { window: 60, max: 5 },
      "/sign-in/social": { window: 60, max: 20 },
    },
  },

  // Control C16: SESSION_IDLE_MINUTES idle, renewed by activity; the
  // absolute cap of SESSION_MAX_HOURS is enforced in current-person.ts.
  session: {
    expiresIn: SESSION_IDLE_SECONDS,
    updateAge: SESSION_RENEW_AFTER_SECONDS,
  },

  account: {
    // Control C19: the access token is stored encrypted (Better Auth encrypts
    // access and refresh tokens only). There is no refresh token: the scope
    // has no offline_access (M8). The id token is stored in plain text on
    // purpose: gate.ts reads its tid and aud, it holds nothing the user row
    // does not, and with disableIdTokenSignIn below it cannot be replayed to
    // sign in (better-auth dist/oauth2/link-account.mjs: setTokenUtil wraps
    // the access and refresh tokens, idToken is stored as given; 1.7.5, 1.7.6).
    encryptOAuthTokens: true,
    // A Microsoft identity is never linked onto a user row it did not create.
    accountLinking: { enabled: false },
  },

  advanced: {
    useSecureCookies: baseURL.startsWith("https://"),
  },

  socialProviders: microsoftConfigured(env)
    ? {
        microsoft: {
          clientId: env.MICROSOFT_ENTRA_CLIENT_ID!,
          clientSecret: env.MICROSOFT_ENTRA_CLIENT_SECRET!,
          // Control C1: authorize and token endpoints name our tenant, never "common".
          tenantId: env.MICROSOFT_ENTRA_TENANT_ID!,
          // Control M8: openid, profile, email only. No offline_access (no refresh
          // token), no User.Read (no Graph call for a photo).
          disableDefaultScope: true,
          scope: ["openid", "profile", "email"],
          disableProfilePhoto: true,
          prompt: "select_account",
          // No bare id-token sign-in. Better Auth 1.7.5 otherwise
          // accepts POST /sign-in/social with { idToken }, which skips the code
          // flow, PKCE and state, so an id token read from the database or a log
          // could be replayed. Refused as 404 ID_TOKEN_NOT_SUPPORTED.
          disableIdTokenSignIn: true,
        },
      }
    : {},

  emailAndPassword: {
    // The test lane (control C27): on only where passwordSignInAllowed() says.
    enabled: passwordSignInAllowed(env),
    // Always: nobody signs up through the API; test accounts come from a script.
    disableSignUp: true,
  },

  // Refusals land on /sign-in?error=<code>, which shows fixed words (control C23).
  onAPIError: { errorURL: "/sign-in" },

  // Control C22: every redirect target of a sign-in start is a same-site path,
  // checked on the server, not only by the sign-in page. Control C13: failed
  // callbacks and wrong passwords leave a row.
  hooks: { before: refuseUnsafeRedirects, after: logFailedAttempts },

  databaseHooks: {
    session: {
      create: {
        before: async (newSession, context) => {
          const path = context?.path ?? null;
          const decision = await decideSignIn(
            {
              userId: newSession.userId,
              path,
              expectedTenantId: env.MICROSOFT_ENTRA_TENANT_ID ?? null,
              expectedClientId: env.MICROSOFT_ENTRA_CLIENT_ID ?? null,
              passwordLaneOn: passwordSignInAllowed(env),
              roleSource: ROLE_SOURCE,
              joinMode: JOIN_MODE,
              allowGuests: ALLOW_GUESTS === "yes",
              orgEmailDomains: ORG_EMAIL_DOMAINS,
            },
            gateLookups(),
          );

          await recordSignInEvent({
            outcome: decision.outcome,
            emailAttempted: decision.email,
            tenantIdSeen: decision.tenantIdSeen,
            objectIdSeen: decision.objectIdSeen,
            personId: decision.personId,
            detail: decision.passwordRefusal ?? decision.tokenRefusal ?? decision.joinRefusal ?? decision.grantNote ?? null,
            path,
            ipAddress: newSession.ipAddress,
            userAgent: newSession.userAgent,
          });

          if (decision.outcome === "granted") return;

          // Control C14: a refused Microsoft sign-in keeps no user or account row.
          if (decision.removeAuthRows) await removeRefusedAuthRows(newSession.userId);

          const message =
            decision.passwordRefusal === "test_account_has_microsoft"
              ? PASSWORD_LANE_MESSAGE.testAccountHasMicrosoft
              : decision.passwordRefusal === "not_a_test_address"
                ? PASSWORD_LANE_MESSAGE.notATestAddress
                : decision.outcome === "refused_other"
                  ? "Sign-in refused."
                  : REFUSAL_MESSAGE[decision.outcome];
          throw new APIError("FORBIDDEN", { code: decision.outcome, message });
        },
      },
    },
  },

  telemetry: { enabled: false },
});

export type Session = Awaited<ReturnType<typeof auth.api.getSession>>;
