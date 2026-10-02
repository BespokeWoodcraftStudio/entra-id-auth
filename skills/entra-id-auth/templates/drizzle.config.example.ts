/**
 * copy-templates.sh fills in the source root and writes this as drizzle.config.ts
 * when the site has no Drizzle config. When it has one, the copy lists it as
 * MERGE: add both sign-in schema files to its schema list; keep one config.
 */
import { config } from "dotenv";
import { defineConfig } from "drizzle-kit";

config({ path: ".env.local", quiet: true });

export default defineConfig({
  dialect: "postgresql",
  schema: ["./__SRC_ROOT__/db/schema/auth.ts", "./__SRC_ROOT__/db/schema/access.ts"],
  out: "./drizzle",
  dbCredentials: { url: process.env.DATABASE_URL! },
});
