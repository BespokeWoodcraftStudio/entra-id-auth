/** The open-redirect guard (control C22). */
import { describe, expect, it } from "vitest";

import { safeNextPath } from "@/app/sign-in/safe-next-path";

describe("safeNextPath", () => {
  it.each(["/", "/reports", "/reports/7?tab=a", "/a/b#c"])("keeps %s", (p) => expect(safeNextPath(p)).toBe(p));
  it.each([
    undefined,
    "",
    "reports",
    "//evil.example",
    "/\\evil.example",
    "/%5Cevil.example",
    "/%2F%2Fevil.example",
    "https://evil.example",
    "/\u0000x",
    "/\tx",
  ])("refuses %s", (p) => expect(safeNextPath(p)).toBeUndefined());
  // Next 16 passes a repeated ?next= as an array; a crafted link must not throw.
  it.each([[["/reports", "//evil.example"]], [["/reports"]], [[]], [7], [null], [{ startsWith: () => true }]])(
    "refuses a value that is not one string: %j",
    (p) => {
      expect(() => safeNextPath(p)).not.toThrow();
      expect(safeNextPath(p)).toBeUndefined();
    },
  );
});
