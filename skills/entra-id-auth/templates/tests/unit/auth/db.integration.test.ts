/**
 * The controls that need a real Postgres: append-only tables, the
 * last-administrator race, the first-administrator refusal, the log row a
 * forged Microsoft callback leaves (control C9, C10, C11, C13), the refusal
 * of a bare id-token sign-in, the absolute cap of SESSION_MAX_HOURS (C16,
 * C17), the sign-up refusal (C27), seeding people, and the ROLE_SOURCE and
 * JOIN_MODE this copy was filled with.
 *
 * Runs only with TEST_DATABASE_URL pointing at a throwaway local database
 * that has been migrated: SKILL.md step 6.3 creates <name>_test (<name> is the database in
 * .env.local's DATABASE_URL), migrates it, runs this file and drops it.
 * With no TEST_DATABASE_URL these tests are skipped. A TEST_DATABASE_URL that
 * is not on this machine fails the run loudly; it is never skipped.
 */
import { sql } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import type { Database } from "@/lib/db";

// getCurrentPerson reads the request's cookies through next/headers; the
// absolute cap test hands it the cookie a real sign-in set.
const request = vi.hoisted(() => ({ headers: new Headers() }));
vi.mock("next/headers", () => ({ headers: async () => request.headers }));

const url = process.env.TEST_DATABASE_URL;
// WHATWG URL keeps the brackets on an IPv6 host: "[::1]", never "::1".
const LOCAL_HOSTS = ["localhost", "127.0.0.1", "[::1]"];
if (url) {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error("TEST_DATABASE_URL is not a URL. Point it at a throwaway Postgres on this machine, or unset it.");
  }
  if (!LOCAL_HOSTS.includes(parsed.hostname) || parsed.searchParams.has("host") || parsed.searchParams.has("hostaddr")) {
    throw new Error("TEST_DATABASE_URL is not a database on this machine. Refusing to run against it; point it at a throwaway local Postgres.");
  }
}

describe.skipIf(!url)("with a throwaway local database", () => {
  let db: Database;
  let schema: typeof import("@/db/schema/access");
  let directory: typeof import("@/lib/auth/directory");
  const stamp = Date.now().toString(36);

  beforeAll(async () => {
    process.env.DATABASE_URL = url;
    process.env.BETTER_AUTH_SECRET ||= "t".repeat(48);
    process.env.MICROSOFT_ENTRA_TENANT_ID ||= "11111111-1111-1111-1111-111111111111";
    process.env.MICROSOFT_ENTRA_CLIENT_ID ||= "22222222-2222-2222-2222-222222222222";
    process.env.MICROSOFT_ENTRA_CLIENT_SECRET ||= "test-only";
    process.env.ALLOW_PASSWORD_SIGNIN = "true";
    db = (await import("@/lib/db")).getDb();
    schema = await import("@/db/schema/access");
    directory = await import("@/lib/auth/directory");
    // Start from no active administrator: switch off any left by earlier runs (an insert, which is allowed).
    await db.execute(sql`
      insert into person_assignments (person_id, role, active, note)
      select person_id, 'member', false, 'reset by db.integration.test'
      from (select distinct on (person_id) person_id, role, active from person_assignments order by person_id, set_at desc, id desc) l
      where l.role = 'administrator' and l.active`);
  });

  afterAll(async () => {
    await (await import("@/lib/db")).closeDb();
  });

  /** Drizzle wraps the database's own message in a "Failed query" error; read the cause. */
  async function refused(run: Promise<unknown>): Promise<string> {
    try {
      await run;
      return "it ran";
    } catch (error) {
      const e = error as { message?: string; cause?: { message?: string } };
      return e.cause?.message ?? e.message ?? "";
    }
  }

  it("refuses UPDATE, DELETE and TRUNCATE on every one of the four access tables", async () => {
    // A row in each table that belongs to this person, so the row triggers have something to fire on.
    const { person } = await directory.addPerson(
      { email: `ro-${stamp}@org.example`, displayName: "Row", role: "member", objectId: crypto.randomUUID(), tenantId: "11111111-1111-1111-1111-111111111111" },
      null,
    );
    const { recordSignInEvent } = await import("@/lib/auth/gate-store");
    await recordSignInEvent({ outcome: "granted", personId: person.id, path: "db.integration.test" });
    const tables: Array<[string, string]> = [
      ["people", "id"],
      ["person_identities", "person_id"],
      ["person_assignments", "person_id"],
      ["sign_in_events", "person_id"],
    ];
    for (const [table, column] of tables) {
      const count = async () =>
        (await db.execute(sql`select count(*)::int as n from ${sql.identifier(table)} where ${sql.identifier(column)} = ${person.id}`))[0];
      expect(await count(), table).toEqual({ n: 1 });
      expect(await refused(db.execute(sql`update ${sql.identifier(table)} set id = id where ${sql.identifier(column)} = ${person.id}`)), `${table} update`).toMatch(/append-only/);
      expect(await refused(db.execute(sql`delete from ${sql.identifier(table)} where ${sql.identifier(column)} = ${person.id}`)), `${table} delete`).toMatch(/append-only/);
      expect(await refused(db.execute(sql`truncate ${sql.identifier(table)} cascade`)), `${table} truncate`).toMatch(/append-only/);
      expect(await count(), table).toEqual({ n: 1 });
    }
  });

  it("first administrator: creates one, then refuses a second", async () => {
    const { createFirstAdministrator } = await import("../../../scripts/first-administrator");
    const { ORG_EMAIL_DOMAINS } = await import("@/lib/auth/settings");
    // The last listed domain: any of the organisation's domains will do.
    const domain = ORG_EMAIL_DOMAINS[ORG_EMAIL_DOMAINS.length - 1];
    const input = {
      email: `first-${stamp}@${domain}`,
      displayName: "First",
      objectId: crypto.randomUUID(),
      tenantId: "11111111-1111-1111-1111-111111111111",
      ranBy: "the test",
    };
    await createFirstAdministrator(input);
    await expect(createFirstAdministrator({ ...input, email: `second-${stamp}@${ORG_EMAIL_DOMAINS[0]}` })).rejects.toThrow(/already exists/);
    await expect(createFirstAdministrator({ ...input, email: `x-${stamp}@elsewhere.example` })).rejects.toThrow(/must be an @/);
  });

  it("two administrators demoting each other at once: exactly one wins", async () => {
    // Leave only A and B as active administrators.
    await db.execute(sql`
      insert into person_assignments (person_id, role, active, note)
      select person_id, 'member', false, 'reset by db.integration.test'
      from (select distinct on (person_id) person_id, role, active from person_assignments order by person_id, set_at desc, id desc) l
      where l.role = 'administrator' and l.active`);
    const a = (await directory.addPerson({ email: `a-${stamp}@org.example`, displayName: "A", role: "administrator" }, null)).person;
    const b = (await directory.addPerson({ email: `b-${stamp}@org.example`, displayName: "B", role: "administrator" }, null)).person;
    const results = await Promise.allSettled([
      directory.setAssignment({ personId: a.id, role: "member", active: true }, b.id),
      directory.setAssignment({ personId: b.id, role: "member", active: true }, a.id),
    ]);
    expect(results.filter((r) => r.status === "fulfilled")).toHaveLength(1);
    expect(results.filter((r) => r.status === "rejected")).toHaveLength(1);
  });

  it("a forged Microsoft callback leaves a refused_other row", async () => {
    const { auth } = await import("@/lib/auth/server");
    const before = await db.select({ n: sql<number>`count(*)::int` }).from(schema.signInEvents);
    await auth.handler(new Request("http://localhost:3000/api/auth/callback/microsoft?code=forged&state=forged"));
    const after = await db.select({ n: sql<number>`count(*)::int` }).from(schema.signInEvents);
    expect(after[0].n).toBe(before[0].n + 1);
  });

  it("the server refuses an unsafe callbackURL on a sign-in start, whatever the page sent (C22)", async () => {
    const { auth } = await import("@/lib/auth/server");
    const start = (callbackURL: string) =>
      auth.handler(
        new Request("http://localhost:3000/api/auth/sign-in/social", {
          method: "POST",
          headers: { "content-type": "application/json", origin: "http://localhost:3000" },
          body: JSON.stringify({ provider: "microsoft", callbackURL, disableRedirect: true }),
        }),
      );
    for (const bad of ["/\\evil.example", "//evil.example", "https://evil.example/", "/%5Cevil.example"]) {
      expect((await start(bad)).status).toBe(403);
    }
    expect((await start("/reports")).status).toBe(200);
  });

  it("refuses a bare id-token sign-in: only the code flow with PKCE and state makes a session", async () => {
    const { auth } = await import("@/lib/auth/server");
    const before = await db.select({ n: sql<number>`count(*)::int` }).from(schema.signInEvents);
    const res = await auth.handler(
      new Request("http://localhost:3000/api/auth/sign-in/social", {
        method: "POST",
        headers: { "content-type": "application/json", origin: "http://localhost:3000" },
        body: JSON.stringify({ provider: "microsoft", idToken: { token: "a.b.c" } }),
      }),
    );
    expect(res.status).toBe(404);
    expect(await res.json()).toMatchObject({ code: "ID_TOKEN_NOT_SUPPORTED" });
    expect(res.headers.get("set-cookie") ?? "").not.toMatch(/session_token/);
    // Refused before any session exists, so the gate writes no row.
    const after = await db.select({ n: sql<number>`count(*)::int` }).from(schema.signInEvents);
    expect(after[0].n).toBe(before[0].n);
  });

  it("the session hook: a listed .invalid test identity gets a session; a real address never does", async () => {
    const { auth } = await import("@/lib/auth/server");
    const ctx = await auth.$context;
    const password = `pw-${stamp}-long-enough`;
    async function withPassword(email: string) {
      const u = await ctx.internalAdapter.createUser({ email, name: "T", emailVerified: true }, { method: "email-password" });
      await ctx.internalAdapter.createAccount({ userId: u.id, providerId: "credential", accountId: u.id, password: await ctx.password.hash(password) });
    }
    const testAddress = `t-${stamp}@site.invalid`;
    await directory.addPerson({ email: testAddress, displayName: "T", role: "member" }, null);
    await withPassword(testAddress);
    const ok = await auth.api.signInEmail({ body: { email: testAddress, password } });
    expect(ok.token).toBeTruthy();

    const realAddress = `real-${stamp}@org.example`;
    await directory.addPerson({ email: realAddress, displayName: "R", role: "member" }, null);
    await withPassword(realAddress);
    await expect(auth.api.signInEmail({ body: { email: realAddress, password } })).rejects.toThrow();
    const [row] = await db
      .select({ outcome: schema.signInEvents.outcome, detail: schema.signInEvents.detail })
      .from(schema.signInEvents)
      .where(sql`${schema.signInEvents.emailAttempted} = ${realAddress}`);
    expect(row).toEqual({ outcome: "refused_password_not_allowed_here", detail: "not_a_test_address" });
  });

  it("a wrong password leaves a refused_other row", async () => {
    const { auth } = await import("@/lib/auth/server");
    const address = `t-${stamp}@site.invalid`;
    await auth.handler(
      new Request("http://localhost:3000/api/auth/sign-in/email", {
        method: "POST",
        headers: { "content-type": "application/json", origin: "http://localhost:3000" },
        body: JSON.stringify({ email: address, password: "wrong-password-here" }),
      }),
    );
    const rows = await db
      .select({ outcome: schema.signInEvents.outcome })
      .from(schema.signInEvents)
      .where(sql`${schema.signInEvents.emailAttempted} = ${address} and ${schema.signInEvents.outcome} = 'refused_other'`);
    expect(rows.length).toBeGreaterThanOrEqual(1);
  });

  /** A Better Auth user with a Microsoft account and a stored id token, as a real callback leaves them. */
  async function microsoftSignIn() {
    const { auth } = await import("@/lib/auth/server");
    const ctx = await auth.$context;
    const hook = auth.options.databaseHooks!.session!.create!.before!;
    const aud = process.env.MICROSOFT_ENTRA_CLIENT_ID;
    const token = (tid: string, extra: Record<string, unknown> = {}) =>
      `${Buffer.from("{}").toString("base64url")}.${Buffer.from(JSON.stringify({ tid, aud, ...extra })).toString("base64url")}.sig`;
    async function microsoftUser(email: string, oid: string, tid: string, extra: Record<string, unknown> = {}) {
      const u = await ctx.internalAdapter.createUser({ email, name: "M", emailVerified: true }, { method: "oauth" } as never);
      await ctx.internalAdapter.createAccount({ userId: u.id, providerId: "microsoft", accountId: oid, idToken: token(tid, extra) });
      return u.id;
    }
    const session = (userId: string) => ({ userId, token: "t", expiresAt: new Date(), ipAddress: "", userAgent: "" }) as never;
    const cbx = { path: "/callback/:id" } as never;
    return { hook, microsoftUser, session, cbx };
  }

  async function newestAssignment(personId: string) {
    const [row] = await db
      .select({ role: schema.personAssignments.role, active: schema.personAssignments.active, note: schema.personAssignments.note, setBy: schema.personAssignments.setByPersonId })
      .from(schema.personAssignments)
      .where(sql`${schema.personAssignments.personId} = ${personId}`)
      .orderBy(sql`${schema.personAssignments.setAt} desc, ${schema.personAssignments.id} desc`)
      .limit(1);
    return row;
  }

  it("the session hook on a Microsoft account: foreign tenant refused and its rows removed; a bound person granted", async () => {
    const { user } = await import("@/db/schema/auth");
    const { JOIN_MODE } = await import("@/lib/auth/settings");
    const { hook, microsoftUser, session, cbx } = await microsoftSignIn();

    const foreignId = await microsoftUser(`f-${stamp}@org.example`, crypto.randomUUID(), "99999999-9999-9999-9999-999999999999");
    await expect(hook(session(foreignId), cbx)).rejects.toMatchObject({ body: { code: "refused_wrong_tenant" } });
    expect(await db.select().from(user).where(sql`${user.id} = ${foreignId}`)).toHaveLength(0);

    const oid = crypto.randomUUID();
    const tenant = process.env.MICROSOFT_ENTRA_TENANT_ID!;
    await directory.addPerson({ email: `bound-${stamp}@org.example`, displayName: "B", role: "member", objectId: oid, tenantId: tenant }, null);
    const renamedId = await microsoftUser(`renamed-${stamp}@org.example`, oid, tenant);
    await expect(hook(session(renamedId), cbx)).resolves.toBeUndefined();

    // A different Microsoft account claiming the bound person's address is refused in either JOIN_MODE.
    const imposterId = await microsoftUser(`bound-${stamp}@org.example`, crypto.randomUUID(), tenant);
    await expect(hook(session(imposterId), cbx)).rejects.toMatchObject({ body: { code: "refused_identity_mismatch" } });

    // Someone not on the list: refused with JOIN_MODE listed; JOIN_MODE group is below.
    const strangerId = await microsoftUser(`stranger-${stamp}@org.example`, crypto.randomUUID(), tenant);
    if (JOIN_MODE === "listed") {
      await expect(hook(session(strangerId), cbx)).rejects.toMatchObject({ body: { code: "refused_not_on_the_list" } });
      expect(await db.select().from(user).where(sql`${user.id} = ${strangerId}`)).toHaveLength(0);
    }
  });

  it("JOIN_MODE: a group member not on the list joins as a member (group), or is refused and nothing is added (listed)", async () => {
    const { ALLOW_GUESTS, JOIN_MODE, ORG_EMAIL_DOMAINS } = await import("@/lib/auth/settings");
    const { JOINED_NOTE } = await import("@/lib/auth/gate-store");
    const { hook, microsoftUser, session, cbx } = await microsoftSignIn();
    const tenant = process.env.MICROSOFT_ENTRA_TENANT_ID!;
    const oid = crypto.randomUUID();
    // On the organisation's own domain, so ALLOW_GUESTS never decides this join.
    const email = `joiner-${stamp}@${ORG_EMAIL_DOMAINS[0]}`;
    const userId = await microsoftUser(email, oid, tenant);
    const listed = async () => db.select({ id: schema.people.id }).from(schema.people).where(sql`lower(${schema.people.email}) = ${email}`);

    if (JOIN_MODE === "listed") {
      await expect(hook(session(userId), cbx)).rejects.toMatchObject({ body: { code: "refused_not_on_the_list" } });
      expect(await listed()).toHaveLength(0);
      return;
    }
    await expect(hook(session(userId), cbx)).resolves.toBeUndefined();
    const [person] = await listed();
    expect(person).toBeDefined();
    const [identity] = await db
      .select({ objectId: schema.personIdentities.objectId, boundBy: schema.personIdentities.boundBy })
      .from(schema.personIdentities)
      .where(sql`${schema.personIdentities.personId} = ${person!.id}`);
    expect(identity).toEqual({ objectId: oid, boundBy: "first sign-in" });
    expect(await newestAssignment(person!.id)).toMatchObject({ role: "member", active: true, note: JOINED_NOTE, setBy: null });
    const [event] = await db
      .select({ outcome: schema.signInEvents.outcome, detail: schema.signInEvents.detail })
      .from(schema.signInEvents)
      .where(sql`${schema.signInEvents.personId} = ${person!.id}`);
    expect(event).toEqual({ outcome: "granted", detail: "joined_from_group" });

    // The second sign-in finds them by object id and adds nothing.
    const again = await microsoftUser(`joiner-renamed-${stamp}@org.example`, oid, tenant);
    await expect(hook(session(again), cbx)).resolves.toBeUndefined();
    expect(await db.select().from(schema.people).where(sql`lower(${schema.people.email}) like ${`joiner-%${stamp}@%`}`)).toHaveLength(1);

    // A group member outside the organisation's domains (a B2B guest): refused with ALLOW_GUESTS no, joins with yes.
    const guestEmail = `guest-${stamp}@guest-org.example`;
    const guestId = await microsoftUser(guestEmail, crypto.randomUUID(), tenant);
    const guestListed = async () => db.select({ id: schema.people.id }).from(schema.people).where(sql`lower(${schema.people.email}) = ${guestEmail}`);
    if (ALLOW_GUESTS === "no") {
      await expect(hook(session(guestId), cbx)).rejects.toMatchObject({ body: { code: "refused_not_on_the_list" } });
      expect(await guestListed()).toHaveLength(0);
      const [refused] = await db
        .select({ outcome: schema.signInEvents.outcome, detail: schema.signInEvents.detail })
        .from(schema.signInEvents)
        .where(sql`lower(${schema.signInEvents.emailAttempted}) = ${guestEmail}`);
      expect(refused).toEqual({ outcome: "refused_not_on_the_list", detail: "outside_org_domains" });
    } else {
      await expect(hook(session(guestId), cbx)).resolves.toBeUndefined();
      expect(await guestListed()).toHaveLength(1);
    }
  });

  it("ROLE_SOURCE: the Entra app role sets the role at sign-in (entra), or is never read (site)", async () => {
    const { ROLE_SOURCE } = await import("@/lib/auth/settings");
    const { ENTRA_ROLE_NOTE } = await import("@/lib/auth/gate-store");
    const { hook, microsoftUser, session, cbx } = await microsoftSignIn();
    const tenant = process.env.MICROSOFT_ENTRA_TENANT_ID!;
    const oid = crypto.randomUUID();
    const { person } = await directory.addPerson(
      { email: `roles-${stamp}@org.example`, displayName: "R", role: "member", objectId: oid, tenantId: tenant },
      null,
    );

    const asAdmin = await microsoftUser(`roles-${stamp}@org.example`, oid, tenant, { roles: ["administrator"] });
    await expect(hook(session(asAdmin), cbx)).resolves.toBeUndefined();
    if (ROLE_SOURCE === "site") {
      expect(await newestAssignment(person.id)).toMatchObject({ role: "member", active: true });
      return;
    }
    expect(await newestAssignment(person.id)).toMatchObject({ role: "administrator", active: true, note: ENTRA_ROLE_NOTE, setBy: null });

    // The app role taken away in Entra: the next sign-in appends a member row.
    const asMember = await microsoftUser(`roles-again-${stamp}@org.example`, oid, tenant);
    await expect(hook(session(asMember), cbx)).resolves.toBeUndefined();
    expect(await newestAssignment(person.id)).toMatchObject({ role: "member", active: true, note: ENTRA_ROLE_NOTE });

    // Switched off on the site: refused whatever Entra says, and no role row is written.
    await directory.setAssignment({ personId: person.id, role: "member", active: false }, person.id);
    const rows = async () => (await db.select().from(schema.personAssignments).where(sql`${schema.personAssignments.personId} = ${person.id}`)).length;
    const before = await rows();
    const switchedOff = await microsoftUser(`roles-off-${stamp}@org.example`, oid, tenant, { roles: ["administrator"] });
    await expect(hook(session(switchedOff), cbx)).rejects.toMatchObject({ body: { code: "refused_switched_off" } });
    expect(await rows()).toBe(before);
  });

  it("addPerson: an object id already on the list is refused by name, and nothing is added", async () => {
    const tenant = process.env.MICROSOFT_ENTRA_TENANT_ID!;
    const oid = crypto.randomUUID();
    await directory.addPerson({ email: `alex.smith-${stamp}@org.example`, displayName: "Alex Smith", role: "member", objectId: oid, tenantId: tenant }, null);
    // Their address changed in Entra; the object id did not.
    const renamed = `alex.jones-${stamp}@org.example`;
    await expect(
      directory.addPerson({ email: renamed, displayName: "Alex Jones", role: "member", objectId: oid.toUpperCase(), tenantId: tenant }, null),
    ).rejects.toMatchObject({ code: "duplicate_identity", message: expect.stringContaining(`alex.smith-${stamp}@org.example`) });
    expect(await db.select().from(schema.people).where(sql`lower(${schema.people.email}) = ${renamed}`)).toHaveLength(0);
  });

  it("seed-people: adds each person bound by object id in their role; a second run changes nothing", async () => {
    const { seedPeople, databaseSeedStore, parsePeopleFile } = await import("../../../scripts/seed-people");
    const { ORG_EMAIL_DOMAINS } = await import("@/lib/auth/settings");
    const tenant = "11111111-1111-1111-1111-111111111111";
    const text = JSON.stringify([
      { oid: crypto.randomUUID(), email: `seed-a-${stamp}@${ORG_EMAIL_DOMAINS[0]}`, name: "Seed A", role: "administrator" },
      { oid: crypto.randomUUID(), email: `seed-b-${stamp}@${ORG_EMAIL_DOMAINS[ORG_EMAIL_DOMAINS.length - 1]}`, name: "Seed B", role: "member" },
    ]);
    const entries = parsePeopleFile(text);
    const store = await databaseSeedStore();
    const options = { tenantId: tenant, ranBy: "the test" };
    expect(await seedPeople(entries, options, store)).toEqual({ added: 2, alreadyOnList: 0, bound: 0, refused: [] });
    const count = async () =>
      (await db.execute(sql`select
        (select count(*)::int from people where email like ${`seed-_-${stamp}@%`}) as people,
        (select count(*)::int from person_identities i join people p on p.id = i.person_id where p.email like ${`seed-_-${stamp}@%`}) as identities,
        (select count(*)::int from person_assignments a join people p on p.id = a.person_id where p.email like ${`seed-_-${stamp}@%`}) as assignments`))[0];
    expect(await count()).toEqual({ people: 2, identities: 2, assignments: 2 });
    const [a] = await db.select({ id: schema.people.id }).from(schema.people).where(sql`${schema.people.email} = ${entries[0]!.email}`);
    expect(await newestAssignment(a!.id)).toMatchObject({ role: "administrator", active: true, setBy: null });

    expect(await seedPeople(entries, options, store)).toEqual({ added: 0, alreadyOnList: 2, bound: 0, refused: [] });
    expect(await count()).toEqual({ people: 2, identities: 2, assignments: 2 });
  });

  it("the absolute cap: a session older than SESSION_MAX_HOURS is refused, deleted and logged (C16, C17)", async () => {
    const { auth } = await import("@/lib/auth/server");
    const { SESSION_MAX_HOURS } = await import("@/lib/auth/settings");
    const { session } = await import("@/db/schema/auth");
    const { getCurrentPerson } = await import("@/lib/auth/current-person");
    const ctx = await auth.$context;
    const address = `cap-${stamp}@site.invalid`;
    const password = `pw-${stamp}-long-enough`;
    await directory.addPerson({ email: address, displayName: "Cap", role: "member" }, null);
    const u = await ctx.internalAdapter.createUser({ email: address, name: "Cap", emailVerified: true }, { method: "email-password" });
    await ctx.internalAdapter.createAccount({ userId: u.id, providerId: "credential", accountId: u.id, password: await ctx.password.hash(password) });

    const signedIn = await auth.api.signInEmail({ body: { email: address, password }, returnHeaders: true });
    const cookie = signedIn.headers
      .getSetCookie()
      .map((c) => c.split(";")[0])
      .join("; ");
    request.headers = new Headers({ cookie });

    // A fresh session passes, so the cookie and the mock are real.
    expect((await getCurrentPerson())?.email).toBe(address);

    // One minute short of the cap, still inside the idle limit: it passes.
    await db.execute(sql`update session set created_at = now() - (${SESSION_MAX_HOURS}::int * interval '1 hour' - interval '1 minute') where user_id = ${u.id}`);
    expect((await getCurrentPerson())?.email).toBe(address);

    // The configured cap and one minute old, still inside the idle limit: refused.
    await db.execute(sql`update session set created_at = now() - (${SESSION_MAX_HOURS}::int * interval '1 hour' + interval '1 minute') where user_id = ${u.id}`);
    expect(await getCurrentPerson()).toBeNull();
    expect(await db.select().from(session).where(sql`${session.userId} = ${u.id}`)).toHaveLength(0);
    const rows = await db
      .select({ outcome: schema.signInEvents.outcome, path: schema.signInEvents.path })
      .from(schema.signInEvents)
      .where(sql`${schema.signInEvents.emailAttempted} = ${address} and ${schema.signInEvents.outcome} = 'refused_session_expired'`);
    expect(rows).toEqual([{ outcome: "refused_session_expired", path: "session" }]);
    request.headers = new Headers();
  });

  it("refuses a sign-up through the API: no user, no session (C27)", async () => {
    const { auth } = await import("@/lib/auth/server");
    const { user } = await import("@/db/schema/auth");
    const address = `signup-${stamp}@site.invalid`;
    const res = await auth.handler(
      new Request("http://localhost:3000/api/auth/sign-up/email", {
        method: "POST",
        headers: { "content-type": "application/json", origin: "http://localhost:3000" },
        body: JSON.stringify({ email: address, password: "not-a-real-password-1", name: "Probe" }),
      }),
    );
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(res.status).toBeLessThan(500);
    expect(await res.json()).toMatchObject({ code: "EMAIL_PASSWORD_SIGN_UP_DISABLED" });
    expect(res.headers.get("set-cookie") ?? "").not.toMatch(/session_token/);
    expect(await db.select().from(user).where(sql`${user.email} = ${address}`)).toHaveLength(0);
  });
});
