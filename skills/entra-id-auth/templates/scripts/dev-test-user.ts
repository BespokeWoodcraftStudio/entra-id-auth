/**
 * Gives a test identity a password, for the test lane only (control C27).
 * Sign-up through the API is always refused, so this script is the only way a
 * password account exists.
 *
 * On this machine:
 *   DEV_TEST_PASSWORD='<password>' npx tsx scripts/dev-test-user.ts tester@site.invalid - "Test Person"
 * Refuses unless the address ends in .invalid (RFC 2606, never delivered), the
 * database is on this machine, this is not a Vercel run, and the test lane is
 * on here.
 *
 * On a preview database (PREVIEW_MODE=test-lane with PASSWORD_LANE=local+preview):
 *   DATABASE_URL="$(cat ~/.config/<slug>/database-url-preview)" DEV_TEST_PASSWORD='<password>' \
 *     npx tsx scripts/dev-test-user.ts --preview tester@site.invalid - "Test Person"
 * The URL is read from its owner-only file, never typed on the line, so it stays
 * out of shell history. It is Preview's own database, made empty, never a branch
 * or copy of production's. It is
 * refused unless that database holds test identities only: no address outside
 * .invalid, no Microsoft account, no bound Entra identity. Production's
 * database, and any copy of it, holds real people, so it is always refused;
 * a URL that reaches the database in any ~/.config/<slug>/database-url-prod
 * is refused before anything is read, even while production is still empty.
 * The preview database must be migrated first:
 *   DATABASE_URL="$(cat ~/.config/<slug>/database-url-preview)" npx drizzle-kit migrate
 * The account signs in only on a preview whose ALLOW_PASSWORD_SIGNIN is true.
 *
 * The password is typed by the person running it and never written to a file.
 * "-" reads it from DEV_TEST_PASSWORD, so it stays out of the process list;
 * when Claude runs this, the person sets that variable (and, for --preview,
 * DATABASE_URL), never Claude.
 */
import { config } from "dotenv";

// The environment wins over .env.local, so --preview uses the DATABASE_URL set for this run.
config({ path: ".env.local", quiet: true });

import { readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import { sql } from "drizzle-orm";

import {
  PREVIEW_REQUIRED_TABLES,
  previewDatabaseRefusal,
  previewSchemaRefusal,
  testIdentityTargetRefusal,
} from "../__SRC_ROOT__/lib/auth/test-identity";

/** Every ~/.config/<slug>/database-url-prod on this machine. Read only to compare, never printed. */
function productionDatabaseUrls(): string[] {
  const root = join(homedir(), ".config");
  let dirs: string[];
  try {
    dirs = readdirSync(root);
  } catch {
    return [];
  }
  const urls: string[] = [];
  for (const dir of dirs) {
    try {
      const url = readFileSync(join(root, dir, "database-url-prod"), "utf8").trim();
      if (url) urls.push(url);
    } catch {
      // No production URL for this folder.
    }
  }
  return urls;
}

const USAGE = 'Usage: npx tsx scripts/dev-test-user.ts [--preview] <x@y.invalid> <password or -> ["Name"]';

async function main() {
  const preview = process.argv.includes("--preview");
  const [rawEmail, passwordArg, name] = process.argv.slice(2).filter((a) => a !== "--preview");
  const password = passwordArg === "-" ? process.env.DEV_TEST_PASSWORD : passwordArg;
  if (!rawEmail || !password) throw new Error(USAGE);
  const email = rawEmail.trim().toLowerCase();
  const onVercel = Boolean(process.env.VERCEL || process.env.VERCEL_ENV);
  const databaseUrl = process.env.DATABASE_URL || undefined;
  // The lane flag is read for a local target only; a preview's own ALLOW_PASSWORD_SIGNIN is on Vercel.
  const laneOnHere =
    !preview && !onVercel && Boolean(databaseUrl) ? (await import("../__SRC_ROOT__/lib/auth/env")).passwordSignInAllowed() : false;
  const refusal = testIdentityTargetRefusal({
    email,
    databaseUrl,
    preview,
    onVercel,
    laneOnHere,
    productionDatabaseUrls: preview ? productionDatabaseUrls() : [],
  });
  if (refusal) throw new Error(refusal);

  const { getDb } = await import("../__SRC_ROOT__/lib/db");
  const { people, personAssignments } = await import("../__SRC_ROOT__/db/schema/access");
  const { auth } = await import("../__SRC_ROOT__/lib/auth/server");
  const db = getDb();

  if (preview) {
    const firstRow = <T>(rows: unknown) => (Array.isArray(rows) ? rows[0] : (rows as { rows: T[] }).rows[0]) as T | undefined;
    // An unmigrated preview database: say so, in place of Postgres's raw 'relation does not exist'.
    const missing: string[] = [];
    for (const table of PREVIEW_REQUIRED_TABLES) {
      const row = firstRow<{ found: boolean }>(
        await db.execute(sql`select to_regclass(${`public."${table}"`}) is not null as found`),
      );
      if (!row?.found) missing.push(table);
    }
    const schemaRefusal = previewSchemaRefusal(missing);
    if (schemaRefusal) throw new Error(schemaRefusal);
    const count = async (query: ReturnType<typeof sql>) => Number(firstRow<{ n: number }>(await db.execute(query))?.n ?? 0);
    const contentsRefusal = previewDatabaseRefusal({
      realPeople: await count(sql`select count(*)::int as n from people where lower(email) not like '%.invalid'`),
      microsoftAccounts: await count(sql`select count(*)::int as n from account where provider_id <> 'credential'`),
      boundIdentities: await count(sql`select count(*)::int as n from person_identities`),
    });
    if (contentsRefusal) throw new Error(contentsRefusal);
  }

  const [person] = await db.select({ id: people.id }).from(people).where(sql`lower(${people.email}) = ${email}`).limit(1);
  if (!person) {
    const [created] = await db
      .insert(people)
      .values({ email, displayName: name ?? "Test person", note: "Test identity, dev-test-user script." })
      .returning();
    await db.insert(personAssignments).values({ personId: created.id, role: "member", active: true, note: "Test identity." });
  }

  const ctx = await auth.$context;
  const hash = await ctx.password.hash(password);
  const existing = await ctx.internalAdapter.findUserByEmail(email);
  const user =
    existing?.user ??
    (await ctx.internalAdapter.createUser({ email, name: name ?? "Test person", emailVerified: true }, { method: "email-password" }));
  const accounts = await ctx.internalAdapter.findAccounts(user.id);
  if (accounts.some((a) => a.providerId === "microsoft")) throw new Error("Refusing: this identity has a Microsoft account.");
  const credential = accounts.find((a) => a.providerId === "credential");
  if (credential) await ctx.internalAdapter.updateAccount(credential.id, { password: hash });
  else await ctx.internalAdapter.createAccount({ userId: user.id, providerId: "credential", accountId: user.id, password: hash });
  console.log(
    preview
      ? `${email} can sign in with a password on a preview that uses this database, once that preview's ALLOW_PASSWORD_SIGNIN is true.`
      : `${email} can sign in with a password on this machine.`,
  );
}

if (process.argv[1]?.endsWith("dev-test-user.ts")) {
  main()
    .catch((error) => {
      console.error(error instanceof Error ? error.message : error);
      process.exitCode = 1;
    })
    .finally(async () => {
      const { closeDb } = await import("../__SRC_ROOT__/lib/db");
      await closeDb();
    });
}
