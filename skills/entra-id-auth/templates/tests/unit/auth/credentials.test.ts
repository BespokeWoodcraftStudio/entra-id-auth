/** The renewal warning (control M11). */
import { afterEach, describe, expect, it, vi } from "vitest";

import { credentialWarning } from "@/lib/auth/credentials";
import { resetAuthEnvCache } from "@/lib/auth/env";

function withEnv(expires: string | undefined) {
  vi.stubEnv("DATABASE_URL", "postgres://localhost/x");
  vi.stubEnv("BETTER_AUTH_SECRET", "x".repeat(40));
  vi.stubEnv("MICROSOFT_ENTRA_TENANT_ID", "11111111-1111-1111-1111-111111111111");
  vi.stubEnv("MICROSOFT_ENTRA_CLIENT_ID", "22222222-2222-2222-2222-222222222222");
  vi.stubEnv("MICROSOFT_ENTRA_CLIENT_SECRET", "not-a-real-secret");
  vi.stubEnv("MICROSOFT_ENTRA_CLIENT_SECRET_EXPIRES", expires ?? "");
  resetAuthEnvCache();
}

afterEach(() => {
  vi.unstubAllEnvs();
  resetAuthEnvCache();
});

describe("credentialWarning", () => {
  const now = new Date("2027-01-01T00:00:00Z");
  it("is quiet more than 30 days out", () => {
    withEnv("2027-06-01T00:00:00Z");
    expect(credentialWarning(now)).toBeNull();
  });
  it("warns within 30 days", () => {
    withEnv("2027-01-20T00:00:00Z");
    expect(credentialWarning(now)).toContain("in 19 days");
  });
  it("warns when the date was never recorded", () => {
    withEnv(undefined);
    expect(credentialWarning(now)).toContain("not recorded");
  });
});
