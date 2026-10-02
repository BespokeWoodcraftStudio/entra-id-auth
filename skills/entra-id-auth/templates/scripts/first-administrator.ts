/**
 * Creates the first administrator, so somebody can sign in at all.
 *
 * A new database has nobody on its people list, and every later person is
 * added by an administrator, so this is the one way in (control C11). It
 * refuses, with a plain reason and a non-zero exit, when:
 *  - an active administrator already exists (it is for the first one only)
 *  - the address is not on one of the organisation's own email domains
 *  - the name is empty, or the address is already on the list
 *
 * It binds the person's Entra identity now (tenant id + object id), so the
 * first sign-in matches on object id, never on email (control C5). The skill
 * looks the object id up read-only: az ad user show --id <address> --query id
 *
 *   npx tsx scripts/first-administrator.ts <address> "<full name>" --oid <object id> --tenant <tenant id> --by "<who ran it>"
 *
 * Reads DATABASE_URL from the environment first, then .env.local (which
 * points at the local database). For production, migrate first and pass the
 * production URL from its owner-only file, never typed on the line:
 *   DATABASE_URL="$(cat ~/.config/<slug>/database-url-prod)" npx tsx scripts/first-administrator.ts ...
 * One transaction, under the same lock as every administrator change.
 */
import { config } from "dotenv";

config({ path: ".env.local", quiet: true });

import { sql } from "drizzle-orm";

import { emailOnDomains, ORG_EMAIL_DOMAINS } from "../__SRC_ROOT__/lib/auth/settings";

export interface FirstAdministratorInput {
  email: string;
  displayName: string;
  objectId: string;
  tenantId: string;
  ranBy: string;
}

const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function createFirstAdministrator(input: FirstAdministratorInput) {
  const email = input.email.trim().toLowerCase();
  const displayName = input.displayName.trim();
  if (!emailOnDomains(email, ORG_EMAIL_DOMAINS)) {
    const allowed = ORG_EMAIL_DOMAINS.map((d) => `@${d}`).join(" or ");
    throw new Error(`Refusing: the first administrator must be an ${allowed} address.`);
  }
  if (!displayName) throw new Error("Refusing: a name is required.");
  if (!GUID.test(input.objectId) || !GUID.test(input.tenantId)) {
    throw new Error("Refusing: --oid and --tenant must be the Entra object id and tenant id (GUIDs).");
  }
  if (!input.ranBy.trim()) throw new Error("Refusing: say who ran this with --by.");

  const { getDb } = await import("../__SRC_ROOT__/lib/db");
  const { people, personAssignments, personIdentities } = await import("../__SRC_ROOT__/db/schema/access");
  const { ADMIN_LOCK_KEY, otherActiveAdministrators } = await import("../__SRC_ROOT__/lib/auth/directory");
  const db = getDb();

  return db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(${ADMIN_LOCK_KEY})`);
    if ((await otherActiveAdministrators(tx, null)) > 0) {
      throw new Error("Refusing: an active administrator already exists. Add the next person from the site.");
    }
    const [exists] = await tx.select({ id: people.id }).from(people).where(sql`lower(${people.email}) = ${email}`).limit(1);
    if (exists) throw new Error(`Refusing: ${email} is already on the people list.`);

    const note = `First administrator, created by the first-administrator script, run by ${input.ranBy.trim()}, ${new Date().toISOString().slice(0, 10)}.`;
    const [person] = await tx.insert(people).values({ email, displayName, addedByPersonId: null, note }).returning();
    await tx.insert(personIdentities).values({
      personId: person.id,
      tenantId: input.tenantId.toLowerCase(),
      objectId: input.objectId.toLowerCase(),
      boundBy: "added with object id",
    });
    await tx.insert(personAssignments).values({ personId: person.id, role: "administrator", active: true, setByPersonId: null, note });
    return person;
  });
}

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i > -1 ? process.argv[i + 1] : undefined;
}

async function main() {
  const [email, name] = process.argv.slice(2);
  if (!email || !name || email.startsWith("--")) {
    throw new Error('Usage: npx tsx scripts/first-administrator.ts <address> "<full name>" --oid <id> --tenant <id> --by "<who>"');
  }
  const person = await createFirstAdministrator({
    email,
    displayName: name,
    objectId: arg("--oid") ?? "",
    tenantId: arg("--tenant") ?? "",
    ranBy: arg("--by") ?? "",
  });
  console.log(`Created the first administrator (${person.email}).`);
}

if (process.argv[1]?.endsWith("first-administrator.ts")) {
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
