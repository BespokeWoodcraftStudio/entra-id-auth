/** Which paths pass the gate without a session, as a table (control C25). */
import { describe, expect, it } from "vitest";

import { isPublicPath } from "@/lib/auth/route-access";
import { PUBLIC_PATHS } from "@/lib/auth/settings";
import { config } from "@/proxy";

// "/" is gated unless the site put it in PUBLIC_PATHS (a public landing page).
// Either way, opening "/" opens nothing under it.
const rootIsPublic = (PUBLIC_PATHS as readonly string[]).includes("/");

const cases: Array<[string, boolean]> = [
  ["/", rootIsPublic],
  ["/anything", false],
  ["/a/route/added/later", false],
  ["/sign-in", true],
  ["/sign-in/", true],
  ["/sign-in-help", false],
  ["/sign-inx", false],
  ["/api/auth/callback/microsoft", true],
  ["/api/authx", false],
  ["/api/cron/credential-check", true],
  ["/api/cronjob", false],
  ["/api/health", true],
  ["/api/health-details", false],
  ["/api/anything-else", false],
  ["/_next/static/chunk.js", true],
  ["/favicon.ico", true],
];

describe("isPublicPath", () => {
  it.each(cases)("%s -> %s", (path, expected) => {
    expect(isPublicPath(path)).toBe(expected);
  });
});

describe("the proxy matcher", () => {
  const matcher = new RegExp(`^${config.matcher[0]}$`);
  it.each([
    ["/", true],
    ["/sign-in", true],
    ["/api/health", true],
    ["/_next/static/x.js", false],
    ["/_next/image", false],
    ["/favicon.ico", false],
    ["/_next/staticfoo", true],
  ])("%s runs the proxy: %s", (path, expected) => {
    expect(matcher.test(path)).toBe(expected);
  });
});
