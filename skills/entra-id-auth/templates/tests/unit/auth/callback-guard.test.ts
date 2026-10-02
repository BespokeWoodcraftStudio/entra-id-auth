/** The server-side open-redirect guard on every sign-in start (control C22). */
import { describe, expect, it } from "vitest";

import { unsafeRedirectTarget } from "@/lib/auth/callback-guard";

describe("unsafeRedirectTarget", () => {
  it.each([
    [{}],
    [{ callbackURL: "/" }],
    [{ callbackURL: "/reports/7?tab=a", errorCallbackURL: "/sign-in" }],
    [null],
  ])("accepts %o", (body) => expect(unsafeRedirectTarget(body)).toBeNull());

  it.each([
    [{ callbackURL: "https://evil.example/" }, "callbackURL"],
    [{ callbackURL: "/\\evil.example" }, "callbackURL"],
    [{ callbackURL: "//evil.example" }, "callbackURL"],
    [{ callbackURL: "/%5Cevil.example" }, "callbackURL"],
    [{ callbackURL: "/", errorCallbackURL: "https://evil.example" }, "errorCallbackURL"],
    [{ newUserCallbackURL: "javascript:alert(1)" }, "newUserCallbackURL"],
    [{ callbackURL: 42 }, "callbackURL"],
  ])("refuses %o", (body, field) => expect(unsafeRedirectTarget(body)).toBe(field));
});
