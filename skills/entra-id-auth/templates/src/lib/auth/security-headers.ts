/**
 * The site's security headers, in one place, used by next.config.ts (every
 * response) and by proxy.ts (the CSP, which needs a fresh nonce per request).
 * Tested as a table.
 *
 * Four static headers alone are not enough: a full CSP (control C31), a
 * Referrer-Policy and no X-Powered-By header (control C32) complete the set.
 */

/** Sent on every response, including static files. */
export const STATIC_SECURITY_HEADERS: ReadonlyArray<{ key: string; value: string }> = [
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=(), usb=()" },
  // Control C33: a private site is never indexed. Here as well as in vercel.json,
  // so it holds on any host. A site with a public landing page it wants found
  // removes this deliberately.
  { key: "X-Robots-Tag", value: "noindex, nofollow, noarchive, nosnippet, noimageindex" },
];

export interface CspOptions {
  nonce: string;
  /** `next dev` needs 'unsafe-eval' for React's error overlays; production never does. */
  development: boolean;
  /** A Vercel preview loads the Vercel toolbar from vercel.live. */
  preview: boolean;
}

/**
 * A strict, nonce-based policy (Next.js's own guide). Scripts run only with
 * this request's nonce or when loaded by a script that had it
 * ('strict-dynamic'). Styles allow 'unsafe-inline' because React style
 * attributes and many UI libraries need it; script injection is the risk a
 * CSP must stop, and it does. Forms post only to this site and to Microsoft's
 * sign-in. Nothing may frame the site.
 */
export function buildCsp({ nonce, development, preview }: CspOptions): string {
  const vercelLive = preview ? " https://vercel.live" : "";
  const directives = [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${development ? " 'unsafe-eval'" : ""}${vercelLive}`,
    "style-src 'self' 'unsafe-inline'",
    `img-src 'self' blob: data:${preview ? " https://vercel.live https://vercel.com" : ""}`,
    "font-src 'self' data:",
    `connect-src 'self'${preview ? " https://vercel.live wss://ws-us3.pusher.com" : ""}${development ? " ws:" : ""}`,
    `frame-src ${preview ? "https://vercel.live" : "'none'"}`,
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'self' https://login.microsoftonline.com",
    "frame-ancestors 'none'",
    ...(development ? [] : ["upgrade-insecure-requests"]),
  ];
  return directives.join("; ");
}

/** A fresh, unguessable nonce for one request. */
export function newNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes));
}
