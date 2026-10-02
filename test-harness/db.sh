#!/usr/bin/env bash
# The database test (db.integration.test.ts) against a throwaway Postgres on
# this machine: fills the templates, creates the tables in TEST_DATABASE_URL
# with drizzle-kit push, adds the append-only triggers, then runs the test
# once per filled copy, one after the other, clearing the rate-limit counters
# before each.
#
# Usage: TEST_DATABASE_URL=postgres://localhost:<port>/<empty db> bash db.sh
#   (npm run test:db). With no TEST_DATABASE_URL it says so and runs nothing.
# It refuses any database that is not on this machine, or that holds a table
# other than the test's own, before touching it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${TEST_DATABASE_URL:-}" ]; then
  echo "TEST_DATABASE_URL is not set, so the database test did not run."
  echo "Point it at an empty, throwaway Postgres on this machine to run it."
  exit 0
fi

# The same rule the test itself applies, checked before drizzle-kit writes anything.
node -e '
  const LOCAL = ["localhost", "127.0.0.1", "[::1]"];
  let u;
  try { u = new URL(process.argv[1]); } catch { console.error("STOP: TEST_DATABASE_URL is not a URL."); process.exit(1); }
  if (!LOCAL.includes(u.hostname) || u.searchParams.has("host") || u.searchParams.has("hostaddr")) {
    console.error("STOP: TEST_DATABASE_URL is not a database on this machine. Refusing to touch it.");
    process.exit(1);
  }
' "$TEST_DATABASE_URL"

# drizzle-kit push --force drops any table the schema does not name, so a
# database holding anything but the test's own tables is refused, before any
# write. The test's tables are read from the template schema; a rerun on them
# still works.
cd "$HERE"
DATABASE_URL="$TEST_DATABASE_URL" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  import postgres from "postgres";
  const own = new Set();
  for (const f of process.argv.slice(1)) {
    for (const m of readFileSync(f, "utf8").matchAll(/pgTable\(\s*"([^"]+)"/g)) own.add(m[1]);
  }
  if (own.size === 0) { console.error("STOP: no tables found in the template schema."); process.exit(1); }
  const sql = postgres(process.env.DATABASE_URL, { max: 1, onnotice: () => {} });
  let found;
  try {
    found = (await sql.unsafe("select tablename from pg_tables where schemaname = current_schema() order by tablename")).map((r) => r.tablename);
  } finally {
    await sql.end({ timeout: 5 });
  }
  const other = found.filter((t) => !own.has(t));
  if (other.length > 0) {
    console.error("STOP: TEST_DATABASE_URL holds tables the test did not make: " + other.join(", ") + ".");
    console.error("The test pushes its schema with --force, which could drop them. Use an empty, throwaway database.");
    process.exit(1);
  }
' "$HERE/../skills/entra-id-auth/templates/src/db/schema/auth.ts" "$HERE/../skills/entra-id-auth/templates/src/db/schema/access.ts"

bash "$HERE/fill.sh"

# Every copy has the same schema; create it once from the first.
cd "$HERE/.work/site-listed"
DATABASE_URL="$TEST_DATABASE_URL" "$HERE/node_modules/.bin/drizzle-kit" push --config drizzle.config.example.ts --force
cd "$HERE"
# clear_rate_limit: Better Auth keeps its rate-limit counters in the database,
# so a copy run straight after another would be refused with 429 by the counts
# of the one before. Cleared before every copy.
clear_rate_limit() {
  DATABASE_URL="$TEST_DATABASE_URL" node --input-type=module -e '
    import postgres from "postgres";
    const sql = postgres(process.env.DATABASE_URL, { max: 1, onnotice: () => {} });
    try { await sql.unsafe("delete from rate_limit"); } finally { await sql.end({ timeout: 5 }); }
  '
}

DATABASE_URL="$TEST_DATABASE_URL" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  import postgres from "postgres";
  const sql = postgres(process.env.DATABASE_URL, { max: 1, onnotice: () => {} });
  try {
    await sql.unsafe(readFileSync(process.argv[1], "utf8"));
    console.log("append-only triggers in place");
  } finally {
    await sql.end({ timeout: 5 });
  }
' "$HERE/.work/site-listed/drizzle/access_append_only.sql"

# One copy at a time, each with fresh rate-limit counters.
for dir in "$HERE"/.work/*/; do
  name="$(basename "$dir")"
  clear_rate_limit
  echo "database test: $name"
  HARNESS_SUITE=db "$HERE/node_modules/.bin/vitest" run --project "$name"
done
