/**
 * Only copy this file when the site has no database client yet. If it has
 * one, keep it and make sure it exports getDb() and the Database type, which
 * the sign-in code imports.
 *
 * Plain Postgres over the `postgres` driver: the same code runs against a
 * local Postgres and against Neon on Vercel.
 */
import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";

import * as access from "@/db/schema/access";
import * as authTables from "@/db/schema/auth";

const schema = { ...authTables, ...access };

export type Database = ReturnType<typeof drizzle<typeof schema>>;

declare global {
  var __siteSql: ReturnType<typeof postgres> | undefined;
  var __siteDb: Database | undefined;
}

export function getDb(): Database {
  if (!globalThis.__siteDb) {
    const url = process.env.DATABASE_URL;
    if (!url) throw new Error("DATABASE_URL is not set.");
    globalThis.__siteSql ??= postgres(url, {
      max: process.env.VERCEL ? 1 : 10,
      idle_timeout: 20,
      connect_timeout: 10,
      prepare: false,
    });
    globalThis.__siteDb = drizzle(globalThis.__siteSql, { schema });
  }
  return globalThis.__siteDb;
}

export async function closeDb(): Promise<void> {
  await globalThis.__siteSql?.end({ timeout: 5 });
  globalThis.__siteSql = undefined;
  globalThis.__siteDb = undefined;
}
