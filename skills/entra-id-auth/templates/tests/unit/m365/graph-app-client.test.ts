/**
 * The Microsoft 365 reader's own checks (control M10, M13): only allowed
 * mailboxes, even for a path a new caller builds, and $top a whole number
 * from 1 to 50. Nothing here calls Microsoft. Skipped on a site that has no
 * reader (the setup copies graph-app-client.ts only when the person said yes).
 */
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const file = fileURLToPath(new URL("../../../__SRC_ROOT__/lib/m365/graph-app-client.ts", import.meta.url));

describe.skipIf(!existsSync(file))("the Microsoft 365 reader", () => {
  // Typed by hand: a type import of a file the site may not have would stop its type check.
  interface Client {
    mailboxInPath(path: string): string | null;
    graphGet<T>(path: string): Promise<T>;
    graphUrl(path: string): URL;
    latestMessages(mailbox: string, top?: unknown): Promise<unknown>;
    clampTop(top: unknown): number;
  }
  let client: Client;
  const saved = { ...process.env };

  beforeEach(async () => {
    vi.resetModules();
    process.env.DATABASE_URL = "postgres://localhost:5432/site";
    process.env.BETTER_AUTH_SECRET = "t".repeat(48);
    process.env.M365_READER_MAILBOXES = "Shared@Contoso.example, other@contoso.example";
    (await import("@/lib/auth/env")).resetAuthEnvCache();
    client = (await import(/* @vite-ignore */ file)) as Client;
  });

  afterEach(() => {
    process.env = { ...saved };
    vi.unstubAllGlobals();
  });

  it("reads the mailbox a /users/ path names; other paths name none", () => {
    expect(client.mailboxInPath("/users/Shared%40Contoso.example/messages?$top=1")).toBe("shared@contoso.example");
    expect(client.mailboxInPath("/users/shared@contoso.example")).toBe("shared@contoso.example");
    expect(client.mailboxInPath("/organization")).toBeNull();
  });

  it("graphGet refuses a mailbox that is not allowed before any token is asked for", async () => {
    const fetch = vi.fn();
    vi.stubGlobal("fetch", fetch);
    await expect(client.graphGet("/users/ceo%40contoso.example/messages")).rejects.toThrow(/not one this site may read/);
    await expect(client.latestMessages("ceo@contoso.example")).rejects.toThrow(/not one this site may read/);
    expect(fetch).not.toHaveBeenCalled();
  });

  it.each([
    // fetch resolves these to another mailbox after a check on the first segment would have passed.
    ["/users/shared@contoso.example/messages/../../ceo@contoso.example/messages", /dot segments/],
    ["/users/shared@contoso.example/messages/%2e%2e/%2E%2E/ceo@contoso.example/messages", /dot segments/],
    ["/users/shared@contoso.example/messages/.%2e/.%2e/ceo@contoso.example", /dot segments/],
    ["/users/shared@contoso.example/./messages", /dot segments/],
    ["/users/shared@contoso.example%2f..%2fceo@contoso.example/messages", /dot segments/],
    ["/users/shared@contoso.example\\..\\..\\ceo@contoso.example", /dot segments/],
    ["/users//ceo@contoso.example/messages", /empty segments/],
    // An OData key names a mailbox without a /users/ segment.
    ["/users('ceo@contoso.example')/messages", /OData key/],
    ["/Users%28'ceo@contoso.example'%29/messages", /OData key/],
    ["/users/('ceo@contoso.example')/messages", /not one this site may read/],
    ["/users/ceo@contoso.example/messages?$filter=from/address eq 'shared@contoso.example'", /not one this site may read/],
  ])("graphGet refuses %s before any token is asked for", async (path, message) => {
    const fetch = vi.fn();
    vi.stubGlobal("fetch", fetch);
    await expect(client.graphGet(path)).rejects.toThrow(message);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("graphUrl keeps an allowed mailbox, and dots inside a query value, as they are", () => {
    const url = client.graphUrl("/users/Shared%40Contoso.example/messages?$search=\"a..b\"&$top=5");
    expect(url.origin).toBe("https://graph.microsoft.com");
    expect(url.pathname).toBe("/v1.0/users/Shared%40Contoso.example/messages");
    expect(client.graphUrl("/organization").pathname).toBe("/v1.0/organization");
    expect(client.graphUrl("/users/other@contoso.example/mailFolders/inbox/messages").pathname).toBe(
      "/v1.0/users/other@contoso.example/mailFolders/inbox/messages",
    );
  });

  it("graphGet refuses a path that does not start with /", async () => {
    await expect(client.graphGet("users/shared@contoso.example")).rejects.toThrow(/starts with \//);
  });

  it.each([
    [10, 10],
    [1, 1],
    [50, 50],
    [0, 1],
    [-5, 1],
    [500, 50],
    [7.9, 7],
    ["12", 12],
    ["5&$select=body", 10],
    [undefined, 10],
  ])("clampTop(%o) is %o", (top, expected) => {
    expect(client.clampTop(top)).toBe(expected);
  });
});
