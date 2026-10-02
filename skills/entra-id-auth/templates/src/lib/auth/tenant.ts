/**
 * The `tid`, `aud` and `roles` claims off the stored id token, read without
 * checking its signature.
 *
 * What the token's authenticity really rests on: it came back from our
 * tenant's own token endpoint, over TLS, in exchange for a code, our client
 * secret and the PKCE verifier (OpenID Connect Core 3.1.3.7, item 6). Better
 * Auth does not verify the id token's signature, audience or issuer on this
 * code-flow path (better-auth 1.7.5 and 1.7.6); it only stores the token. The
 * one path that would take an id token from the browser, POST /sign-in/social
 * with { idToken }, is switched off in server.ts (disableIdTokenSignIn).
 *
 * So `tid` and `aud` are a second check on what the token endpoint gave us,
 * never the only one, and never used to authenticate anything. `roles` sets
 * the role inside the site only when ROLE_SOURCE is "entra" (settings.ts);
 * it rests on the same exchange, and the person must already have passed
 * every other check before it is read.
 */
export interface IdTokenClaims {
  tid: string | null;
  /** Every audience the token names (the claim may be a string or a list). */
  aud: string[];
  /** The app roles Entra assigned this person for this app (empty when none, or when the claim is absent). */
  roles: string[];
}

const strings = (value: unknown): string[] =>
  typeof value === "string" ? [value] : Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];

export function claimsFromIdToken(idToken: string): IdTokenClaims | null {
  try {
    const payload = idToken.split(".")[1];
    if (!payload) return null;
    const parsed: unknown = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    if (!parsed || typeof parsed !== "object") return null;
    const { tid, aud, roles } = parsed as { tid?: unknown; aud?: unknown; roles?: unknown };
    return { tid: typeof tid === "string" ? tid : null, aud: strings(aud), roles: strings(roles) };
  } catch {
    return null;
  }
}
