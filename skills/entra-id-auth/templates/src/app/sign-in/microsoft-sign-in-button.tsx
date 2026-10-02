"use client";

import { useState } from "react";

import { authClient } from "@/lib/auth/client";

/**
 * Starts the Microsoft sign-in. `signIn.social` returns `{ error }` instead of
 * throwing for a handled failure, so the button says something rather than
 * silently re-enabling.
 */
export function MicrosoftSignInButton({ next }: { next?: string }) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function start() {
    setPending(true);
    setError(null);
    const result = await authClient.signIn.social({
      provider: "microsoft",
      callbackURL: next ?? "/",
      errorCallbackURL: "/sign-in",
    });
    if (result?.error) {
      setPending(false);
      setError("Something went wrong. Try again.");
    }
  }

  return (
    <div className="sign-in-microsoft">
      {error ? <p role="alert">{error}</p> : null}
      <button type="button" onClick={start} disabled={pending}>
        {pending ? "Opening Microsoft..." : "Sign in with Microsoft"}
      </button>
    </div>
  );
}
