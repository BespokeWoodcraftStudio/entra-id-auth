/**
 * The off-Vercel production checks read the build flag, not only the runtime
 * NODE_ENV: a production build started with NODE_ENV set to
 * development still needs https, the Microsoft values and CRON_SECRET.
 */
import { afterEach, describe, expect, it, vi } from "vitest";

const settings = {
  DATABASE_URL: "postgres://localhost/unused",
  BETTER_AUTH_SECRET: "t".repeat(48),
  BETTER_AUTH_URL: "http://site.example",
  VERCEL_ENV: "",
  NEXT_PHASE: "",
  MICROSOFT_ENTRA_TENANT_ID: "",
  MICROSOFT_ENTRA_CLIENT_ID: "",
  MICROSOFT_ENTRA_CLIENT_SECRET: "",
  CRON_SECRET: "",
};

/** Loads env.ts as a build of the given mode would, then runs with NODE_ENV=development. */
async function envModule(builtAs: "production" | "development") {
  vi.resetModules();
  for (const [k, v] of Object.entries(settings)) vi.stubEnv(k, v);
  vi.stubEnv("NODE_ENV", builtAs);
  const mod = await import("@/lib/auth/env");
  vi.stubEnv("NODE_ENV", "development");
  mod.resetAuthEnvCache();
  return mod;
}

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe("authEnv off Vercel", () => {
  it("a production build run with NODE_ENV=development is still checked as production", async () => {
    const { authEnv } = await envModule("production");
    expect(() => authEnv()).toThrow(/A production server needs .*BETTER_AUTH_URL as https.*CRON_SECRET/);
  });

  it("the checks are skipped while next build collects pages", async () => {
    const { authEnv } = await envModule("production");
    vi.stubEnv("NEXT_PHASE", "phase-production-build");
    expect(() => authEnv()).not.toThrow();
  });

  it("a development build with the same settings starts", async () => {
    const { authEnv } = await envModule("development");
    expect(() => authEnv()).not.toThrow();
  });
});
