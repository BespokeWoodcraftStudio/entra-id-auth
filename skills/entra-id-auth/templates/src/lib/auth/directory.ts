/**
 * Adding people and changing who may do what. Every write is a new row
 * (append-only), carries who made it, and the last active administrator can
 * never be switched off or demoted.
 *
 * The last-administrator check and its write run in one transaction under a
 * transaction-scoped advisory lock, so two administrators demoting each other
 * at the same moment cannot both pass (control C9).
 *
 * Call these only after requireAdministrator(); the actor is that person.
 */
import { and, desc, eq, sql } from "drizzle-orm";

import { people, personAssignments, personIdentities } from "@/db/schema/access";
import { getDb, type Database } from "@/lib/db";

import type { Role } from "./current-person";

/** One lock for every change that could leave no administrator. */
const ADMIN_LOCK_KEY = 71_402_311;

export class DirectoryError extends Error {
  constructor(
    readonly code: "last_administrator" | "duplicate_email" | "duplicate_identity" | "invalid",
    message: string,
  ) {
    super(message);
  }
}

type Tx = Parameters<Parameters<Database["transaction"]>[0]>[0];

/** Postgres unique_violation, on the error or on the driver error a query error wraps. */
function isUniqueViolation(error: unknown): boolean {
  const e = error as { code?: unknown; cause?: { code?: unknown } } | null;
  return e?.code === "23505" || e?.cause?.code === "23505";
}

/** Active administrators other than `exceptPersonId`, from each person's newest row. */
async function otherActiveAdministrators(tx: Tx, exceptPersonId: string | null): Promise<number> {
  const rows = await tx.execute<{ n: number }>(sql`
    select count(*)::int as n from (
      select distinct on (person_id) person_id, role, active
      from person_assignments
      order by person_id, set_at desc, id desc
    ) latest
    where latest.role = 'administrator' and latest.active = true
      and (${exceptPersonId}::uuid is null or latest.person_id <> ${exceptPersonId}::uuid)
  `);
  const first = (Array.isArray(rows) ? rows[0] : (rows as { rows: { n: number }[] }).rows[0]) as { n: number } | undefined;
  return Number(first?.n ?? 0);
}

export interface NewPerson {
  email: string;
  displayName: string;
  role: Role;
  /** The Entra object id, looked up by the admin (az ad user show). Binds identity now, not at first sign-in. */
  objectId?: string;
  tenantId?: string;
  note?: string;
}

export async function addPerson(input: NewPerson, actorPersonId: string | null, db: Database = getDb()) {
  const email = input.email.trim().toLowerCase();
  const displayName = input.displayName.trim();
  if (!email.includes("@") || !displayName) throw new DirectoryError("invalid", "A person needs an email and a name.");
  return db.transaction(async (tx) => {
    const [exists] = await tx.select({ id: people.id }).from(people).where(sql`lower(${people.email}) = ${email}`).limit(1);
    if (exists) throw new DirectoryError("duplicate_email", "That email is already on the list.");
    const tenantId = input.tenantId?.trim().toLowerCase();
    const objectId = input.objectId?.trim().toLowerCase();
    const identityTaken = () =>
      new DirectoryError(
        "duplicate_identity",
        "That Microsoft account is already on the list under another address. Change that person instead of adding a new one.",
      );
    if (objectId && tenantId) {
      // One binding per identity: someone whose address changed in Entra keeps the same object id.
      const [bound] = await tx
        .select({ email: people.email })
        .from(personIdentities)
        .innerJoin(people, eq(people.id, personIdentities.personId))
        .where(and(eq(personIdentities.tenantId, tenantId), eq(personIdentities.objectId, objectId)))
        .limit(1);
      if (bound) {
        throw new DirectoryError(
          "duplicate_identity",
          `That Microsoft account is already on the list as ${bound.email}. Change that person instead of adding a new one.`,
        );
      }
    }
    const [person] = await tx
      .insert(people)
      .values({ email, displayName, addedByPersonId: actorPersonId, note: input.note ?? null })
      .returning();
    if (objectId && tenantId) {
      try {
        await tx.insert(personIdentities).values({ personId: person.id, tenantId, objectId, boundBy: "added with object id" });
      } catch (error) {
        // A first sign-in bound the same identity a moment ago.
        if (isUniqueViolation(error)) throw identityTaken();
        throw error;
      }
    }
    const [assignment] = await tx
      .insert(personAssignments)
      .values({ personId: person.id, role: input.role, active: true, setByPersonId: actorPersonId, note: input.note ?? null })
      .returning();
    return { person, assignment };
  });
}

export interface AssignmentChange {
  personId: string;
  role: Role;
  active: boolean;
  note?: string;
}

export async function setAssignment(change: AssignmentChange, actorPersonId: string, db: Database = getDb()) {
  return db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(${ADMIN_LOCK_KEY})`);
    const [before] = await tx
      .select({ role: personAssignments.role, active: personAssignments.active })
      .from(personAssignments)
      .where(eq(personAssignments.personId, change.personId))
      .orderBy(desc(personAssignments.setAt), desc(personAssignments.id))
      .limit(1);
    const wasAdmin = before?.active === true && before.role === "administrator";
    const staysAdmin = change.active && change.role === "administrator";
    if (wasAdmin && !staysAdmin && (await otherActiveAdministrators(tx, change.personId)) === 0) {
      throw new DirectoryError("last_administrator", "There must be at least one administrator. Make someone else an administrator first.");
    }
    if (before && before.role === change.role && before.active === change.active) return null;
    const [row] = await tx
      .insert(personAssignments)
      .values({ personId: change.personId, role: change.role, active: change.active, setByPersonId: actorPersonId, note: change.note ?? null })
      .returning();
    return row;
  });
}

/** Used by the first-administrator script, inside its own transaction. */
export { ADMIN_LOCK_KEY, otherActiveAdministrators };
