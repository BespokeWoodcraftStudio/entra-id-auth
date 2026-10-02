/**
 * GET /api/health
 *
 * To anyone: `{"ok":true}` and nothing else. To the CRON_SECRET bearer or a
 * signed-in administrator: which settings are present (never a value) and
 * when the Microsoft credentials end. Answering anyone with the whole settings
 * list would tell a stranger how the site is set up (control C35).
 */
import { NextResponse } from "next/server";

import { credentialStatuses } from "@/lib/auth/credentials";
import { getCurrentPerson, isAdministrator } from "@/lib/auth/current-person";
import { describeAuthEnv } from "@/lib/auth/env";
import { isAuthorizedServerCall } from "@/lib/auth/server-caller";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  let allowed = isAuthorizedServerCall(request.headers.get("authorization"));
  if (!allowed) {
    const person = await getCurrentPerson().catch(() => null);
    allowed = person !== null && isAdministrator(person);
  }
  if (!allowed) return NextResponse.json({ ok: true });

  const credentials = credentialStatuses();
  return NextResponse.json({
    ok: true,
    settings: describeAuthEnv(),
    credentials,
    warn: credentials.some((c) => c.warn),
  });
}
