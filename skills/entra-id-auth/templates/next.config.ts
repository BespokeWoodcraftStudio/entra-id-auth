/**
 * Merge into the site's own next.config (.ts, .mts, .js or .mjs); never keep
 * two. Next loads only one, the .js or .mjs before this .ts, so a second file
 * beside the site's own is silently ignored. The CSP is not here: it needs a
 * fresh nonce per request, so src/proxy.ts sets it.
 */
import type { NextConfig } from "next";

import { STATIC_SECURITY_HEADERS } from "./__SRC_ROOT__/lib/auth/security-headers";

const nextConfig: NextConfig = {
  // Control C32: no X-Powered-By.
  poweredByHeader: false,
  async headers() {
    return [{ source: "/(.*)", headers: [...STATIC_SECURITY_HEADERS] }];
  },
};

export default nextConfig;
