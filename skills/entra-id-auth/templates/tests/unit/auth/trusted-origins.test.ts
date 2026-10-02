/** Which origins may start a sign-in, as a table (control C20). */
import { describe, expect, it } from "vitest";

import type { AuthEnv } from "@/lib/auth/env";
import { trustedOriginsFor } from "@/lib/auth/trusted-origins";

const base = { ALLOW_PASSWORD_SIGNIN: "false", NODE_ENV: "production", DATABASE_URL: "x", BETTER_AUTH_SECRET: "x".repeat(32) } as AuthEnv;

describe("trustedOriginsFor", () => {
  it("production: exactly the site and the listed origins, never a localhost", () => {
    const env = { ...base, VERCEL_ENV: "production", AUTH_TRUSTED_ORIGINS: "https://site.example, https://site.vercel.app, not-an-origin, https://x.example/path" } as AuthEnv;
    expect(trustedOriginsFor(env, "http://localhost:3000", "https://site.example").sort()).toEqual(["https://site.example", "https://site.vercel.app"]);
  });

  it("production: https host or host:port only; http, wildcards, paths and junk are dropped", () => {
    const listed = [
      "https://ok.example",
      "https://ok.example:8443",
      "https://sub.ok-site.example",
      "http://plain.example",
      "https://*.vercel.app",
      "*",
      "https://*",
      "https://ok.example/",
      "https://user@ok.example",
      "https://ok.example:99999x",
      "https://bad_host.example",
      "javascript://ok.example",
    ].join(",");
    const env = { ...base, VERCEL_ENV: "production", AUTH_TRUSTED_ORIGINS: listed } as AuthEnv;
    expect(trustedOriginsFor(env, null, "https://site.example").sort()).toEqual([
      "https://ok.example",
      "https://ok.example:8443",
      "https://site.example",
      "https://sub.ok-site.example",
    ]);
  });

  it("a production build run off Vercel with NODE_ENV=development also drops a listed http origin", () => {
    const env = { ...base, VERCEL_ENV: undefined, NODE_ENV: "development", AUTH_TRUSTED_ORIGINS: "http://plain.example,https://ok.example" } as AuthEnv;
    expect(trustedOriginsFor(env, null, "https://site.example", true).sort()).toEqual(["https://ok.example", "https://site.example"]);
  });

  it("outside production a listed http origin is kept, a wildcard never", () => {
    const env = { ...base, VERCEL_ENV: undefined, NODE_ENV: "development", AUTH_TRUSTED_ORIGINS: "http://lan-box:3000,https://*.example,*" } as AuthEnv;
    expect(trustedOriginsFor(env, null, "http://localhost:3000", false).sort()).toEqual(["http://lan-box:3000", "http://localhost:3000"]);
  });

  it("a production build off Vercel is treated as production", () => {
    const env = { ...base, VERCEL_ENV: undefined, NODE_ENV: "production" } as AuthEnv;
    expect(trustedOriginsFor(env, "http://localhost:4000", "https://site.example")).toEqual(["https://site.example"]);
  });

  it("a preview trusts its own branch address, not localhost", () => {
    const env = { ...base, VERCEL_ENV: "preview", VERCEL_BRANCH_URL: "site-git-x.vercel.app", VERCEL_URL: "site-abc.vercel.app" } as AuthEnv;
    const out = trustedOriginsFor(env, "http://localhost:3000", "https://site-git-x.vercel.app");
    expect(out).toContain("https://site-git-x.vercel.app");
    expect(out).toContain("https://site-abc.vercel.app");
    expect(out).not.toContain("http://localhost:3000");
  });

  it("a production build run with NODE_ENV=development still trusts no localhost", () => {
    const env = { ...base, VERCEL_ENV: undefined, NODE_ENV: "development" } as AuthEnv;
    expect(trustedOriginsFor(env, "http://localhost:4000", "https://site.example", true)).toEqual(["https://site.example"]);
  });

  it("a local copy trusts its own localhost origin on any port, and nothing foreign", () => {
    const env = { ...base, VERCEL_ENV: undefined, NODE_ENV: "development" } as AuthEnv;
    expect(trustedOriginsFor(env, "http://localhost:3217", "http://localhost:3000")).toContain("http://localhost:3217");
    expect(trustedOriginsFor(env, "https://evil.example", "http://localhost:3000")).not.toContain("https://evil.example");
    expect(trustedOriginsFor(env, "http://localhost.evil.example", "http://localhost:3000")).not.toContain("http://localhost.evil.example");
  });
});
