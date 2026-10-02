/**
 * Who is signed in, checked on every protected request (the third door).
 *
 * A session is not enough. Each call reads the person by Entra object id and
 * their newest assignment again, so switching someone off works on their next
 * click without waiting for the session to end (control C7). It also ends any
 * session older than the absolute limit (control C16, C17).
 *
 * Where each one goes (control C26):
 *  - proxy.ts: personFromHeaders(request.headers) on every gated path, before
 *    anything renders.
 *  - Every page, layout, template and default file on a gated path:
 *    requirePagePerson() (or requireAdministratorPage()) as the first line. A layout's check does not
 *    cover the pages under it: Next renders them in parallel.
 *  - Every route handler and server action: requireCurrentPerson() or
 *    requireAdministrator().
 */
import { and, desc, eq, sql } from "drizzle-orm";
import { headers } from "next/headers";
import { notFound, redirect } from "next/navigation";
import { cache } from "react";

import { account, session as sessionTable } from "@/db/schema/auth";
import { people, personAssignments, personIdentities } from "@/db/schema/access";
import { getDb } from "@/lib/db";

import { authEnv, passwordSignInAllowed } from "./env";
import { recordSignInEvent } from "./gate-store";
import { auth } from "./server";
import { SESSION_MAX_AGE_SECONDS } from "./settings";

export type Role = (typeof personAssignments.$inferSelect)["role"];

export interface SignedInPerson {
  personId: string;
  displayName: string;
  email: string;
  role: Role;
  authUserId: string;
  sessionId: string;
}

export class AccessError extends Error {
  constructor(
    readonly code: "not_signed_in" | "not_permitted",
    message: string,
  ) {
    super(message);
  }
}

async function findPerson(userId: string, email: string): Promise<{ id: string; displayName: string; email: string } | null> {
  const db = getDb();
  const [microsoft] = await db
    .select({ objectId: account.accountId })
    .from(account)
    .where(and(eq(account.userId, userId), eq(account.providerId, "microsoft")))
    .orderBy(desc(account.updatedAt))
    .limit(1);
  const tenantId = authEnv().MICROSOFT_ENTRA_TENANT_ID;

  if (microsoft && tenantId) {
    const [row] = await db
      .select({ id: people.id, displayName: people.displayName, email: people.email })
      .from(personIdentities)
      .innerJoin(people, eq(people.id, personIdentities.personId))
      .where(and(eq(personIdentities.tenantId, tenantId), eq(personIdentities.objectId, microsoft.objectId)))
      .limit(1);
    return row ?? null;
  }

  // The test lane only: a .invalid address with no Microsoft account.
  if (!microsoft && passwordSignInAllowed() && email.endsWith(".invalid")) {
    const [row] = await db
      .select({ id: people.id, displayName: people.displayName, email: people.email })
      .from(people)
      .where(sql`lower(${people.email}) = ${email}`)
      .limit(1);
    return row ?? null;
  }
  return null;
}

/**
 * The person behind a request's session cookie, or null. Takes the headers
 * itself, so the proxy can call it before any page renders.
 */
export async function personFromHeaders(requestHeaders: Headers): Promise<SignedInPerson | null> {
  const current = await auth.api.getSession({ headers: requestHeaders });
  if (!current?.user) return null;

  const started = new Date(current.session.createdAt).getTime();
  if (Date.now() - started > SESSION_MAX_AGE_SECONDS * 1000) {
    // Past the absolute limit: end it here, so the next sign-in goes back
    // through Microsoft (group and account checked again; MFA only where the
    // site owner chose it).
    await getDb().delete(sessionTable).where(eq(sessionTable.id, current.session.id));
    await recordSignInEvent({ outcome: "refused_session_expired", emailAttempted: current.user.email, path: "session" });
    return null;
  }

  const person = await findPerson(current.user.id, current.user.email.toLowerCase());
  if (!person) return null;

  const [assignment] = await getDb()
    .select({ role: personAssignments.role, active: personAssignments.active })
    .from(personAssignments)
    .where(eq(personAssignments.personId, person.id))
    .orderBy(desc(personAssignments.setAt))
    .limit(1);
  if (!assignment?.active) return null;

  return {
    personId: person.id,
    displayName: person.displayName,
    email: person.email,
    role: assignment.role,
    authUserId: current.user.id,
    sessionId: current.session.id,
  };
}

/** The signed-in person, or null. Cached for one request. */
export const getCurrentPerson = cache(async (): Promise<SignedInPerson | null> => personFromHeaders(await headers()));

/**
 * The first line of every page, layout, template and default file on a gated
 * path (control C26): sends anyone without a usable session to /sign-in before the file
 * reads data or returns markup. A layout above a page does not protect it:
 * Next renders the two in parallel, and a page with no check of its own is
 * sent in the body of the layout's redirect. page-checks.test.ts fails on a
 * file whose default export (or generateMetadata) does not start with it.
 */
export async function requirePagePerson(): Promise<SignedInPerson> {
  const person = await getCurrentPerson();
  if (!person) redirect("/sign-in");
  return person;
}

/** requirePagePerson() for a page only administrators may see: anyone else gets the site's 404. */
export async function requireAdministratorPage(): Promise<SignedInPerson> {
  const person = await requirePagePerson();
  if (!isAdministrator(person)) notFound();
  return person;
}

/** For route handlers and server actions. */
export async function requireCurrentPerson(): Promise<SignedInPerson> {
  const person = await getCurrentPerson();
  if (!person) throw new AccessError("not_signed_in", "Sign in with your work Microsoft account to use this.");
  return person;
}

export function isAdministrator(person: SignedInPerson): boolean {
  return person.role === "administrator";
}

export async function requireAdministrator(): Promise<SignedInPerson> {
  const person = await requireCurrentPerson();
  if (!isAdministrator(person)) throw new AccessError("not_permitted", "Only an administrator can do this.");
  return person;
}
