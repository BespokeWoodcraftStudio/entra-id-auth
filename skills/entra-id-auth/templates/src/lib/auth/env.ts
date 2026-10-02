/**
 * Every setting sign-in reads, validated once, from one place (control C39:
 * one source per setting). Server only; never import this from a client
 * component. Nothing here prints a value: describeAuthEnv() reports presence.
 */
import { z } from "zod";

const optional = z.string().min(1).optional();
/** Any Microsoft GUID. Not z.uuid(), which also checks the RFC variant bits. */
const guid = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, "must be a GUID");

const shape = {
    DATABASE_URL: z.string().min(1, "DATABASE_URL is not set"),

    BETTER_AUTH_SECRET: z.string().min(32, "BETTER_AUTH_SECRET is too short (32 characters at least)"),
    BETTER_AUTH_URL: z.string().url().optional(),
    /** Every origin a browser may sign in from, comma separated, each https://host. */
    AUTH_TRUSTED_ORIGINS: z.string().optional(),

    /** The tenant lock: authorize and token endpoints name this tenant only. */
    MICROSOFT_ENTRA_TENANT_ID: guid.optional(),
    MICROSOFT_ENTRA_CLIENT_ID: guid.optional(),
    MICROSOFT_ENTRA_CLIENT_SECRET: optional,
    /** ISO date the client secret ends. Not a secret; drives the renewal warning. */
    MICROSOFT_ENTRA_CLIENT_SECRET_EXPIRES: optional,

    /** The test password lane. Off unless this says true AND the environment allows it. */
    ALLOW_PASSWORD_SIGNIN: z.enum(["true", "false"]).default("false"),

    /** Bearer for server-to-server routes (Vercel cron sends it). */
    CRON_SECRET: optional,

    /** Only when the site reads Microsoft 365 on the server, with its own app. */
    M365_READER_TENANT_ID: guid.optional(),
    M365_READER_CLIENT_ID: guid.optional(),
    M365_READER_CERTIFICATE_PEM: optional,
    M365_READER_CERTIFICATE_EXPIRES: optional,
    M365_READER_MAILBOXES: optional,

    VERCEL_ENV: z.enum(["production", "preview", "development"]).optional(),
    VERCEL_BRANCH_URL: optional,
    VERCEL_URL: optional,
    NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
};

/**
 * True in any production build. Next.js replaces the literal
 * `process.env.NODE_ENV` at build time (checked on a Next 16 build:
 * `process.env.NODE_ENV === "development"` compiled to `!1`), so a production
 * build stays a production build whatever NODE_ENV the host sets when it runs
 * it. A Vercel preview is also a production build; VERCEL_ENV tells it apart.
 */
export const BUILT_FOR_PRODUCTION = process.env.NODE_ENV === "production";

/**
 * Production, for every security decision: Vercel production, or anywhere off
 * Vercel when the build or the runtime says production.
 */
export function isProduction(env: { VERCEL_ENV?: string; NODE_ENV?: string }, builtForProduction: boolean = BUILT_FOR_PRODUCTION): boolean {
  if (env.VERCEL_ENV === "production") return true;
  if (env.VERCEL_ENV === undefined) return env.NODE_ENV === "production" || builtForProduction;
  return false;
}

const LOCAL_HTTP = /^http:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?$/;

const schema = z.object(shape).superRefine((env, ctx) => {
    const microsoftSet = [env.MICROSOFT_ENTRA_TENANT_ID, env.MICROSOFT_ENTRA_CLIENT_ID, env.MICROSOFT_ENTRA_CLIENT_SECRET];
    const someSet = microsoftSet.some(Boolean);
    const allSet = microsoftSet.every(Boolean);
    if (someSet && !allSet) {
      ctx.addIssue({ code: "custom", message: "Set all three MICROSOFT_ENTRA_* values or none." });
    }
    if (env.VERCEL_ENV === "production") {
      if (!allSet) ctx.addIssue({ code: "custom", message: "Production needs MICROSOFT_ENTRA_TENANT_ID, _CLIENT_ID and _CLIENT_SECRET." });
      if (!env.BETTER_AUTH_URL?.startsWith("https://")) ctx.addIssue({ code: "custom", message: "Production needs BETTER_AUTH_URL as https://<domain>." });
      if (!env.CRON_SECRET) ctx.addIssue({ code: "custom", message: "Production needs CRON_SECRET." });
    } else if (env.VERCEL_ENV === undefined && isProduction(env) && process.env.NEXT_PHASE !== "phase-production-build") {
      // Off Vercel, a production server (next start, or any other host) gets the
      // same checks; plain http is allowed only for a copy on this machine.
      // isProduction() reads the build flag too, so a production build run with
      // NODE_ENV=development is still checked.
      if (!allSet) ctx.addIssue({ code: "custom", message: "A production server needs MICROSOFT_ENTRA_TENANT_ID, _CLIENT_ID and _CLIENT_SECRET." });
      const url = env.BETTER_AUTH_URL ?? "";
      if (!url.startsWith("https://") && !LOCAL_HTTP.test(url)) ctx.addIssue({ code: "custom", message: "A production server needs BETTER_AUTH_URL as https://<domain>." });
      if (!env.CRON_SECRET) ctx.addIssue({ code: "custom", message: "A production server needs CRON_SECRET." });
    }
  });

export type AuthEnv = z.infer<typeof schema>;

let cached: AuthEnv | null = null;

/** Parse and cache. Throws with the names of what is missing, never a value. */
export function authEnv(): AuthEnv {
  if (cached) return cached;
  // An empty value (a blank line copied from .env.example) counts as not set.
  const source = Object.fromEntries(Object.entries(process.env).filter(([, v]) => v !== undefined && v !== ""));
  const parsed = schema.safeParse(source);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `${i.path.join(".") || "env"}: ${i.message}`).join("; ");
    throw new Error(`Sign-in settings are not usable. ${issues}`);
  }
  cached = parsed.data;
  return cached;
}

/** For tests only. */
export function resetAuthEnvCache(): void {
  cached = null;
}

/** True when Microsoft sign-in is configured here. Previews may run without it. */
export function microsoftConfigured(env: AuthEnv = authEnv()): boolean {
  return Boolean(env.MICROSOFT_ENTRA_TENANT_ID && env.MICROSOFT_ENTRA_CLIENT_ID && env.MICROSOFT_ENTRA_CLIENT_SECRET);
}

/**
 * The site's own address. Production: BETTER_AUTH_URL, required. A preview:
 * its branch address, unless BETTER_AUTH_URL names a registered preview host.
 * Local: BETTER_AUTH_URL as `run local` writes it (LOCAL_PORT, 3000 by default);
 * with none set, http://localhost:3000.
 */
export function authBaseUrl(env: AuthEnv = authEnv()): string {
  if (env.BETTER_AUTH_URL) return env.BETTER_AUTH_URL;
  if (env.VERCEL_ENV === "preview" && env.VERCEL_BRANCH_URL) return `https://${env.VERCEL_BRANCH_URL}`;
  return "http://localhost:3000";
}

/**
 * The test password lane (control C27). Allowed only when the flag says so
 * AND either this is a Vercel preview, or it is off Vercel and neither the
 * build nor the runtime is production. A production build keeps it off on any
 * host, even one that runs it with NODE_ENV=development (a check that read only the runtime NODE_ENV
 * would turn it on that way).
 * To test the lane locally, use `next dev`.
 */
export function passwordSignInAllowed(env: AuthEnv = authEnv(), builtForProduction: boolean = BUILT_FOR_PRODUCTION): boolean {
  if (env.ALLOW_PASSWORD_SIGNIN !== "true") return false;
  if (env.VERCEL_ENV === "preview") return true;
  if (env.VERCEL_ENV === undefined && !isProduction(env, builtForProduction)) return true;
  return false;
}

/** Presence only, for the health check. Never a value. */
export function describeAuthEnv(): Record<string, "set" | "not set"> {
  const keys = Object.keys(shape);
  const out: Record<string, "set" | "not set"> = {};
  for (const key of keys) out[key] = process.env[key] ? "set" : "not set";
  return out;
}
