/**
 * Runs the templates' own tests against every filled copy fill.sh made in
 * .work, one vitest project per copy. Each project's "@" alias points at its
 * own copy's src, as the template's vitest.config.mts does on a real site.
 *
 * HARNESS_SUITE=db runs only db.integration.test.ts (npm run test:db), one
 * file at a time, because every copy shares the one throwaway database.
 * Otherwise it runs everything else; the database test is left out, as it
 * skips itself anyway with no TEST_DATABASE_URL.
 */
import { existsSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const work = fileURLToPath(new URL("./.work", import.meta.url));
if (!existsSync(work)) throw new Error("Nothing filled yet: run bash fill.sh first (npm test does).");
const copies = readdirSync(work, { withFileTypes: true })
  .filter((d) => d.isDirectory())
  .map((d) => d.name);

const DB_TEST = "tests/unit/auth/db.integration.test.ts";
const dbSuite = process.env.HARNESS_SUITE === "db";

export default defineConfig({
  test: {
    fileParallelism: !dbSuite,
    projects: copies.map((name) => ({
      resolve: { alias: { "@": `${work}/${name}/src` } },
      test: {
        name,
        root: `${work}/${name}`,
        environment: "node",
        include: dbSuite ? [DB_TEST] : ["tests/**/*.test.ts"],
        exclude: dbSuite ? [] : [DB_TEST],
      },
    })),
  },
});
