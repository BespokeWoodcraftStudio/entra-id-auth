/**
 * Example: every route handler checks the person itself, even though the
 * proxy already has, so the handler stays closed if the proxy is changed,
 * merged badly or skipped. Every route.ts on a gated path (outside
 * PUBLIC_PATHS and SERVER_TO_SERVER_PATHS) calls requireCurrentPerson() or
 * requireAdministrator() first in every exported method, GET, POST and the
 * rest each on its own (control C26; page-checks.test.ts fails on a method
 * that does not). The try below is the one shape the check allows around the
 * call: nothing after the try, and every catch returns a response or
 * rethrows, so a refused person never falls through to the data.
 */
import { NextResponse } from "next/server";

import { AccessError, requireCurrentPerson } from "@/lib/auth/current-person";

export async function GET() {
  try {
    const person = await requireCurrentPerson();
    return NextResponse.json({ hello: person.displayName });
  } catch (error) {
    if (error instanceof AccessError) {
      return NextResponse.json({ error: error.code }, { status: error.code === "not_signed_in" ? 401 : 403 });
    }
    throw error;
  }
}
