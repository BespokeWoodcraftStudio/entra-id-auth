/** Where the test password lane may run, and where a test identity may be made (control C27). */
import { describe, expect, it } from "vitest";

import { passwordSignInAllowed, type AuthEnv } from "@/lib/auth/env";
import {
  isSameDatabase,
  isTestAddress,
  PREVIEW_REQUIRED_TABLES,
  previewDatabaseRefusal,
  previewSchemaRefusal,
  testIdentityTargetRefusal,
  type TestIdentityTarget,
} from "@/lib/auth/test-identity";

const env = (over: Partial<AuthEnv>) => ({ ALLOW_PASSWORD_SIGNIN: "true", NODE_ENV: "development", ...over }) as AuthEnv;

describe("passwordSignInAllowed", () => {
  it.each([
    [{ ALLOW_PASSWORD_SIGNIN: "false" }, false],
    [{ VERCEL_ENV: "production" }, false],
    [{ VERCEL_ENV: "production", NODE_ENV: "production" }, false],
    [{ VERCEL_ENV: "development" }, false],
    [{ VERCEL_ENV: undefined, NODE_ENV: "production" }, false],
    [{ VERCEL_ENV: "preview", NODE_ENV: "production" }, true],
    [{ VERCEL_ENV: undefined, NODE_ENV: "development" }, true],
    [{ VERCEL_ENV: undefined, NODE_ENV: "test" }, true],
  ] as Array<[Partial<AuthEnv>, boolean]>)("%o -> %s", (over, expected) => {
    expect(passwordSignInAllowed(env(over), false)).toBe(expected);
  });

  // A production build stays off even when a host runs it with NODE_ENV=development.
  it.each([
    [{ VERCEL_ENV: undefined, NODE_ENV: "development" }, false],
    [{ VERCEL_ENV: undefined, NODE_ENV: "test" }, false],
    [{ VERCEL_ENV: "preview", NODE_ENV: "production" }, true],
    [{ VERCEL_ENV: "production", NODE_ENV: "development" }, false],
  ] as Array<[Partial<AuthEnv>, boolean]>)("production build, %o -> %s", (over, expected) => {
    expect(passwordSignInAllowed(env(over), true)).toBe(expected);
  });
});

describe("where dev-test-user may give a test identity a password", () => {
  const local = { email: "tester@site.invalid", databaseUrl: "postgres://localhost:5432/site", preview: false, onVercel: false, laneOnHere: true };
  const remote = "postgres://user:pw@ep-example-123.us-east-2.aws.neon.example/site?sslmode=require";

  it("this machine: allowed with a .invalid address, a local database and the lane on", () => {
    expect(testIdentityTargetRefusal(local)).toBeNull();
    expect(testIdentityTargetRefusal({ ...local, databaseUrl: "postgres://127.0.0.1:55432/site" })).toBeNull();
    expect(testIdentityTargetRefusal({ ...local, databaseUrl: "postgres://[::1]/site" })).toBeNull();
  });

  it.each([
    [{ email: "real.person@contoso.example" }, /must end in .invalid/],
    [{ email: "invalid" }, /must end in .invalid/],
    [{ onVercel: true }, /on Vercel/],
    [{ databaseUrl: undefined }, /DATABASE_URL is not set/],
    [{ databaseUrl: remote }, /only a database on this machine/],
    [{ databaseUrl: "postgres://localhost/site?host=db.example" }, /only a database on this machine/],
    [{ databaseUrl: "not a url" }, /only a database on this machine/],
    [{ laneOnHere: false }, /ALLOW_PASSWORD_SIGNIN is not true here/],
  ] as Array<[Partial<TestIdentityTarget>, RegExp]>)("this machine: refuses %o", (over, message) => {
    expect(testIdentityTargetRefusal({ ...local, ...over })).toMatch(message);
  });

  it("--preview: allowed against a remote database, whatever the lane says here", () => {
    expect(testIdentityTargetRefusal({ ...local, preview: true, databaseUrl: remote, laneOnHere: false })).toBeNull();
  });

  it.each([
    [{ email: "real.person@contoso.example" }, /must end in .invalid/],
    [{ onVercel: true }, /on Vercel/],
    [{ databaseUrl: undefined }, /DATABASE_URL is not set/],
    [{ databaseUrl: "postgres://localhost:5432/site" }, /this one is on this machine/],
  ] as Array<[Partial<TestIdentityTarget>, RegExp]>)("--preview: refuses %o", (over, message) => {
    expect(testIdentityTargetRefusal({ ...local, preview: true, databaseUrl: remote, ...over })).toMatch(message);
  });

  it("--preview: refuses production's database even before it holds anyone", () => {
    const prod = "postgres://owner:secret@ep-prod-111.us-east-2.aws.neon.example/site?sslmode=require";
    const pooled = "postgres://owner:other@ep-prod-111-pooler.us-east-2.aws.neon.example/site?sslmode=require&channel_binding=require";
    const previewDb = "postgres://owner:secret@ep-prod-111.us-east-2.aws.neon.example/site_preview?sslmode=require";
    const target = { ...local, preview: true, laneOnHere: false };
    expect(testIdentityTargetRefusal({ ...target, databaseUrl: prod, productionDatabaseUrls: [prod] })).toMatch(/production's database/);
    expect(testIdentityTargetRefusal({ ...target, databaseUrl: pooled, productionDatabaseUrls: [` ${prod}\n`] })).toMatch(/production's database/);
    expect(testIdentityTargetRefusal({ ...target, databaseUrl: previewDb, productionDatabaseUrls: [prod] })).toBeNull();
    expect(testIdentityTargetRefusal({ ...target, databaseUrl: remote, productionDatabaseUrls: ["", "not a url"] })).toBeNull();
    // The message names the file, never the URL.
    expect(testIdentityTargetRefusal({ ...target, databaseUrl: prod, productionDatabaseUrls: [prod] })).not.toMatch(/secret|neon/);
  });

  it("the same database: host with or without Neon's -pooler, port and name", () => {
    expect(isSameDatabase("postgres://a:b@db.example/x", "postgres://c:d@db.example:5432/x")).toBe(true);
    expect(isSameDatabase("postgres://a:b@db.example/x", "postgres://a:b@db.example/y")).toBe(false);
    expect(isSameDatabase("postgres://a:b@db.example:6543/x", "postgres://a:b@db.example/x")).toBe(false);
    expect(isSameDatabase("postgres://a:b@db-other.example/x", "postgres://a:b@db.example/x")).toBe(false);
    expect(isSameDatabase("not a url", "not a url")).toBe(true);
    expect(isSameDatabase("not a url", "postgres://a:b@db.example/x")).toBe(false);
  });

  it("--preview: an unmigrated database gets the migrate line, not Postgres's raw error", () => {
    expect(previewSchemaRefusal([])).toBeNull();
    const message = previewSchemaRefusal(["people", "session"]);
    expect(message).toMatch(/has not been migrated \(missing: people, session\)/);
    expect(message).toContain('DATABASE_URL="$(cat ~/.config/<slug>/database-url-preview)" npx drizzle-kit migrate');
    expect(PREVIEW_REQUIRED_TABLES).toEqual(expect.arrayContaining(["people", "person_identities", "account", "session"]));
  });

  it("--preview: only a database that holds test identities only", () => {
    expect(previewDatabaseRefusal({ realPeople: 0, microsoftAccounts: 0, boundIdentities: 0 })).toBeNull();
    // Production's database, or a branch copied from it, always holds at least its first administrator.
    expect(previewDatabaseRefusal({ realPeople: 1, microsoftAccounts: 0, boundIdentities: 0 })).toMatch(/production's, or a copy of it/);
    expect(previewDatabaseRefusal({ realPeople: 0, microsoftAccounts: 1, boundIdentities: 0 })).toMatch(/holds real people/);
    expect(previewDatabaseRefusal({ realPeople: 0, microsoftAccounts: 0, boundIdentities: 1 })).toMatch(/holds real people/);
  });

  it("a test address is .invalid and nothing else", () => {
    expect(isTestAddress("Tester@Site.INVALID")).toBe(true);
    expect(isTestAddress("tester@site.invalid.example")).toBe(false);
    expect(isTestAddress(".invalid")).toBe(false);
  });
});
