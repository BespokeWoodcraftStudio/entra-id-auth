/**
 * Only for a site that reads Microsoft 365 on the server (for example one
 * mailbox). Copy it only when the person said yes to that.
 *
 * App-only access with its OWN registration and a certificate, never the
 * sign-in app or its secret (control M12). The app holds no Graph application
 * permission; Exchange RBAC for Applications is what lets it read, and only
 * the named mailboxes (control M10, M13). Asking for any other mailbox gets 403.
 *
 * Needs: npm i @azure/identity
 *
 * A new caller: go through graphGet, which checks the URL fetch will send
 * (after "." and ".." are resolved) and refuses a /users/<mailbox> path whose
 * mailbox is not in M365_READER_MAILBOXES, a dot segment, an encoded slash or
 * dot, and an OData key such as /users('<mailbox>'). Encode any request value
 * that goes into a path with encodeURIComponent, and keep every number that
 * reaches a query string a whole number (see latestMessages). Exchange RBAC
 * still refuses any other mailbox; this check is the site's own second lock.
 */
import { ClientCertificateCredential } from "@azure/identity";

import { authEnv } from "@/lib/auth/env";

let credential: ClientCertificateCredential | null = null;

function reader(): ClientCertificateCredential {
  if (credential) return credential;
  const env = authEnv();
  if (!env.M365_READER_TENANT_ID || !env.M365_READER_CLIENT_ID || !env.M365_READER_CERTIFICATE_PEM) {
    throw new Error("The Microsoft 365 reader is not set up here.");
  }
  credential = new ClientCertificateCredential(env.M365_READER_TENANT_ID, env.M365_READER_CLIENT_ID, {
    certificate: env.M365_READER_CERTIFICATE_PEM.replace(/\\n/g, "\n"),
  });
  return credential;
}

/** The mailboxes this site may read, from settings. Anything else is refused here too. */
export function allowedMailboxes(): string[] {
  return (authEnv().M365_READER_MAILBOXES ?? "")
    .split(",")
    .map((m) => m.trim().toLowerCase())
    .filter(Boolean);
}

/** Graph error text with ids removed, so no GUID from Microsoft lands in a record (control C36). */
export function scrubGraphError(text: string): string {
  return text.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, "<id>").slice(0, 500);
}

/** The mailbox a /users/<mailbox>/... path names, lower-cased, or null for any other path. */
export function mailboxInPath(path: string): string | null {
  const match = /^\/users\/([^/?#]+)/i.exec(path);
  if (!match) return null;
  try {
    return decodeURIComponent(match[1]).trim().toLowerCase();
  } catch {
    return match[1].toLowerCase();
  }
}

const GRAPH_BASE = "https://graph.microsoft.com/v1.0";

/**
 * The URL graphGet fetches, or a refusal. fetch normalises a URL before it is
 * sent, so the mailbox check runs on what Microsoft will receive, and any path
 * that could change between the check and the request is refused: a "." or
 * ".." segment, an empty segment, an encoded dot, slash or backslash, a backslash, or an OData
 * key such as /users('<mailbox>') that names a mailbox without a /users/ segment.
 */
export function graphUrl(path: string): URL {
  if (!path.startsWith("/")) throw new Error("A Graph path starts with /.");
  const bare = path.split(/[?#]/, 1)[0];
  if (/\\|%2e|%2f|%5c|\/\//i.test(bare) || bare.split("/").some((segment) => segment === "." || segment === "..")) {
    throw new Error("A Graph path may not hold dot segments, empty segments or encoded slashes.");
  }
  const url = new URL(`${GRAPH_BASE}${path}`);
  if (url.origin !== "https://graph.microsoft.com" || !url.pathname.startsWith("/v1.0/")) {
    throw new Error("A Graph path stays on Microsoft Graph v1.0.");
  }
  const graphPath = url.pathname.slice("/v1.0".length);
  const first = graphPath.split("/")[1] ?? "";
  if (/^users./i.test(first)) throw new Error("Name a mailbox as /users/<mailbox>/..., not as an OData key.");
  const mailbox = mailboxInPath(graphPath);
  if (mailbox !== null && (/[()'"]/.test(mailbox) || !allowedMailboxes().includes(mailbox))) {
    throw new Error("That mailbox is not one this site may read.");
  }
  return url;
}

export async function graphGet<T>(path: string): Promise<T> {
  const url = graphUrl(path);
  // A token error (an AADSTS message) carries trace, correlation, tenant and client ids: scrubbed too.
  const token = await reader()
    .getToken("https://graph.microsoft.com/.default")
    .catch((error: unknown) => {
      throw new Error(`No token for the Microsoft 365 reader: ${scrubGraphError(error instanceof Error ? error.message : String(error))}`);
    });
  if (!token) throw new Error("No token for the Microsoft 365 reader.");
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${token.token}` },
    cache: "no-store",
  });
  if (!response.ok) {
    throw new Error(`Microsoft Graph said ${response.status}: ${scrubGraphError(await response.text())}`);
  }
  return (await response.json()) as T;
}

/** A whole number from 1 to 50 for $top, whatever a caller passes (a request value included). */
export function clampTop(top: unknown): number {
  const n = Math.trunc(Number(top));
  return Number.isFinite(n) ? Math.min(50, Math.max(1, n)) : 10;
}

/** Example: the newest messages in one allowed mailbox. */
export async function latestMessages(mailbox: string, top: unknown = 10) {
  const address = mailbox.trim().toLowerCase();
  if (!allowedMailboxes().includes(address)) throw new Error("That mailbox is not one this site may read.");
  return graphGet<{ value: { id: string; subject: string; receivedDateTime: string }[] }>(
    `/users/${encodeURIComponent(address)}/messages?$top=${clampTop(top)}&$select=id,subject,receivedDateTime&$orderby=receivedDateTime desc`,
  );
}
