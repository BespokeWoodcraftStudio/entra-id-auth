/**
 * Where scripts/dev-test-user.ts may give a test identity a password (control
 * C27). Pure checks, so each refusal is unit tested without a database; the
 * script runs them before it writes anything.
 *
 * Two targets, and only two:
 *  - this machine: a Postgres on localhost, with the test lane on here;
 *  - a preview database, only with --preview: the database must hold test
 *    identities only (no address outside .invalid, no Microsoft account, no
 *    bound Entra identity). Production's database always holds its first
 *    administrator, and a preview copied from production holds everyone, so
 *    both are refused. Production never lets a password sign in anyway
 *    (env.ts passwordSignInAllowed).
 * A preview database must also be migrated first, and must not be the one in
 * ~/.config/<slug>/database-url-prod (compared by host and database name, so
 * a production database with no administrator yet is still refused).
 * Never from a Vercel run.
 */

export const TEST_IDENTITY_SUFFIX = ".invalid";

/** A test address: ends in .invalid (RFC 2606, never delivered). */
export function isTestAddress(email: string): boolean {
  const e = email.trim().toLowerCase();
  return e.includes("@") && e.endsWith(TEST_IDENTITY_SUFFIX);
}

// WHATWG URL keeps the brackets on an IPv6 host: new URL("postgres://[::1]/x").hostname is "[::1]".
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

/** A Postgres on this machine, with no host= or hostaddr= query key that a driver could read over the URL's host. */
export function isLocalDatabaseUrl(url: string): boolean {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return false;
  }
  return LOCAL_HOSTS.has(u.hostname) && !u.searchParams.has("host") && !u.searchParams.has("hostaddr");
}

export interface TestIdentityTarget {
  email: string;
  databaseUrl: string | undefined;
  /** The --preview flag. */
  preview: boolean;
  /** VERCEL or VERCEL_ENV is set: this is a Vercel build or function. */
  onVercel: boolean;
  /** passwordSignInAllowed() on this machine. Checked for a local target only. */
  laneOnHere: boolean;
  /**
   * --preview only: production's database URLs known on this machine (the
   * contents of each ~/.config/<slug>/database-url-prod). Compared here, never printed.
   */
  productionDatabaseUrls?: string[];
}

/** Neon's pooled host is "<endpoint>-pooler.<region>..."; the same database answers on both. */
function databaseKey(url: string): string | null {
  let u: URL;
  try {
    u = new URL(url.trim());
  } catch {
    return null;
  }
  const host = u.hostname.toLowerCase().replace(/-pooler(?=\.)/, "");
  const port = u.port || "5432";
  const name = decodeURIComponent(u.pathname.replace(/^\/+/, "")) || decodeURIComponent(u.username);
  return `${host}:${port}/${name}`;
}

/** True when both URLs reach the same database: same host (pooled or not), port and database name. */
export function isSameDatabase(a: string, b: string): boolean {
  if (a.trim() === b.trim()) return true;
  const ka = databaseKey(a);
  return ka !== null && ka === databaseKey(b);
}

/** Why the script must not write, or null. Checked before it touches the database. */
export function testIdentityTargetRefusal(t: TestIdentityTarget): string | null {
  if (!isTestAddress(t.email)) return "Refusing: a test identity must end in .invalid.";
  if (t.onVercel) return "Refusing to run on Vercel.";
  if (!t.databaseUrl) return "DATABASE_URL is not set.";
  if (t.preview) {
    if (isLocalDatabaseUrl(t.databaseUrl)) {
      return "Refusing: --preview needs the preview database's URL in DATABASE_URL, and this one is on this machine. Leave out --preview for a local account.";
    }
    const databaseUrl = t.databaseUrl;
    if ((t.productionDatabaseUrls ?? []).some((p) => p.trim() && isSameDatabase(databaseUrl, p))) {
      return "Refusing: DATABASE_URL is production's database (the one in database-url-prod). Use the preview database's URL (database-url-preview).";
    }
    return null;
  }
  if (!isLocalDatabaseUrl(t.databaseUrl)) {
    return "Refusing: only a database on this machine. For a preview database, add --preview (see the script's header).";
  }
  if (!t.laneOnHere) return "ALLOW_PASSWORD_SIGNIN is not true here, so this account could not sign in.";
  return null;
}

export interface DatabaseContents {
  /** People on the list whose address does not end in .invalid. */
  realPeople: number;
  /** Better Auth accounts that are not password accounts (Microsoft sign-ins). */
  microsoftAccounts: number;
  /** Bound Entra identities (person_identities rows). */
  boundIdentities: number;
}

/** The tables --preview reads and writes. A preview database that lacks any of them was never migrated. */
export const PREVIEW_REQUIRED_TABLES = ["people", "person_identities", "person_assignments", "user", "account", "session"] as const;

/** --preview only: why this database has no schema yet, or null. `missing` lists the tables to_regclass did not find. */
export function previewSchemaRefusal(missing: readonly string[]): string | null {
  if (missing.length === 0) return null;
  return (
    `Refusing: the preview database has not been migrated (missing: ${missing.join(", ")}). ` +
    "Migrate it first, from the site's folder: " +
    'DATABASE_URL="$(cat ~/.config/<slug>/database-url-preview)" npx drizzle-kit migrate ' +
    "then run this again."
  );
}

/** --preview only: why this database is not a test-only preview database, or null. */
export function previewDatabaseRefusal(c: DatabaseContents): string | null {
  if (c.realPeople > 0 || c.microsoftAccounts > 0 || c.boundIdentities > 0) {
    return (
      "Refusing: this database holds real people " +
      `(${c.realPeople} on the list outside .invalid, ${c.microsoftAccounts} Microsoft account(s), ${c.boundIdentities} bound identity(ies)). ` +
      "It is production's, or a copy of it. Give previews their own empty database, then run this again."
    );
  }
  return null;
}
