/**
 * Puts the people chosen during setup on the site's own list, so they can
 * sign in without being added one by one.
 *
 * Reads the people file the setup wrote (owner-only, never committed):
 *   [{ "oid": "<object id>", "email": "<address>", "name": "<full name>", "role": "administrator" | "member" }]
 *
 *   npx tsx scripts/seed-people.ts ~/.config/<slug>/people.json --tenant <tenant id> --by "<who ran it>"
 *
 * Each person is added with their Entra identity bound now (tenant id +
 * object id), so their first sign-in matches on object id, never on email
 * (control C5), with an active row in the role the file gives.
 *
 * Safe to run again: a person already bound, or already on the list, is
 * counted and left alone; their role is never changed here (use
 * scripts/set-person.ts). An address already bound to a different Microsoft
 * account is refused, never re-bound. Addresses must be on one of the
 * organisation's email domains unless --allow-other-domains is given (only
 * when guests may sign in). It prints counts, never names or addresses.
 *
 * --tenant defaults to MICROSOFT_ENTRA_TENANT_ID. Reads DATABASE_URL from the
 * environment first, then .env.local. For production, pass the production URL
 * from its owner-only file, never typed on the line:
 *   DATABASE_URL="$(cat ~/.config/<slug>/database-url-prod)" npx tsx scripts/seed-people.ts ...
 */
import { config } from "dotenv";

config({ path: ".env.local", quiet: true });

import { readFileSync } from "node:fs";

import { emailOnDomains, ORG_EMAIL_DOMAINS } from "../__SRC_ROOT__/lib/auth/settings";

export type SeedRole = "administrator" | "member";

export interface SeedEntry {
  oid: string;
  email: string;
  name: string;
  role: SeedRole;
}

export interface SeedOptions {
  tenantId: string;
  ranBy: string;
  allowOtherDomains?: boolean;
  /** For the note on each new row; defaults to today. */
  today?: string;
}

export interface SeedStore {
  personByIdentity(tenantId: string, objectId: string): Promise<{ personId: string } | null>;
  personByEmail(email: string): Promise<{ personId: string; boundObjectId: string | null } | null>;
  /** Adds the person, their identity and an active row, in one transaction. False if the address or identity was taken first. */
  addPerson(entry: SeedEntry, tenantId: string, note: string): Promise<boolean>;
  /** Binds an identity to a listed person with none. False if either side was bound first. */
  bindIdentity(personId: string, tenantId: string, objectId: string): Promise<boolean>;
}

export interface SeedResult {
  added: number;
  alreadyOnList: number;
  bound: number;
  refused: Array<{ entry: number; reason: string }>;
}

const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Reads and checks the people file. Throws, naming entry numbers and never an
 * address, when anything in it is wrong, so a bad file changes nothing.
 */
export function parsePeopleFile(text: string, domains: readonly string[] = ORG_EMAIL_DOMAINS, allowOtherDomains = false): SeedEntry[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error("Refusing: the people file is not JSON.");
  }
  if (!Array.isArray(parsed)) throw new Error("Refusing: the people file must be a JSON list.");
  const problems: string[] = [];
  const seenOid = new Set<string>();
  const seenEmail = new Set<string>();
  const entries: SeedEntry[] = [];
  parsed.forEach((raw: unknown, i) => {
    const n = i + 1;
    const e = (raw ?? {}) as Record<string, unknown>;
    const oid = typeof e.oid === "string" ? e.oid.trim().toLowerCase() : "";
    const email = typeof e.email === "string" ? e.email.trim().toLowerCase() : "";
    const name = typeof e.name === "string" ? e.name.trim() : "";
    const role = e.role;
    if (!GUID.test(oid)) problems.push(`entry ${n}: oid is not an object id`);
    if (!/^[^@\s]+@[^@\s]+$/.test(email)) problems.push(`entry ${n}: email is not an address`);
    else if (!allowOtherDomains && !emailOnDomains(email, domains)) problems.push(`entry ${n}: email is not on the organisation's domains`);
    if (!name) problems.push(`entry ${n}: name is empty`);
    if (role !== "administrator" && role !== "member") problems.push(`entry ${n}: role must be administrator or member`);
    if (oid && seenOid.has(oid)) problems.push(`entry ${n}: the same oid appears twice`);
    if (email && seenEmail.has(email)) problems.push(`entry ${n}: the same email appears twice`);
    seenOid.add(oid);
    seenEmail.add(email);
    entries.push({ oid, email, name, role: role as SeedRole });
  });
  if (problems.length > 0) {
    const offDomain = problems.some((p) => p.endsWith("is not on the organisation's domains"));
    const hint = offDomain
      ? " Take those entries out of the file (and the sign-in group), or add their domain to EMAIL_DOMAINS; --allow-other-domains only when guests may sign in."
      : "";
    throw new Error(`Refusing: the people file has ${problems.length} problem(s): ${problems.join("; ")}.${hint}`);
  }
  return entries;
}

/** Adds each entry once. Running it again with the same file changes nothing. */
export async function seedPeople(entries: SeedEntry[], options: SeedOptions, store: SeedStore): Promise<SeedResult> {
  const tenantId = options.tenantId.trim().toLowerCase();
  if (!GUID.test(tenantId)) throw new Error("Refusing: --tenant must be the tenant id (a GUID).");
  if (!options.ranBy.trim()) throw new Error("Refusing: say who ran this with --by.");
  const today = options.today ?? new Date().toISOString().slice(0, 10);
  const note = `Seeded from the setup by the seed-people script, run by ${options.ranBy.trim()}, ${today}.`;
  const result: SeedResult = { added: 0, alreadyOnList: 0, bound: 0, refused: [] };

  for (const [i, entry] of entries.entries()) {
    const n = i + 1;
    if (await store.personByIdentity(tenantId, entry.oid)) {
      result.alreadyOnList += 1;
      continue;
    }
    const listed = await store.personByEmail(entry.email);
    if (listed) {
      if (listed.boundObjectId) {
        result.refused.push({ entry: n, reason: "the address is on the list, bound to a different Microsoft account" });
      } else if (await store.bindIdentity(listed.personId, tenantId, entry.oid)) {
        result.bound += 1;
      } else {
        result.refused.push({ entry: n, reason: "another sign-in bound this person or this identity first" });
      }
      continue;
    }
    if (await store.addPerson(entry, tenantId, note)) result.added += 1;
    else result.refused.push({ entry: n, reason: "another change added this address or identity first; run again" });
  }
  return result;
}

/** The store over the site's database. */
export async function databaseSeedStore(): Promise<SeedStore> {
  const { and, eq, sql } = await import("drizzle-orm");
  const { getDb } = await import("../__SRC_ROOT__/lib/db");
  const { people, personAssignments, personIdentities } = await import("../__SRC_ROOT__/db/schema/access");
  const db = getDb();
  const lost = new Error("lost the race");
  return {
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
    async addPerson(entry, tenantId, note) {
      try {
        return await db.transaction(async (tx) => {
          const [person] = await tx
            .insert(people)
            .values({ email: entry.email, displayName: entry.name, addedByPersonId: null, note })
            .onConflictDoNothing()
            .returning({ id: people.id });
          if (!person) throw lost;
          const bound = await tx
            .insert(personIdentities)
            .values({ personId: person.id, tenantId, objectId: entry.oid, boundBy: "added with object id" })
            .onConflictDoNothing()
            .returning({ id: personIdentities.id });
          if (bound.length !== 1) throw lost;
          await tx.insert(personAssignments).values({ personId: person.id, role: entry.role, active: true, setByPersonId: null, note });
          return true;
        });
      } catch (error) {
        if (error === lost) return false;
        throw error;
      }
    },
    async bindIdentity(personId, tenantId, objectId) {
      const rows = await db
        .insert(personIdentities)
        .values({ personId, tenantId, objectId, boundBy: "added with object id" })
        .onConflictDoNothing()
        .returning({ id: personIdentities.id });
      return rows.length === 1;
    },
  };
}

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i > -1 ? process.argv[i + 1] : undefined;
}

async function main() {
  const file = process.argv[2];
  if (!file || file.startsWith("--")) {
    throw new Error('Usage: npx tsx scripts/seed-people.ts <people.json> --tenant <tenant id> --by "<who>" [--allow-other-domains]');
  }
  const allowOtherDomains = process.argv.includes("--allow-other-domains");
  const entries = parsePeopleFile(readFileSync(file, "utf8"), ORG_EMAIL_DOMAINS, allowOtherDomains);
  const result = await seedPeople(
    entries,
    { tenantId: arg("--tenant") ?? process.env.MICROSOFT_ENTRA_TENANT_ID ?? "", ranBy: arg("--by") ?? "", allowOtherDomains },
    await databaseSeedStore(),
  );
  console.log(
    `People file: ${entries.length} entries. Added ${result.added}, already on the list ${result.alreadyOnList}, ` +
      `bound to their Microsoft account ${result.bound}, refused ${result.refused.length}.`,
  );
  for (const r of result.refused) console.log(`Entry ${r.entry} refused: ${r.reason}.`);
  if (result.refused.length > 0) process.exitCode = 1;
}

if (process.argv[1]?.endsWith("seed-people.ts")) {
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
