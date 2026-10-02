/**
 * The seed-people script without a database: the file check, and that a
 * second run with the same file changes nothing (control C5: every seeded
 * person is bound by object id, never matched later by email).
 */
import { describe, expect, it } from "vitest";

import { parsePeopleFile, seedPeople, type SeedEntry, type SeedStore } from "../../../scripts/seed-people";

const TENANT = "11111111-1111-1111-1111-111111111111";
const DOMAINS = ["org.example", "second.example"];
const oid = (n: number) => `${String(n).repeat(8).slice(0, 8)}-0000-0000-0000-000000000000`;

/** An in-memory people list with the same rules as the tables: one identity per person, one person per identity, unique addresses. */
function memoryStore() {
  const people = new Map<string, { email: string; name: string; role: string; objectId: string | null; note: string }>();
  let next = 0;
  const store: SeedStore = {
    async personByIdentity(tenantId, objectId) {
      if (tenantId !== TENANT) return null;
      for (const [id, p] of people) if (p.objectId === objectId) return { personId: id };
      return null;
    },
    async personByEmail(email) {
      for (const [id, p] of people) if (p.email === email.toLowerCase()) return { personId: id, boundObjectId: p.objectId };
      return null;
    },
    async addPerson(entry, _tenantId, note) {
      if ([...people.values()].some((p) => p.email === entry.email || p.objectId === entry.oid)) return false;
      people.set(`p${++next}`, { email: entry.email, name: entry.name, role: entry.role, objectId: entry.oid, note });
      return true;
    },
    async bindIdentity(personId, _tenantId, objectId) {
      const p = people.get(personId);
      if (!p || p.objectId || [...people.values()].some((o) => o.objectId === objectId)) return false;
      p.objectId = objectId;
      return true;
    },
  };
  return { store, people };
}

const file = (entries: unknown[]) => JSON.stringify(entries);
const good: SeedEntry[] = [
  { oid: oid(1), email: "first@org.example", name: "First", role: "administrator" },
  { oid: oid(2), email: "second@second.example", name: "Second", role: "member" },
  { oid: oid(3), email: "third@org.example", name: "Third", role: "member" },
];

describe("parsePeopleFile", () => {
  it("reads a good file, lower-casing addresses and object ids", () => {
    const text = file([{ oid: oid(1).toUpperCase(), email: "First@Org.Example", name: " First ", role: "administrator" }]);
    expect(parsePeopleFile(text, DOMAINS)).toEqual([{ oid: oid(1), email: "first@org.example", name: "First", role: "administrator" }]);
  });

  it.each([
    ["not JSON", "{", /not JSON/],
    ["not a list", "{}", /must be a JSON list/],
    ["a bad oid", file([{ oid: "x", email: "a@org.example", name: "A", role: "member" }]), /entry 1: oid/],
    ["a bad address", file([{ oid: oid(1), email: "nobody", name: "A", role: "member" }]), /entry 1: email is not an address/],
    ["another domain", file([{ oid: oid(1), email: "a@elsewhere.example", name: "A", role: "member" }]), /entry 1: email is not on the organisation's domains/],
    ["no name", file([{ oid: oid(1), email: "a@org.example", name: " ", role: "member" }]), /entry 1: name is empty/],
    ["an unknown role", file([{ oid: oid(1), email: "a@org.example", name: "A", role: "owner" }]), /entry 1: role/],
    [
      "the same person twice",
      file([
        { oid: oid(1), email: "a@org.example", name: "A", role: "member" },
        { oid: oid(1), email: "A@org.example", name: "A", role: "member" },
      ]),
      /entry 2: the same oid appears twice; entry 2: the same email appears twice/,
    ],
  ])("refuses %s, naming the entry and never the address", (_label, text, message) => {
    let thrown = "";
    try {
      parsePeopleFile(text as string, DOMAINS);
    } catch (error) {
      thrown = (error as Error).message;
    }
    expect(thrown).toMatch(message as RegExp);
    expect(thrown).not.toMatch(/@/);
  });

  it("another domain is allowed only when asked for", () => {
    const text = file([{ oid: oid(1), email: "guest@elsewhere.example", name: "Guest", role: "member" }]);
    expect(parsePeopleFile(text, DOMAINS, true)).toHaveLength(1);
  });

  it("says what to do about an address on another domain, and only then", () => {
    const off = file([{ oid: oid(1), email: "guest@elsewhere.example", name: "Guest", role: "member" }]);
    expect(() => parsePeopleFile(off, DOMAINS)).toThrow(/add their domain to EMAIL_DOMAINS; --allow-other-domains only when guests may sign in/);
    const noName = file([{ oid: oid(1), email: "a@org.example", name: " ", role: "member" }]);
    expect(() => parsePeopleFile(noName, DOMAINS)).not.toThrow(/EMAIL_DOMAINS/);
  });
});

describe("seedPeople", () => {
  const options = { tenantId: TENANT, ranBy: "the test", today: "2026-01-15" };

  it("adds everyone with their role and identity, then a second run changes nothing", async () => {
    const { store, people } = memoryStore();
    expect(await seedPeople(good, options, store)).toEqual({ added: 3, alreadyOnList: 0, bound: 0, refused: [] });
    expect([...people.values()].map((p) => [p.email, p.role, p.objectId])).toEqual([
      ["first@org.example", "administrator", oid(1)],
      ["second@second.example", "member", oid(2)],
      ["third@org.example", "member", oid(3)],
    ]);
    expect([...people.values()][0]?.note).toBe("Seeded from the setup by the seed-people script, run by the test, 2026-01-15.");

    const before = JSON.stringify([...people]);
    expect(await seedPeople(good, options, store)).toEqual({ added: 0, alreadyOnList: 3, bound: 0, refused: [] });
    expect(JSON.stringify([...people])).toBe(before);
  });

  it("binds a listed person with no identity yet, and never changes their role", async () => {
    const { store, people } = memoryStore();
    people.set("p0", { email: "first@org.example", name: "First", role: "member", objectId: null, note: "added earlier" });
    const result = await seedPeople(good.slice(0, 1), options, store);
    expect(result).toEqual({ added: 0, alreadyOnList: 0, bound: 1, refused: [] });
    expect(people.get("p0")).toMatchObject({ objectId: oid(1), role: "member" });
    expect(await seedPeople(good.slice(0, 1), options, store)).toEqual({ added: 0, alreadyOnList: 1, bound: 0, refused: [] });
  });

  it("refuses an address already bound to a different Microsoft account, and leaves it alone", async () => {
    const { store, people } = memoryStore();
    people.set("p0", { email: "first@org.example", name: "First", role: "member", objectId: oid(9), note: "added earlier" });
    const result = await seedPeople(good.slice(0, 1), options, store);
    expect(result.refused).toEqual([{ entry: 1, reason: "the address is on the list, bound to a different Microsoft account" }]);
    expect(people.get("p0")?.objectId).toBe(oid(9));
  });

  it("refuses a bad tenant id or no --by before writing anything", async () => {
    const { store, people } = memoryStore();
    await expect(seedPeople(good, { ...options, tenantId: "not-a-guid" }, store)).rejects.toThrow(/--tenant/);
    await expect(seedPeople(good, { ...options, ranBy: " " }, store)).rejects.toThrow(/--by/);
    expect(people.size).toBe(0);
  });
});
