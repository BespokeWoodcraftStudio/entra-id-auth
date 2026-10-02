/** A stranger gets {ok:true} and nothing else (control C35). */
import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("@/lib/auth/current-person", () => ({
  getCurrentPerson: vi.fn(async () => null),
  isAdministrator: (p: { role: string }) => p.role === "administrator",
}));

import { GET } from "@/app/api/health/route";
import * as current from "@/lib/auth/current-person";
import { resetAuthEnvCache } from "@/lib/auth/env";

afterEach(() => {
  vi.unstubAllEnvs();
  resetAuthEnvCache();
});

function stubBaseEnv() {
  vi.stubEnv("DATABASE_URL", "postgres://localhost/x");
  vi.stubEnv("BETTER_AUTH_SECRET", "x".repeat(40));
  vi.stubEnv("CRON_SECRET", "bearer-value");
  resetAuthEnvCache();
}

describe("GET /api/health", () => {
  it("tells a stranger only ok", async () => {
    stubBaseEnv();
    const res = await GET(new Request("https://site.example/api/health"));
    expect(await res.json()).toEqual({ ok: true });
  });
  it("tells the bearer which settings are present, never a value", async () => {
    stubBaseEnv();
    const res = await GET(new Request("https://site.example/api/health", { headers: { authorization: "Bearer bearer-value" } }));
    const body = await res.json();
    expect(body.settings.CRON_SECRET).toBe("set");
    expect(JSON.stringify(body)).not.toContain("bearer-value");
  });
  it("tells a signed-in member only ok", async () => {
    stubBaseEnv();
    vi.mocked(current.getCurrentPerson).mockResolvedValueOnce({ role: "member" } as never);
    const res = await GET(new Request("https://site.example/api/health"));
    expect(await res.json()).toEqual({ ok: true });
  });
});
