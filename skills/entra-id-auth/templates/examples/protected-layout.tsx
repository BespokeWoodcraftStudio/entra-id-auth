/**
 * Example: the layout of the signed-in part of the site.
 *
 * Where it goes: a route group, src/app/(app)/layout.tsx, with every
 * signed-in page moved under src/app/(app)/ (a route group adds nothing to
 * the URL, so src/app/page.tsx becomes src/app/(app)/page.tsx and still
 * serves /). Never the root src/app/layout.tsx: the root layout also wraps
 * /sign-in, so its redirect would send /sign-in to itself and nobody could
 * sign in. The same holds for a root template.tsx or default.tsx: they show
 * nothing private and never check, and one that needs the person moves into
 * src/app/(app)/. If the site already has a layout for its signed-in pages, put the
 * requirePagePerson() line at the top of that one.
 *
 * This layout is a convenience, not the gate. It keeps the session alive and
 * shows administrators the credential warning. It does not protect the pages
 * under it: Next renders a layout and its page in parallel, and when the
 * layout redirects, a page with no check of its own is still sent in the body
 * of the 307. Next's own authentication guide says so: "a layout that hides
 * or swaps them does not stop them from running or from appearing in the RSC
 * Payload" (them: the route segments and slots under it).
 *
 * The gate is two checks (control C26):
 *  1. proxy.ts reads the person in full on every gated path before anything
 *     renders, so a made-up or expired cookie gets a 307 and nothing else.
 *  2. Every page, layout, template and default file on a gated path, this
 *     one included, calls requirePagePerson() as its first line
 *     (examples/protected-page.tsx).
 *     tests/unit/auth/page-checks.test.ts fails on a file whose default
 *     export does not start with it.
 * Every route handler and server action calls requireCurrentPerson() or
 * requireAdministrator() itself (examples/route-handler.ts).
 */
import type { ReactNode } from "react";

import { SessionKeepAlive } from "@/components/auth/session-keep-alive";
import { credentialWarning } from "@/lib/auth/credentials";
import { isAdministrator, requirePagePerson } from "@/lib/auth/current-person";

export default async function SignedInLayout({ children }: { children: ReactNode }) {
  const person = await requirePagePerson();

  const warning = isAdministrator(person) ? credentialWarning() : null;

  return (
    <>
      <SessionKeepAlive />
      {warning ? <div role="status">{warning}</div> : null}
      {children}
    </>
  );
}
