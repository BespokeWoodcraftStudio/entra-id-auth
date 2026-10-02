/**
 * Vitest for the sign-in tests. Merge into the site's own vitest config if it
 * has one. The "@" alias must match tsconfig's "@/*" path, or no test can
 * import the code it tests.
 */
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: { alias: { "@": fileURLToPath(new URL("./__SRC_ROOT__", import.meta.url)) } },
  test: { environment: "node", include: ["tests/**/*.test.ts"] },
});
