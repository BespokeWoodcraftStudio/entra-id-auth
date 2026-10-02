/** The headers every response carries, and the CSP (control C29, C31, C32). */
import { describe, expect, it } from "vitest";

import { buildCsp, newNonce, STATIC_SECURITY_HEADERS } from "@/lib/auth/security-headers";
import nextConfig from "../../../next.config";

describe("static headers", () => {
  const map = Object.fromEntries(STATIC_SECURITY_HEADERS.map((h) => [h.key, h.value]));
  it("deny framing, sniffing and a loose referrer", () => {
    expect(map["X-Frame-Options"]).toBe("DENY");
    expect(map["X-Content-Type-Options"]).toBe("nosniff");
    expect(map["Referrer-Policy"]).toBe("strict-origin-when-cross-origin");
    expect(map["Permissions-Policy"]).toContain("camera=()");
  });
  it("are applied to every path by next.config, with X-Powered-By off", async () => {
    // A failure here usually means next.config still needs the MERGE from ~/.config/<slug>/merge/next.config.ts.
    expect(nextConfig.poweredByHeader, "next.config is not merged yet: merge it from the filled copy").toBe(false);
    const rules = await nextConfig.headers!();
    const all = rules.find((r) => r.source === "/(.*)");
    expect(all?.headers).toEqual(expect.arrayContaining([...STATIC_SECURITY_HEADERS]));
  });
});

describe("buildCsp", () => {
  const prod = buildCsp({ nonce: "abc", development: false, preview: false });
  it("is strict in production", () => {
    expect(prod).toContain("default-src 'self'");
    expect(prod).toContain("script-src 'self' 'nonce-abc' 'strict-dynamic'");
    expect(prod).not.toContain("unsafe-eval");
    expect(prod).toContain("object-src 'none'");
    expect(prod).toContain("base-uri 'none'");
    expect(prod).toContain("frame-ancestors 'none'");
    expect(prod).toContain("form-action 'self' https://login.microsoftonline.com");
    expect(prod).not.toContain("vercel.live");
  });
  it("allows eval only in development and the Vercel toolbar only on previews", () => {
    expect(buildCsp({ nonce: "n", development: true, preview: false })).toContain("'unsafe-eval'");
    expect(buildCsp({ nonce: "n", development: false, preview: true })).toContain("https://vercel.live");
  });
  it("makes a new nonce each time", () => {
    expect(newNonce()).not.toBe(newNonce());
  });
});
