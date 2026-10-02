/**
 * Every branch of the session gate, with no database (control C4, C5, C6, C27),
 * including both ROLE_SOURCE and both JOIN_MODE settings, and ALLOW_GUESTS.
 */
import { describe, expect, it } from "vitest";

import { decideSignIn, roleFromEntraRoles, type GateLookups, type JoinInput, type SiteRole } from "@/lib/auth/gate";
import { claimsFromIdToken } from "@/lib/auth/tenant";

const TENANT = "11111111-1111-1111-1111-111111111111";
const OTHER_TENANT = "22222222-2222-2222-2222-222222222222";
const OID = "33333333-3333-3333-3333-333333333333";
const CLIENT = "55555555-5555-5555-5555-555555555555";

/** An id token for our app unless the claims say otherwise. */
function idToken(claims: Record<string, unknown>): string {
  const b = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b({ alg: "none" })}.${b({ aud: CLIENT, ...claims })}.sig`;
}

interface World {
  email?: string | null;
  microsoft?: { objectId: string; idToken: string | null } | null;
  byIdentity?: Record<string, string>;
  byEmail?: Record<string, { personId: string; boundObjectId: string | null }>;
  active?: Record<string, boolean>;
  /** Each person's newest role; member when not given. */
  role?: Record<string, SiteRole>;
  name?: string | null;
  /** What joinPerson returns: a new person id, or null for a lost race. */
  joinResult?: string | null;
  bindResult?: boolean;
  /** When a bind loses the race: who the identity belongs to on the re-read. */
  identityAfterLostBind?: string | null;
}

function lookups(w: World) {
  const bound: Array<[string, string, string]> = [];
  const joined: JoinInput[] = [];
  const roleRows: Array<[string, SiteRole]> = [];
  let lostBind = false;
  const look: GateLookups = {
    microsoftAccountFor: async () => w.microsoft ?? null,
    emailFor: async () => w.email ?? null,
    nameFor: async () => (w.name === undefined ? "A Person" : w.name),
    personByIdentity: async (t, o) => {
      if (lostBind) return w.identityAfterLostBind ? { personId: w.identityAfterLostBind } : null;
      const hit = w.byIdentity?.[`${t}/${o}`] ?? bound.find(([, bt, bo]) => bt === t && bo === o)?.[0];
      return hit ? { personId: hit } : null;
    },
    personByEmail: async (e) => w.byEmail?.[e] ?? null,
    bindIdentity: async (p, t, o) => {
      if (w.bindResult === false) {
        lostBind = true;
        return false;
      }
      bound.push([p, t, o]);
      return true;
    },
    latestAssignment: async (p) => {
      if (p in (w.active ?? {})) return { active: w.active![p], role: w.role?.[p] ?? "member" };
      // A person the join just added has an active member row.
      if (joined.length > 0 && p === w.joinResult) return { active: true, role: "member" };
      return null;
    },
    joinPerson: async (input) => {
      joined.push(input);
      return w.joinResult ? { personId: w.joinResult } : null;
    },
    setRoleFromEntra: async (p, r) => {
      roleRows.push([p, r]);
    },
  };
  return { look, bound, joined, roleRows };
}

const social = {
  userId: "u1",
  path: "/callback/:id",
  expectedTenantId: TENANT,
  expectedClientId: CLIENT,
  passwordLaneOn: false,
  roleSource: "site",
  joinMode: "listed",
  allowGuests: false,
  orgEmailDomains: ["org.example"],
} as const;

describe("Microsoft sign-in", () => {
  it("refuses a token from another tenant and removes the refused rows", async () => {
    const { look } = lookups({ email: "a@org.example", microsoft: { objectId: OID, idToken: idToken({ tid: OTHER_TENANT }) } });
    const d = await decideSignIn(social, look);
    expect(d.outcome).toBe("refused_wrong_tenant");
    expect(d.tenantIdSeen).toBe(OTHER_TENANT);
    expect(d.removeAuthRows).toBe(true);
  });

  it("refuses when the id token carries no tenant", async () => {
    const { look } = lookups({ email: "a@org.example", microsoft: { objectId: OID, idToken: null } });
    expect((await decideSignIn(social, look)).outcome).toBe("refused_wrong_tenant");
  });

  it("grants a token whose audience is our app (a list naming it, in capitals, is fine)", async () => {
    const { look } = lookups({
      email: "a@org.example",
      microsoft: { objectId: OID, idToken: idToken({ tid: TENANT, aud: ["other", CLIENT.toUpperCase()] }) },
      byIdentity: { [`${TENANT}/${OID}`]: "p1" },
      active: { p1: true },
    });
    const d = await decideSignIn(social, look);
    expect(d.outcome).toBe("granted");
    expect(d.tokenRefusal).toBeUndefined();
  });

  it.each([
    ["another app", "66666666-6666-6666-6666-666666666666"],
    ["no audience", undefined],
    ["a number", 7],
  ])("refuses a token for %s like a wrong tenant, says why, and removes the refused rows", async (_label, aud) => {
    const { look } = lookups({
      email: "a@org.example",
      microsoft: { objectId: OID, idToken: idToken({ tid: TENANT, aud }) },
      byIdentity: { [`${TENANT}/${OID}`]: "p1" },
      active: { p1: true },
    });
    const d = await decideSignIn(social, look);
    expect(d.outcome).toBe("refused_wrong_tenant");
    expect(d.tokenRefusal).toBe("wrong_audience");
    expect(d.tenantIdSeen).toBe(TENANT);
    expect(d.removeAuthRows).toBe(true);
  });

  it("refuses a Microsoft sign-in when the app's client id is not configured", async () => {
    const { look } = lookups({ email: "a@org.example", microsoft: { objectId: OID, idToken: idToken({ tid: TENANT }) } });
    expect((await decideSignIn({ ...social, expectedClientId: null }, look)).outcome).toBe("refused_other");
  });

  it("refuses someone not on the list", async () => {
    const { look } = lookups({ email: "a@org.example", microsoft: { objectId: OID, idToken: idToken({ tid: TENANT }) } });
    const d = await decideSignIn(social, look);
    expect(d.outcome).toBe("refused_not_on_the_list");
    expect(d.removeAuthRows).toBe(true);
  });

  it("binds the identity at first sign-in, then grants", async () => {
    const { look, bound } = lookups({
      email: "a@org.example",
      microsoft: { objectId: OID, idToken: idToken({ tid: TENANT }) },
      byEmail: { "a@org.example": { personId: "p1", boundObjectId: null } },
      active: { p1: true },
    });
    const d = await decideSignIn(social, look);
    expect(d.outcome).toBe("granted");
    expect(bound).toEqual([["p1", TENANT, OID]]);
    expect(d.removeAuthRows).toBe(false);
  });

  it("finds a bound person by object id even after the email changed", async () => {
    const { look } = lookups({
      email: "renamed@org.example",
      microsoft: { objectId: OID, idToken: idToken({ tid: TENANT }) },
      byIdentity: { [`${TENANT}/${OID}`]: "p1" },
      active: { p1: true },
    });
    expect((await decideSignIn(social, look)).outcome).toBe("granted");
  });

  it("refuses a different Microsoft account that claims a bound person's email", async () => {
    const { look } = lookups({
      email: "a@org.example",
      microsoft: { objectId: "44444444-4444-4444-4444-444444444444", idToken: idToken({ tid: TENANT }) },
      byEmail: { "a@org.example": { personId: "p1", boundObjectId: OID } },
      active: { p1: true },
    });
    expect((await decideSignIn(social, look)).outcome).toBe("refused_identity_mismatch");
  });

  it("a bind that loses the race to the same person's other sign-in: granted", async () => {
    const { look, bound } = lookups({
      email: "a@org.example",
      microsoft: { objectId: OID, idToken: idToken({ tid: TENANT }) },
      byEmail: { "a@org.example": { personId: "p1", boundObjectId: null } },
      active: { p1: true },
      bindResult: false,
      identityAfterLostBind: "p1",
    });
    const d = await decideSignIn(social, look);
    expect(d.outcome).toBe("granted");
    expect(d.personId).toBe("p1");
    expect(bound).toEqual([]);
  });

  it.each([
    ["bound to someone else", "p2"],
    ["still unbound", null],
  ])("a bind that loses the race, identity %s on the re-read: refused_identity_mismatch", async (_label, after) => {
    const { look } = lookups({
      email: "a@org.example",
      microsoft: { objectId: OID, idToken: idToken({ tid: TENANT }) },
      byEmail: { "a@org.example": { personId: "p1", boundObjectId: null } },
      active: { p1: true },
      bindResult: false,
      identityAfterLostBind: after,
    });
    const d = await decideSignIn(social, look);
    expect(d.outcome).toBe("refused_identity_mismatch");
    expect(d.personId).toBe("p1");
    expect(d.removeAuthRows).toBe(true);
  });

  it("refuses someone switched off", async () => {
    const { look } = lookups({
      email: "a@org.example",
      microsoft: { objectId: OID, idToken: idToken({ tid: TENANT }) },
      byIdentity: { [`${TENANT}/${OID}`]: "p1" },
      active: { p1: false },
    });
    expect((await decideSignIn(social, look)).outcome).toBe("refused_switched_off");
  });

  it("refuses a person with no assignment at all", async () => {
    const { look } = lookups({
      email: "a@org.example",
      microsoft: { objectId: OID, idToken: idToken({ tid: TENANT }) },
      byIdentity: { [`${TENANT}/${OID}`]: "p1" },
    });
    expect((await decideSignIn(social, look)).outcome).toBe("refused_switched_off");
  });

  it("refuses a session made any other way with no Microsoft account", async () => {
    const { look } = lookups({ email: "a@org.example", microsoft: null });
    expect((await decideSignIn({ ...social, path: "/something-else" }, look)).outcome).toBe("refused_other");
  });
});

describe("the test password lane", () => {
  const pw = { ...social, path: "/sign-in/email", passwordLaneOn: true };

  it("is refused when the lane is off", async () => {
    const { look } = lookups({ email: "t@x.invalid" });
    const d = await decideSignIn({ ...pw, passwordLaneOn: false }, look);
    expect(d.outcome).toBe("refused_password_not_allowed_here");
  });

  it("is refused for a real address", async () => {
    const { look } = lookups({ email: "a@org.example", byEmail: { "a@org.example": { personId: "p1", boundObjectId: null } }, active: { p1: true } });
    const d = await decideSignIn(pw, look);
    expect(d.passwordRefusal).toBe("not_a_test_address");
  });

  it("is refused for a test identity that also has a Microsoft account", async () => {
    const { look } = lookups({ email: "t@x.invalid", microsoft: { objectId: OID, idToken: idToken({ tid: TENANT }) } });
    expect((await decideSignIn(pw, look)).passwordRefusal).toBe("test_account_has_microsoft");
  });

  it("grants a listed, active .invalid identity", async () => {
    const { look } = lookups({ email: "t@x.invalid", byEmail: { "t@x.invalid": { personId: "p9", boundObjectId: null } }, active: { p9: true } });
    expect((await decideSignIn(pw, look)).outcome).toBe("granted");
  });
});

describe("the roles claim", () => {
  it("reads roles beside tid and aud; a missing or odd claim is no roles", () => {
    expect(claimsFromIdToken(idToken({ tid: TENANT, roles: ["administrator"] }))?.roles).toEqual(["administrator"]);
    expect(claimsFromIdToken(idToken({ tid: TENANT, roles: "administrator" }))?.roles).toEqual(["administrator"]);
    expect(claimsFromIdToken(idToken({ tid: TENANT }))?.roles).toEqual([]);
    expect(claimsFromIdToken(idToken({ tid: TENANT, roles: [7, null] }))?.roles).toEqual([]);
  });

  it.each([
    [["administrator"], "administrator"],
    [["Administrator"], "administrator"],
    [["other", "administrator"], "administrator"],
    [["member"], "member"],
    [["admin"], "member"],
    [[], "member"],
  ] as Array<[string[], SiteRole]>)("%o -> %s", (roles, expected) => {
    expect(roleFromEntraRoles(roles)).toBe(expected);
  });
});

describe("ROLE_SOURCE", () => {
  const listedAs = (role: SiteRole, roles?: string[]) =>
    lookups({
      email: "a@org.example",
      microsoft: { objectId: OID, idToken: idToken({ tid: TENANT, ...(roles ? { roles } : {}) }) },
      byIdentity: { [`${TENANT}/${OID}`]: "p1" },
      active: { p1: true },
      role: { p1: role },
    });

  it("site: the token's roles are never read, and the list is never written", async () => {
    const { look, roleRows } = listedAs("member", ["administrator"]);
    const d = await decideSignIn(social, look);
    expect(d.outcome).toBe("granted");
    expect(roleRows).toEqual([]);
    expect(d.grantNote).toBeUndefined();
  });

  it("entra: a new administrator app role appends an administrator row, recorded as from Entra", async () => {
    const { look, roleRows } = listedAs("member", ["administrator"]);
    const d = await decideSignIn({ ...social, roleSource: "entra" }, look);
    expect(d.outcome).toBe("granted");
    expect(roleRows).toEqual([["p1", "administrator"]]);
    expect(d.grantNote).toBe("role_from_entra");
  });

  it("entra: an app role taken away appends a member row", async () => {
    const { look, roleRows } = listedAs("administrator");
    const d = await decideSignIn({ ...social, roleSource: "entra" }, look);
    expect(d.outcome).toBe("granted");
    expect(roleRows).toEqual([["p1", "member"]]);
  });

  it("entra: the same role writes nothing", async () => {
    const { look, roleRows } = listedAs("administrator", ["administrator"]);
    const d = await decideSignIn({ ...social, roleSource: "entra" }, look);
    expect(d.outcome).toBe("granted");
    expect(roleRows).toEqual([]);
    expect(d.grantNote).toBeUndefined();
  });

  it("entra: someone switched off stays refused, and no role row is written", async () => {
    const { look, roleRows } = lookups({
      email: "a@org.example",
      microsoft: { objectId: OID, idToken: idToken({ tid: TENANT, roles: ["administrator"] }) },
      byIdentity: { [`${TENANT}/${OID}`]: "p1" },
      active: { p1: false },
    });
    expect((await decideSignIn({ ...social, roleSource: "entra" }, look)).outcome).toBe("refused_switched_off");
    expect(roleRows).toEqual([]);
  });

  it("entra: a token from another tenant is refused before its roles are read", async () => {
    const { look, roleRows } = lookups({
      email: "a@org.example",
      microsoft: { objectId: OID, idToken: idToken({ tid: OTHER_TENANT, roles: ["administrator"] }) },
      byIdentity: { [`${OTHER_TENANT}/${OID}`]: "p1" },
      active: { p1: true },
    });
    expect((await decideSignIn({ ...social, roleSource: "entra" }, look)).outcome).toBe("refused_wrong_tenant");
    expect(roleRows).toEqual([]);
  });
});

describe("JOIN_MODE", () => {
  const stranger = (over: Partial<World> = {}) =>
    lookups({ email: "new@org.example", microsoft: { objectId: OID, idToken: idToken({ tid: TENANT }) }, joinResult: "p7", ...over });

  it("listed: a group member not on the list is refused, and nobody is added", async () => {
    const { look, joined } = stranger();
    const d = await decideSignIn(social, look);
    expect(d.outcome).toBe("refused_not_on_the_list");
    expect(joined).toEqual([]);
    expect(d.removeAuthRows).toBe(true);
  });

  it("group: a group member not on the list is added as a member, bound by object id, and granted", async () => {
    const { look, joined, roleRows } = stranger();
    const d = await decideSignIn({ ...social, joinMode: "group" }, look);
    expect(d.outcome).toBe("granted");
    expect(d.personId).toBe("p7");
    expect(d.grantNote).toBe("joined_from_group");
    expect(joined).toEqual([{ email: "new@org.example", displayName: "A Person", tenantId: TENANT, objectId: OID }]);
    expect(roleRows).toEqual([]);
  });

  it("group: with no name on the token, the address stands in for it", async () => {
    const { look, joined } = stranger({ name: null });
    await decideSignIn({ ...social, joinMode: "group" }, look);
    expect(joined[0]?.displayName).toBe("new@org.example");
  });

  // The administrators group holds its own assignment on the app, so a member of it alone gets here too:
  // the tenant setup covers that group with the same Conditional Access policy as the sign-in group.
  it("group with entra roles: joins as a member, then the administrator app role appends its own row", async () => {
    const { look, joined, roleRows } = stranger({ microsoft: { objectId: OID, idToken: idToken({ tid: TENANT, roles: ["administrator"] }) } });
    const d = await decideSignIn({ ...social, joinMode: "group", roleSource: "entra" }, look);
    expect(d.outcome).toBe("granted");
    expect(joined).toHaveLength(1);
    expect(roleRows).toEqual([["p7", "administrator"]]);
    expect(d.grantNote).toBe("joined_from_group");
  });

  it("group: a token from another tenant never joins", async () => {
    const { look, joined } = stranger({ microsoft: { objectId: OID, idToken: idToken({ tid: OTHER_TENANT }) } });
    expect((await decideSignIn({ ...social, joinMode: "group" }, look)).outcome).toBe("refused_wrong_tenant");
    expect(joined).toEqual([]);
  });

  it("group: a token for another app never joins", async () => {
    const { look, joined } = stranger({ microsoft: { objectId: OID, idToken: idToken({ tid: TENANT, aud: "66666666-6666-6666-6666-666666666666" }) } });
    expect((await decideSignIn({ ...social, joinMode: "group" }, look)).outcome).toBe("refused_wrong_tenant");
    expect(joined).toEqual([]);
  });

  it("group: no email on the token means no join", async () => {
    const { look, joined } = stranger({ email: null });
    expect((await decideSignIn({ ...social, joinMode: "group" }, look)).outcome).toBe("refused_not_on_the_list");
    expect(joined).toEqual([]);
  });

  it("group: an address already on the list binds as before, it does not join twice", async () => {
    const { look, joined, bound } = stranger({ byEmail: { "new@org.example": { personId: "p1", boundObjectId: null } }, active: { p1: true } });
    const d = await decideSignIn({ ...social, joinMode: "group" }, look);
    expect(d.outcome).toBe("granted");
    expect(joined).toEqual([]);
    expect(bound).toEqual([["p1", TENANT, OID]]);
  });

  it("group: a join that loses the race to the same person's other sign-in is granted as that person", async () => {
    const { look } = stranger({ joinResult: null, active: { p8: true } });
    // After the lost join, the re-read finds the identity the other sign-in bound.
    const w = { lost: false };
    const racing: GateLookups = {
      ...look,
      personByIdentity: async (t, o) => (w.lost ? { personId: "p8" } : look.personByIdentity(t, o)),
      joinPerson: async () => {
        w.lost = true;
        return null;
      },
    };
    const d = await decideSignIn({ ...social, joinMode: "group" }, racing);
    expect(d.outcome).toBe("granted");
    expect(d.personId).toBe("p8");
  });

  it("group, guests not allowed: an address outside the organisation's domains is refused and nobody is added", async () => {
    // A B2B guest put into the site's group: right tenant and audience, address on their own domain.
    const { look, joined } = stranger({ email: "someone@fabrikam.example" });
    const d = await decideSignIn({ ...social, joinMode: "group" }, look);
    expect(d.outcome).toBe("refused_not_on_the_list");
    expect(d.joinRefusal).toBe("outside_org_domains");
    expect(d.removeAuthRows).toBe(true);
    expect(joined).toEqual([]);
  });

  it("group, guests not allowed: a look-alike domain is refused too", async () => {
    const { look, joined } = stranger({ email: "someone@org.example.fabrikam.example" });
    expect((await decideSignIn({ ...social, joinMode: "group" }, look)).joinRefusal).toBe("outside_org_domains");
    expect(joined).toEqual([]);
  });

  it("group, guests not allowed: an address on any of the organisation's domains joins, ignoring case", async () => {
    const { look, joined } = stranger({ email: "New@Second.Example" });
    const d = await decideSignIn({ ...social, joinMode: "group", orgEmailDomains: ["org.example", "second.example"] }, look);
    expect(d.outcome).toBe("granted");
    expect(d.joinRefusal).toBeUndefined();
    expect(joined).toHaveLength(1);
  });

  it("group, guests allowed: an address outside the organisation's domains joins", async () => {
    const { look, joined } = stranger({ email: "someone@fabrikam.example" });
    const d = await decideSignIn({ ...social, joinMode: "group", allowGuests: true }, look);
    expect(d.outcome).toBe("granted");
    expect(d.grantNote).toBe("joined_from_group");
    expect(joined).toHaveLength(1);
  });

  it("guests not allowed never refuses someone already on the list: the domain check is for joins only", async () => {
    const { look } = stranger({
      email: "listed@fabrikam.example",
      byEmail: { "listed@fabrikam.example": { personId: "p2", boundObjectId: null } },
      active: { p2: true },
    });
    expect((await decideSignIn({ ...social, joinMode: "group" }, look)).outcome).toBe("granted");
  });

  it("group: a join that loses the race to someone else is refused", async () => {
    const { look } = stranger({ joinResult: null });
    const d = await decideSignIn({ ...social, joinMode: "group" }, look);
    expect(d.outcome).toBe("refused_identity_mismatch");
    expect(d.removeAuthRows).toBe(true);
  });
});
