/**
 * Adds a person from the command line, for a site that has no people screen
 * yet. Recorded against a named administrator already on the list.
 *
 *   npx tsx scripts/add-person.ts <address> "<full name>" <administrator|member> --oid <object id> --tenant <tenant id> --by <administrator's address>
 *
 * The object id binds the Entra identity now (control C5). Look it up read-only:
 * az ad user show --id <address> --query id -o tsv
 * The person must also be a member of the site's security group, or
 * Microsoft refuses them before the site hears of them.
 */
import { config } from "dotenv";

config({ path: ".env.local", quiet: true });

import { desc, eq, sql } from "drizzle-orm";

const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface AddPersonArgs {
  email: string;
  name: string;
  role: "administrator" | "member";
  objectId: string;
  tenantId: string;
  /** The administrator this is recorded against: an address on the list. */
  by: string;
}

/** The command line, checked, or a thrown refusal. Pure, so it is tested without a database. */
export function parseAddPersonArgs(argv: readonly string[]): AddPersonArgs {
  const arg = (flag: string): string | undefined => {
    const i = argv.indexOf(flag);
    return i > -1 ? argv[i + 1] : undefined;
  };
  const [email, name, role] = argv;
  if (!email || email.startsWith("--") || !email.includes("@") || !name?.trim() || (role !== "administrator" && role !== "member")) {
    throw new Error('Usage: npx tsx scripts/add-person.ts <address> "<name>" <administrator|member> --oid <id> --tenant <id> --by <admin address>');
  }
  const by = arg("--by")?.trim().toLowerCase();
  if (!by) throw new Error("Say which administrator this is recorded against, with --by <their address>.");
  if (!by.includes("@")) throw new Error("--by takes an administrator's email address here, not a name.");
  // Bind the Entra identity now, never later by email (control C5): an address
  // can be changed by a directory administrator; an object id cannot.
  const objectId = arg("--oid") ?? "";
  const tenantId = arg("--tenant") ?? "";
  if (!GUID.test(objectId) || !GUID.test(tenantId)) {
    throw new Error("Refusing: --oid and --tenant are required GUIDs (az ad user show --id <address> --query id -o tsv; az account show --query tenantId -o tsv).");
  }
  return { email: email.trim().toLowerCase(), name: name.trim(), role, objectId: objectId.toLowerCase(), tenantId: tenantId.toLowerCase(), by };
}

async function main() {
  const { email, name, role, objectId, tenantId, by } = parseAddPersonArgs(process.argv.slice(2));

  const { getDb } = await import("../__SRC_ROOT__/lib/db");
  const { people, personAssignments } = await import("../__SRC_ROOT__/db/schema/access");
  const { addPerson } = await import("../__SRC_ROOT__/lib/auth/directory");
  const db = getDb();

  const [actor] = await db.select({ id: people.id }).from(people).where(sql`lower(${people.email}) = ${by}`).limit(1);
  if (!actor) throw new Error(`${by} is not on the people list. --by takes an administrator's address.`);
  const [latest] = await db
    .select({ role: personAssignments.role, active: personAssignments.active })
    .from(personAssignments)
    .where(eq(personAssignments.personId, actor.id))
    .orderBy(desc(personAssignments.setAt), desc(personAssignments.id))
    .limit(1);
  if (latest?.role !== "administrator" || !latest.active) throw new Error(`${by} is not an active administrator.`);

  const { person } = await addPerson({ email, displayName: name, role, objectId, tenantId }, actor.id);
  console.log(`Added ${person.email} as ${role}.`);
}

if (process.argv[1]?.endsWith("add-person.ts")) {
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
