/**
 * The site's sign-in settings, in one place. Each one is a Setting: the site
 * owner may change it; the default and its reason are written beside it.
 *
 * The entra-id-auth skill fills the placeholder values from the setup
 * answers. Each sits inside a string literal, so the unfilled file still parses; the
 * numbers and choices are checked here and a bad value throws at import, so a
 * site with a wrong setting never starts. No secret lives here.
 */

/** A whole number from a filled setting, or a thrown error naming the setting and its range. */
export function parseWholeNumber(name: string, raw: string, min: number, max: number): number {
  const text = raw.trim();
  const value = /^\d+$/.test(text) ? Number(text) : Number.NaN;
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`Sign-in setting ${name} must be a whole number from ${min} to ${max}; it is "${raw}".`);
  }
  return value;
}

/** One of a fixed list of choices, or a thrown error naming the setting and the choices. */
export function parseChoice<T extends string>(name: string, raw: string, choices: readonly T[]): T {
  const text = raw.trim();
  if (!(choices as readonly string[]).includes(text)) {
    throw new Error(`Sign-in setting ${name} must be one of ${choices.join(", ")}; it is "${raw}".`);
  }
  return text as T;
}

const DOMAIN = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;

/** A comma-separated list of email domains, lower-cased, each checked, at least one. */
export function parseEmailDomains(raw: string): readonly string[] {
  const domains = raw
    .split(",")
    .map((d) => d.trim().toLowerCase())
    .filter(Boolean);
  if (domains.length === 0) throw new Error("Sign-in setting EMAIL_DOMAINS must name at least one domain.");
  for (const d of domains) {
    if (!DOMAIN.test(d)) throw new Error(`Sign-in setting EMAIL_DOMAINS holds "${d}", which is not a domain.`);
  }
  return Object.freeze([...new Set(domains)]);
}

/** True when the address ends in @ one of the domains (compared ignoring case). */
export function emailOnDomains(email: string, domains: readonly string[]): boolean {
  const at = email.trim().toLowerCase().lastIndexOf("@");
  if (at < 1) return false;
  const domain = email.trim().toLowerCase().slice(at + 1);
  return domains.some((d) => d.toLowerCase() === domain);
}

/** Shown on the sign-in page and in refusals. */
export const SITE_NAME = "__SITE_NAME__";

/**
 * The organisation's own email domains. The first administrator, and anyone
 * seeded from the setup, must use one of them. Default: every verified domain
 * of the tenant except *.onmicrosoft.com.
 */
export const ORG_EMAIL_DOMAINS: readonly string[] = parseEmailDomains("__EMAIL_DOMAINS__");

/**
 * Setting: idle limit, in minutes, 15 to 480. A session with no activity for
 * this long ends. Default 60 minutes: long enough for a meeting away from the
 * desk, short enough that an unattended screen does not stay signed in for a
 * day (control C16). Better Auth's `expiresIn`; activity renews it (see
 * SESSION_RENEW_AFTER_SECONDS).
 */
export const SESSION_IDLE_MINUTES = parseWholeNumber("SESSION_IDLE_MINUTES", "__SESSION_IDLE_MINUTES__", 15, 480);
export const SESSION_IDLE_SECONDS = SESSION_IDLE_MINUTES * 60;

/** How stale a session must be before a request renews it. 5 minutes. */
export const SESSION_RENEW_AFTER_SECONDS = 5 * 60;

/**
 * Setting: absolute limit, in hours, 1 to 24. However active, a session ends
 * this long after sign-in and the person goes back through Microsoft, which
 * re-checks the group and the account at that sign-in (and MFA, where the
 * site owner chose it). Default 12 hours: one working day, so a person signs
 * in about once a day. The same answer sets the sign-in frequency of the
 * optional Conditional Access policy, so the two never disagree. With the
 * site's own switch-off, it is how removal from the group in Microsoft
 * reaches a live session (control C17).
 */
export const SESSION_MAX_HOURS = parseWholeNumber("SESSION_MAX_HOURS", "__SESSION_MAX_HOURS__", 1, 24);
export const SESSION_MAX_AGE_SECONDS = SESSION_MAX_HOURS * 60 * 60;

if (SESSION_IDLE_SECONDS >= SESSION_MAX_AGE_SECONDS) {
  throw new Error(
    `Sign-in setting SESSION_IDLE_MINUTES (${SESSION_IDLE_MINUTES}) must be shorter than SESSION_MAX_HOURS (${SESSION_MAX_HOURS} hours).`,
  );
}

/**
 * Setting: where a person's role inside the site comes from.
 *  - "site" (default): the site's own append-only list (person_assignments).
 *    An administrator changes a role there and it applies on the next click.
 *  - "entra": the Entra app role `administrator` in the id token's `roles`
 *    claim, read at each sign-in, so IT manages administrators in Entra. A
 *    change reaches a live session at its next sign-in, at most
 *    SESSION_MAX_HOURS later.
 */
export const ROLE_SOURCE = parseChoice("ROLE_SOURCE", "__ROLE_SOURCE__", ["site", "entra"] as const);
export type RoleSource = typeof ROLE_SOURCE;

/**
 * Setting: what happens when a member of the site's Microsoft group signs in
 * but is not on the site's own list.
 *  - "listed" (default): refused. Someone adds them to the list first, so a
 *    change of group in Microsoft alone never opens the site.
 *  - "group": added to the list as a member at that first sign-in, and
 *    recorded as such. Whoever manages the group in Microsoft then grants
 *    access alone.
 */
export const JOIN_MODE = parseChoice("JOIN_MODE", "__JOIN_MODE__", ["listed", "group"] as const);
export type JoinMode = typeof JOIN_MODE;

/**
 * Setting: may someone outside the organisation (a B2B guest) sign in? The
 * setup's "May guests sign in?" answer. Default "no".
 *  - "no": with JOIN_MODE "group", a group member whose address is not on
 *    one of ORG_EMAIL_DOMAINS is refused at the first sign-in and nobody is
 *    added (a guest's address is on their own organisation's domain), even
 *    when someone later puts a guest into the site's group in Microsoft. A
 *    person an administrator adds to the list by hand is that administrator's
 *    own decision and is not checked here.
 *  - "yes": group members join whatever their address.
 */
export const ALLOW_GUESTS = parseChoice("ALLOW_GUESTS", "__ALLOW_GUESTS__", ["yes", "no"] as const);

/**
 * Routes that answer without a session. Everything else is gated the day it
 * exists. Each entry is a whole path segment: "/sign-in" does not open
 * "/sign-in-help" (control C25).
 *
 * Files in public/ are gated too, except favicon.ico, robots.txt, icon.svg
 * and apple-icon.png. An image or font the sign-in page loads from public/
 * goes here by its exact path (for example "/logo.svg"), never a folder; or
 * import it (a static import), which serves it from /_next/static.
 */
export const PUBLIC_PATHS = ["/sign-in", "/api/auth"] as const;

/**
 * Server-to-server routes. No cookie can reach them, so the gate lets them
 * through and each checks the CRON_SECRET bearer itself (server-caller.ts).
 * Name each one; never open "/api" as a block, or every API route a site adds
 * later would answer strangers.
 */
export const SERVER_TO_SERVER_PATHS = ["/api/cron", "/api/health"] as const;

/** Days before a credential's end date that administrators are warned. */
export const CREDENTIAL_WARNING_DAYS = 30;
