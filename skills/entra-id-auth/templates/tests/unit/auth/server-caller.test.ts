/** The bearer check for cron and health (control C34). */
import { afterEach, describe, expect, it, vi } from "vitest";

import { isAuthorizedServerCall } from "@/lib/auth/server-caller";

afterEach(() => vi.unstubAllEnvs());

describe("isAuthorizedServerCall", () => {
  it("accepts the right bearer and nothing else", () => {
    vi.stubEnv("CRON_SECRET", "s3cret-value");
    expect(isAuthorizedServerCall("Bearer s3cret-value")).toBe(true);
    expect(isAuthorizedServerCall("Bearer s3cret-valuX")).toBe(false);
    expect(isAuthorizedServerCall("s3cret-value")).toBe(false);
    expect(isAuthorizedServerCall(null)).toBe(false);
  });
  it("with no secret: allowed only on a local copy", () => {
    vi.stubEnv("CRON_SECRET", "");
    vi.stubEnv("VERCEL_ENV", "preview");
    expect(isAuthorizedServerCall(null)).toBe(false);
    vi.stubEnv("VERCEL_ENV", "production");
    expect(isAuthorizedServerCall(null)).toBe(false);
  });
});
