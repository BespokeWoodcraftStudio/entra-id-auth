"use client";

import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";

import { authClient } from "@/lib/auth/client";

/**
 * The test password lane. Rendered only where passwordSignInAllowed() is true
 * (a preview or a local copy), and the server refuses it anyway anywhere else
 * and for any address that does not end in .invalid (control C27).
 */
export function PasswordSignInForm({ next }: { next?: string }) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    setError(null);
    const result = await authClient.signIn.email({
      email: String(form.get("email") ?? ""),
      password: String(form.get("password") ?? ""),
    });
    setPending(false);
    if (result?.error) {
      // The server's own fixed words for the gate's refusals; a generic line otherwise.
      setError(result.error.status === 403 && result.error.message ? result.error.message : "That did not work. Check the address and password.");
      return;
    }
    router.push(next ?? "/");
    router.refresh();
  }

  return (
    <form className="sign-in-password" onSubmit={submit}>
      <p>Test sign-in (this copy only)</p>
      {error ? <p role="alert">{error}</p> : null}
      <label>
        Test address
        <input name="email" type="email" autoComplete="username" required placeholder="someone@test.invalid" />
      </label>
      <label>
        Password
        <input name="password" type="password" autoComplete="current-password" required />
      </label>
      <button type="submit" disabled={pending}>
        {pending ? "Signing in..." : "Sign in"}
      </button>
    </form>
  );
}
