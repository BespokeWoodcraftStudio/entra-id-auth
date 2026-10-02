/**
 * What the add-person script accepts, without a database. The write itself,
 * and its refusal of an object id already on the list, are proven against
 * Postgres in db.integration.test.ts.
 */
import { describe, expect, it } from "vitest";

import { parseAddPersonArgs } from "../../../scripts/add-person";

const OID = "33333333-3333-3333-3333-333333333333";
const TENANT = "11111111-1111-1111-1111-111111111111";
const good = ["Alex.Jones@Contoso.example", "Alex Jones", "member", "--oid", OID, "--tenant", TENANT, "--by", "Owner@Contoso.example"];

describe("parseAddPersonArgs", () => {
  it("reads a full command line, lower-casing addresses and ids", () => {
    expect(parseAddPersonArgs(good)).toEqual({
      email: "alex.jones@contoso.example",
      name: "Alex Jones",
      role: "member",
      objectId: OID,
      tenantId: TENANT,
      by: "owner@contoso.example",
    });
    expect(parseAddPersonArgs(good.map((a) => (a === OID ? OID.toUpperCase() : a))).objectId).toBe(OID);
  });

  it.each([
    [[], /Usage/],
    [["--oid", OID], /Usage/],
    [["not-an-address", "A", "member"], /Usage/],
    [["a@contoso.example", " ", "member"], /Usage/],
    [["a@contoso.example", "A", "owner"], /Usage/],
  ])("refuses %o", (argv, message) => {
    expect(() => parseAddPersonArgs(argv)).toThrow(message);
  });

  it("needs --by, as an address", () => {
    expect(() => parseAddPersonArgs(good.slice(0, 7))).toThrow(/with --by/);
    expect(() => parseAddPersonArgs([...good.slice(0, 7), "--by", "Pat Owner"])).toThrow(/--by takes an administrator's email address/);
  });

  it("needs --oid and --tenant as GUIDs", () => {
    expect(() => parseAddPersonArgs(good.map((a) => (a === OID ? "not-a-guid" : a)))).toThrow(/required GUIDs/);
    expect(() => parseAddPersonArgs(good.filter((a) => a !== "--tenant" && a !== TENANT))).toThrow(/required GUIDs/);
  });
});
