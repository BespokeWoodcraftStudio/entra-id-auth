/**
 * Changes a person's role, or switches them off or on again, from the command
 * line, for a site that has no people screen yet. Recorded against a named
 * administrator already on the list, as a new row (the list is append-only).
 *
 *   npx tsx scripts/set-person.ts <address> --role <administrator|member> --by <administrator's address>
 *   npx tsx scripts/set-person.ts <address> --off --by <administrator's address>
 *   npx tsx scripts/set-person.ts <address> --on --by <administrator's address>
 *
 * Switching off applies on the person's next click (control C7). It refuses to
 * leave the site with no active administrator (control C9): make someone else
 * an administrator first. With ROLE_SOURCE "entra" a role comes from the Entra
 * app role at each sign-in, so --role is refused; change the app role
 * assignment in Entra instead. --off and --on still work there.
 *
 * Reads DATABASE_URL from the environment first, then .env.local.
 */
import { config } from "dotenv";

config({ path: ".env.local", quiet: true });

import { desc, eq, sql } from "drizzle-orm";

import { ROLE_SOURCE } from "../__SRC_ROOT__/lib/auth/settings";

export type PersonRole = "administrator" | "member";

export interface PersonChangeRequest {
  role?: PersonRole;
  active?: boolean;
}

/**
 * The row to write, from the person's newest row and what was asked, or a
 * thrown refusal. Pure, so it is tested without a database.
 */
export function nextAssignment(
  current: { role: PersonRole; active: boolean },
  ask: PersonChangeRequest,
  roleSource: "site" | "entra",
): { role: PersonRole; active: boolean } {
  if (ask.role === undefined && ask.active === undefined) throw new Error("Refusing: say what to change: --role, --off or --on.");
  if (ask.role !== undefined && ask.role !== current.role && roleSource === "entra") {
    throw new Error("Refusing: this site takes roles from the Entra app role at each sign-in. Change the app role assignment in Entra instead.");
  }
  return { role: ask.role ?? current.role, active: ask.active ?? current.active };
}

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i > -1 ? process.argv[i + 1] : undefined;
}

async function main() {
  const address = process.argv[2]?.trim().toLowerCase();
  const role = arg("--role");
  const off = process.argv.includes("--off");
  const on = process.argv.includes("--on");
  if (!address || address.startsWith("--") || (role !== undefined && role !== "administrator" && role !== "member") || (off && on)) {
    throw new Error("Usage: npx tsx scripts/set-person.ts <address> [--role administrator|member] [--off | --on] --by <admin address>");
  }
  const by = arg("--by")?.trim().toLowerCase();
  if (!by) throw new Error("Say which administrator this is recorded against, with --by <their address>.");
  if (!by.includes("@")) throw new Error("--by takes an administrator's email address here, not a name.");

  const { getDb } = await import("../__SRC_ROOT__/lib/db");
  const { people, personAssignments } = await import("../__SRC_ROOT__/db/schema/access");
  const { setAssignment } = await import("../__SRC_ROOT__/lib/auth/directory");
  const db = getDb();

  const latestFor = async (personId: string) =>
    (
      await db
        .select({ role: personAssignments.role, active: personAssignments.active })
        .from(personAssignments)
        .where(eq(personAssignments.personId, personId))
        .orderBy(desc(personAssignments.setAt), desc(personAssignments.id))
        .limit(1)
    )[0];

  const [actor] = await db.select({ id: people.id }).from(people).where(sql`lower(${people.email}) = ${by}`).limit(1);
  if (!actor) throw new Error("The --by address is not on the people list. --by takes an administrator's address, as it is on the list.");
  const actorRow = await latestFor(actor.id);
  if (actorRow?.role !== "administrator" || !actorRow.active) throw new Error("The --by address is not an active administrator.");

  const [person] = await db.select({ id: people.id }).from(people).where(sql`lower(${people.email}) = ${address}`).limit(1);
  if (!person) throw new Error("That address is not on the people list. Add it with scripts/add-person.ts.");
  const current = (await latestFor(person.id)) ?? { role: "member" as const, active: false };

  const next = nextAssignment(current, { role: role as PersonRole | undefined, active: off ? false : on ? true : undefined }, ROLE_SOURCE);
  const row = await setAssignment(
    { personId: person.id, role: next.role, active: next.active, note: "Changed with the set-person script." },
    actor.id,
  );
  console.log(row ? `Now ${next.role}, ${next.active ? "on" : "off"}.` : "No change: that is already their role and state.");
}

if (process.argv[1]?.endsWith("set-person.ts")) {
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
