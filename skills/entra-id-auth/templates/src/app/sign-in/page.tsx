/**
 * The one page a stranger can reach. It shows no live data (control C25),
 * maps `?error=` codes to fixed words and never renders `error_description`
 * (control C23), and only follows a `next` path that safeNextPath accepts
 * (control C22).
 *
 * Plain markup, so it drops into any design. Restyle
 * freely; keep the three rules above.
 *
 * A stranger cannot load files from public/ (all but the favicon, robots.txt
 * and the two icons are gated). A logo or font used here is imported (a
 * static import, served from /_next/static), or its exact path, such as
 * "/logo.svg", goes in PUBLIC_PATHS (settings.ts); never a whole folder.
 */
import { redirect } from "next/navigation";

import { getCurrentPerson } from "@/lib/auth/current-person";
import { microsoftConfigured, passwordSignInAllowed } from "@/lib/auth/env";
import { messageForErrorCode } from "@/lib/auth/messages";
import { SITE_NAME } from "@/lib/auth/settings";

import { MicrosoftSignInButton } from "./microsoft-sign-in-button";
import { PasswordSignInForm } from "./password-sign-in-form";
import { safeNextPath } from "./safe-next-path";

export const dynamic = "force-dynamic";

export default async function SignInPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  // A repeated ?next= or ?error= arrives as an array; only a single string is read.
  const params = await searchParams;
  const error = typeof params.error === "string" ? params.error : undefined;
  const safeNext = safeNextPath(params.next);

  // Already signed in: go on. A refused or expired session reads as null here.
  if (!error && (await getCurrentPerson())) redirect(safeNext ?? "/");

  const message = messageForErrorCode(error);
  const microsoft = microsoftConfigured();
  const password = passwordSignInAllowed();

  return (
    <main className="sign-in">
      <h1>{SITE_NAME}</h1>
      <p>Sign in with your work Microsoft account.</p>
      {message ? (
        <p role="alert" className="sign-in-error">
          {message}
        </p>
      ) : null}
      {microsoft ? <MicrosoftSignInButton next={safeNext} /> : null}
      {password ? <PasswordSignInForm next={safeNext} /> : null}
      {!microsoft && !password ? <p>Sign-in is not set up on this copy of the site.</p> : null}
    </main>
  );
}
