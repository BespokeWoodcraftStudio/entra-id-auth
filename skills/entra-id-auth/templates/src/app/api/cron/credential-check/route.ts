/**
 * GET /api/cron/credential-check, daily from vercel.json. Bearer only.
 * Logs a warning when a Microsoft credential ends within 30 days, so the
 * renewal shows in the Vercel logs as well as on administrators' screens.
 */
import { NextResponse } from "next/server";

import { credentialStatuses } from "@/lib/auth/credentials";
import { isAuthorizedServerCall } from "@/lib/auth/server-caller";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  if (!isAuthorizedServerCall(request.headers.get("authorization"))) {
    return NextResponse.json({ ok: false }, { status: 401 });
  }
  const credentials = credentialStatuses();
  for (const c of credentials.filter((x) => x.warn)) {
    console.warn(`Credential renewal due: ${c.name} ends ${c.endsOn ?? "on an unrecorded date"} (${c.daysLeft ?? "?"} days).`);
  }
  return NextResponse.json({ ok: true, due: credentials.filter((c) => c.warn).length });
}
