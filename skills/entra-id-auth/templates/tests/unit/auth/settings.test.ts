/**
 * The settings the setup fills in: numbers in range, choices from their list,
 * one or more email domains, and a bad value refused at import (control C16,
 * C17), so a site with a wrong setting never starts.
 */
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import * as settings from "@/lib/auth/settings";
import { emailOnDomains, parseChoice, parseEmailDomains, parseWholeNumber } from "@/lib/auth/settings";

/** An unfilled placeholder, built so the harness fill never replaces it in this file. */
const unfilled = (name: string) => `__${name}__`;

describe("parseWholeNumber", () => {
  it.each([
    ["60", 60],
    [" 15 ", 15],
    ["480", 480],
  ])("accepts %o", (raw, value) => {
    expect(parseWholeNumber("SESSION_IDLE_MINUTES", raw, 15, 480)).toBe(value);
  });

  it.each(["14", "481", "0", "-1", "12.5", "1e2", "", " ", "sixty", "0x3c", unfilled("SESSION_IDLE_MINUTES")])("refuses %o, naming the setting and the range", (raw) => {
    expect(() => parseWholeNumber("SESSION_IDLE_MINUTES", raw, 15, 480)).toThrow(/SESSION_IDLE_MINUTES must be a whole number from 15 to 480/);
  });

  it.each([
    ["1", 1],
    ["12", 12],
    ["24", 24],
  ])("hours: accepts %o", (raw, value) => {
    expect(parseWholeNumber("SESSION_MAX_HOURS", raw, 1, 24)).toBe(value);
  });

  it.each(["0", "25", "48", unfilled("SESSION_MAX_HOURS")])("hours: refuses %o", (raw) => {
    expect(() => parseWholeNumber("SESSION_MAX_HOURS", raw, 1, 24)).toThrow(/SESSION_MAX_HOURS must be a whole number from 1 to 24/);
  });
});

describe("parseChoice", () => {
  it("accepts each listed choice", () => {
    expect(parseChoice("ROLE_SOURCE", "site", ["site", "entra"])).toBe("site");
    expect(parseChoice("ROLE_SOURCE", " entra ", ["site", "entra"])).toBe("entra");
    expect(parseChoice("JOIN_MODE", "listed", ["listed", "group"])).toBe("listed");
    expect(parseChoice("JOIN_MODE", "group", ["listed", "group"])).toBe("group");
  });

  it.each(["", "Site", "ENTRA", "both", unfilled("ROLE_SOURCE")])("refuses %o", (raw) => {
    expect(() => parseChoice("ROLE_SOURCE", raw, ["site", "entra"])).toThrow(/ROLE_SOURCE must be one of site, entra/);
  });
});

describe("email domains", () => {
  it("one domain", () => {
    expect(parseEmailDomains("org.example")).toEqual(["org.example"]);
  });

  it("several, trimmed, lower-cased, duplicates dropped", () => {
    expect(parseEmailDomains(" Org.Example ,second.example,org.example,")).toEqual(["org.example", "second.example"]);
  });

  it.each(["", ",", "not a domain", "@org.example", "org", "https://org.example", "*.org.example", unfilled("EMAIL_DOMAINS")])("refuses %o", (raw) => {
    expect(() => parseEmailDomains(raw)).toThrow(/EMAIL_DOMAINS/);
  });

  it("an address on any listed domain is accepted, ignoring case; nothing else is", () => {
    const domains = parseEmailDomains("org.example,second.example");
    expect(emailOnDomains("a@org.example", domains)).toBe(true);
    expect(emailOnDomains("B@Second.Example", domains)).toBe(true);
    expect(emailOnDomains("a@sub.org.example", domains)).toBe(false);
    expect(emailOnDomains("a@org.example.evil.example", domains)).toBe(false);
    expect(emailOnDomains("a@elsewhere.example", domains)).toBe(false);
    expect(emailOnDomains("org.example", domains)).toBe(false);
    expect(emailOnDomains("@org.example", domains)).toBe(false);
  });
});

describe("the filled settings module", () => {
  it("holds values in range, and nothing left unfilled", () => {
    expect(settings.SITE_NAME).not.toMatch(/__/);
    expect(settings.ORG_EMAIL_DOMAINS.length).toBeGreaterThan(0);
    expect(settings.SESSION_IDLE_MINUTES).toBeGreaterThanOrEqual(15);
    expect(settings.SESSION_IDLE_MINUTES).toBeLessThanOrEqual(480);
    expect(settings.SESSION_MAX_HOURS).toBeGreaterThanOrEqual(1);
    expect(settings.SESSION_MAX_HOURS).toBeLessThanOrEqual(24);
    expect(settings.SESSION_IDLE_SECONDS).toBe(settings.SESSION_IDLE_MINUTES * 60);
    expect(settings.SESSION_MAX_AGE_SECONDS).toBe(settings.SESSION_MAX_HOURS * 3600);
    expect(settings.SESSION_IDLE_SECONDS).toBeLessThan(settings.SESSION_MAX_AGE_SECONDS);
    expect(["site", "entra"]).toContain(settings.ROLE_SOURCE);
    expect(["listed", "group"]).toContain(settings.JOIN_MODE);
    expect(["yes", "no"]).toContain(settings.ALLOW_GUESTS);
  });
});

describe("a bad value refuses at import", () => {
  const source = readFileSync(fileURLToPath(new URL("../../../__SRC_ROOT__/lib/auth/settings.ts", import.meta.url)), "utf8");

  /** Imports a copy of settings.ts with filled values swapped. */
  async function importWith(swaps: Record<string, string>): Promise<unknown> {
    let text = source;
    for (const [setting, value] of Object.entries(swaps)) {
      const pattern = new RegExp(`("${setting}", )"[^"]*"`);
      expect(text).toMatch(pattern);
      text = text.replace(pattern, `$1"${value}"`);
    }
    const dir = mkdtempSync(join(tmpdir(), "settings-"));
    const file = join(dir, "settings.ts");
    try {
      writeFileSync(file, text);
      return await import(/* @vite-ignore */ file);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  it("the copy imports cleanly with good values", async () => {
    const m = (await importWith({ SESSION_IDLE_MINUTES: "30", SESSION_MAX_HOURS: "8" })) as typeof settings;
    expect(m.SESSION_MAX_AGE_SECONDS).toBe(8 * 3600);
  });

  it.each([
    [{ SESSION_MAX_HOURS: "25" }, /SESSION_MAX_HOURS must be a whole number from 1 to 24/],
    [{ SESSION_MAX_HOURS: "0" }, /SESSION_MAX_HOURS must be a whole number/],
    [{ SESSION_IDLE_MINUTES: "5" }, /SESSION_IDLE_MINUTES must be a whole number from 15 to 480/],
    [{ ROLE_SOURCE: "both" }, /ROLE_SOURCE must be one of site, entra/],
    [{ JOIN_MODE: "anyone" }, /JOIN_MODE must be one of listed, group/],
    [{ ALLOW_GUESTS: "maybe" }, /ALLOW_GUESTS must be one of yes, no/],
    [{ SESSION_IDLE_MINUTES: "60", SESSION_MAX_HOURS: "1" }, /SESSION_IDLE_MINUTES \(60\) must be shorter than SESSION_MAX_HOURS/],
  ] as Array<[Record<string, string>, RegExp]>)("%o", async (swaps, message) => {
    await expect(importWith(swaps)).rejects.toThrow(message);
  });
});
