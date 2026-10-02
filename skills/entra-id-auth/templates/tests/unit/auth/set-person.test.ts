/**
 * What the set-person script writes, without a database. The last-administrator
 * refusal (control C9) is proven against Postgres in db.integration.test.ts.
 */
import { describe, expect, it } from "vitest";

import { nextAssignment } from "../../../scripts/set-person";

describe("nextAssignment", () => {
  const member = { role: "member", active: true } as const;
  const admin = { role: "administrator", active: true } as const;

  it("changes the role, keeping on or off", () => {
    expect(nextAssignment(member, { role: "administrator" }, "site")).toEqual({ role: "administrator", active: true });
    expect(nextAssignment({ ...admin, active: false }, { role: "member" }, "site")).toEqual({ role: "member", active: false });
  });

  it("switches off and on, keeping the role", () => {
    expect(nextAssignment(admin, { active: false }, "site")).toEqual({ role: "administrator", active: false });
    expect(nextAssignment({ ...member, active: false }, { active: true }, "entra")).toEqual({ role: "member", active: true });
  });

  it("refuses when nothing was asked", () => {
    expect(() => nextAssignment(member, {}, "site")).toThrow(/say what to change/);
  });

  it("with roles from Entra, refuses a role change but not a switch-off", () => {
    expect(() => nextAssignment(member, { role: "administrator" }, "entra")).toThrow(/Entra app role/);
    expect(nextAssignment(member, { role: "member", active: false }, "entra")).toEqual({ role: "member", active: false });
  });
});
