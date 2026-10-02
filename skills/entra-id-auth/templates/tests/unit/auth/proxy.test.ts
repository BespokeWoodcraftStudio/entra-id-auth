/**
 * The proxy reads the person before anything renders (control C26): a
 * made-up session cookie, with or without Next's RSC headers, gets a redirect
 * with no page in it, and only a person current-person.ts accepts gets through.
 */
import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("@/lib/auth/current-person", () => ({
  personFromHeaders: vi.fn(async () => null),
}));

import { NextRequest } from "next/server";

import * as current from "@/lib/auth/current-person";
import { proxy } from "@/proxy";

const MADE_UP = "better-auth.session_token=made-up.value";
const MADE_UP_SECURE = "__Secure-better-auth.session_token=made-up.value";

// Next's own header for "the (app) layout is already on screen". The page
// segment's name is built in two parts so it never reads as a template placeholder.
const PAGE_SEGMENT = "__PAGE" + "__";
const TREE = encodeURIComponent(JSON.stringify(["", { children: ["(app)", { children: ["other", { children: [PAGE_SEGMENT, {}] }] }] }, null, null, true]));

function request(path: string, headers: Record<string, string> = {}): NextRequest {
  return new NextRequest(new URL(path, "https://site.example"), { headers });
}

afterEach(() => vi.mocked(current.personFromHeaders).mockClear());

describe("proxy", () => {
  it.each([
    ["a plain request", { cookie: MADE_UP }],
    ["the secure cookie name", { cookie: MADE_UP_SECURE }],
    ["an RSC request with a crafted router tree", { cookie: MADE_UP, RSC: "1", "Next-Router-State-Tree": TREE }],
    ["a prefetch", { cookie: MADE_UP, RSC: "1", "Next-Router-Prefetch": "1" }],
  ])("sends a made-up cookie to /sign-in with an empty body: %s", async (_name, headers) => {
    const res = await proxy(request("/secret?x=1", headers));
    expect(res.status).toBe(307);
    expect(res.headers.get("location")).toBe("https://site.example/sign-in?next=%2Fsecret%3Fx%3D1");
    expect(res.headers.get("x-middleware-next")).toBeNull();
    expect(await res.text()).toBe("");
    expect(current.personFromHeaders).toHaveBeenCalledTimes(1);
  });

  it("answers an API call with a made-up cookie with a plain 401", async () => {
    const res = await proxy(request("/api/things", { cookie: MADE_UP }));
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "not_signed_in" });
  });

  it("refuses no cookie without reading the database", async () => {
    const res = await proxy(request("/secret"));
    expect(res.status).toBe(307);
    expect(current.personFromHeaders).not.toHaveBeenCalled();
  });

  it("never reads the person on a public path", async () => {
    for (const path of ["/sign-in", "/api/auth/get-session", "/api/health"]) {
      const res = await proxy(request(path, { cookie: MADE_UP }));
      expect(res.headers.get("x-middleware-next")).toBe("1");
    }
    expect(current.personFromHeaders).not.toHaveBeenCalled();
  });

  it("lets a person current-person.ts accepts through, with a CSP", async () => {
    vi.mocked(current.personFromHeaders).mockResolvedValueOnce({ personId: "p1", role: "member" } as never);
    const res = await proxy(request("/secret", { cookie: MADE_UP }));
    expect(res.headers.get("x-middleware-next")).toBe("1");
    expect(res.headers.get("content-security-policy")).toContain("nonce-");
    const passed = vi.mocked(current.personFromHeaders).mock.calls[0][0];
    expect(passed.get("cookie")).toBe(MADE_UP);
  });
});
