/**
 * The database side of gate.ts, and the two writes a sign-in makes: the log
 * row and, on a refusal, removal of the refused user's Better Auth rows.
 *
 * No import here may reach back to server.ts.
 */
import { and, desc, eq, sql } from "drizzle-orm";

import { account, user } from "@/db/schema/auth";
import { people, personAssignments, personIdentities, signInEvents } from "@/db/schema/access";
import { getDb, type Database } from "@/lib/db";

import type { GateLookups } from "./gate";

/** The note on a row the JOIN_MODE "group" path writes. */
export const JOINED_NOTE = "Joined at first sign-in: a member of the site's group in Microsoft.";
/** The note on a row the ROLE_SOURCE "entra" path writes; it names the actor. */
export const ENTRA_ROLE_NOTE = "Set by the Entra app role at sign-in.";

export function gateLookups(db: Database = getDb()): GateLookups {
  return {
    async microsoftAccountFor(userId) {
      // Filter by provider, or a password row with no id token would be read
      // as "nothing to check" and skip the tenant check.
      const [row] = await db
        .select({ objectId: account.accountId, idToken: account.idToken })
        .from(account)
        .where(and(eq(account.userId, userId), eq(account.providerId, "microsoft")))
        .orderBy(desc(account.updatedAt))
        .limit(1);
      return row ?? null;
    },
    async emailFor(userId) {
      const [row] = await db.select({ email: user.email }).from(user).where(eq(user.id, userId)).limit(1);
      return row?.email?.toLowerCase() ?? null;
    },
    async nameFor(userId) {
      const [row] = await db.select({ name: user.name }).from(user).where(eq(user.id, userId)).limit(1);
      return row?.name ?? null;
    },
    async personByIdentity(tenantId, objectId) {
      const [row] = await db
        .select({ personId: personIdentities.personId })
        .from(personIdentities)
        .where(and(eq(personIdentities.tenantId, tenantId), eq(personIdentities.objectId, objectId)))
        .limit(1);
      return row ?? null;
    },
    async personByEmail(email) {
      const [row] = await db
        .select({ personId: people.id, boundObjectId: personIdentities.objectId })
        .from(people)
        .leftJoin(personIdentities, eq(personIdentities.personId, people.id))
        .where(sql`lower(${people.email}) = ${email.toLowerCase()}`)
        .limit(1);
      return row ? { personId: row.personId, boundObjectId: row.boundObjectId ?? null } : null;
    },
    async bindIdentity(personId, tenantId, objectId) {
      const rows = await db
        .insert(personIdentities)
        .values({ personId, tenantId, objectId, boundBy: "first sign-in" })
        .onConflictDoNothing()
        .returning({ id: personIdentities.id });
      return rows.length === 1;
    },
    async latestAssignment(personId) {
      const [row] = await db
        .select({ active: personAssignments.active, role: personAssignments.role })
        .from(personAssignments)
        .where(eq(personAssignments.personId, personId))
        .orderBy(desc(personAssignments.setAt), desc(personAssignments.id))
        .limit(1);
      return row ?? null;
    },
    async joinPerson({ email, displayName, tenantId, objectId }) {
      // One transaction: a lost race on the email or the identity leaves nothing behind.
      const lost = new Error("lost the race");
      try {
        return await db.transaction(async (tx) => {
          const [person] = await tx
            .insert(people)
            .values({ email: email.toLowerCase(), displayName, addedByPersonId: null, note: JOINED_NOTE })
            .onConflictDoNothing()
            .returning({ id: people.id });
          if (!person) throw lost;
          const bound = await tx
            .insert(personIdentities)
            .values({ personId: person.id, tenantId, objectId, boundBy: "first sign-in" })
            .onConflictDoNothing()
            .returning({ id: personIdentities.id });
          if (bound.length !== 1) throw lost;
          await tx.insert(personAssignments).values({ personId: person.id, role: "member", active: true, setByPersonId: null, note: JOINED_NOTE });
          return { personId: person.id };
        });
      } catch (error) {
        if (error === lost) return null;
        throw error;
      }
    },
    async setRoleFromEntra(personId, role) {
      await db.insert(personAssignments).values({ personId, role, active: true, setByPersonId: null, note: ENTRA_ROLE_NOTE });
    },
  };
}

export interface SignInEventInput {
  outcome: (typeof signInEvents.$inferInsert)["outcome"];
  emailAttempted?: string | null;
  tenantIdSeen?: string | null;
  objectIdSeen?: string | null;
  detail?: string | null;
  path?: string | null;
  personId?: string | null;
  ipAddress?: string | null;
  userAgent?: string | null;
}

/**
 * One log row. A logging failure never turns into a throw ahead of the
 * refusal it explains. `ipAddress` arrives as "" when
 * no header carried one; `|| null` stores that as nothing.
 */
export async function recordSignInEvent(event: SignInEventInput, db: Database = getDb()): Promise<void> {
  try {
    await db.insert(signInEvents).values({
      outcome: event.outcome,
      emailAttempted: event.emailAttempted ?? null,
      tenantIdSeen: event.tenantIdSeen ?? null,
      objectIdSeen: event.objectIdSeen ?? null,
      detail: event.detail ?? null,
      path: event.path ?? null,
      personId: event.personId ?? null,
      ipAddress: event.ipAddress || null,
      userAgent: event.userAgent || null,
    });
  } catch (error) {
    console.error("Could not record a sign-in event", error instanceof Error ? error.message : "unknown error");
  }
}

/**
 * A refused Microsoft sign-in leaves no Better Auth user or account row
 * behind (control C14). Sessions go with the user (on delete cascade). The
 * sign_in_events row is kept; it is append-only and says what happened.
 */
export async function removeRefusedAuthRows(userId: string, db: Database = getDb()): Promise<void> {
  try {
    await db.transaction(async (tx) => {
      await tx.delete(account).where(eq(account.userId, userId));
      await tx.delete(user).where(eq(user.id, userId));
    });
  } catch (error) {
    console.error("Could not remove a refused sign-in's rows", error instanceof Error ? error.message : "unknown error");
  }
}
