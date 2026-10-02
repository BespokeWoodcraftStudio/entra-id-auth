"use client";

import { useRouter } from "next/navigation";
import { useEffect } from "react";

import { authClient } from "@/lib/auth/client";
import { SESSION_RENEW_AFTER_SECONDS } from "@/lib/auth/settings";

/**
 * Keeps an active person signed in, and lets an idle one go.
 *
 * The session lasts SESSION_IDLE_MINUTES from its last renewal (settings.ts).
 * Server pages read the session but cannot reset the cookie, so this asks the
 * session endpoint at most once per SESSION_RENEW_AFTER_SECONDS, and only
 * after real activity (a key, a click, the tab coming back). No activity, no
 * renewal: the session ends after the idle limit. The absolute limit,
 * SESSION_MAX_HOURS after sign-in, holds either way.
 */
const MIN_GAP_MS = SESSION_RENEW_AFTER_SECONDS * 1000;

export function SessionKeepAlive() {
  const router = useRouter();
  useEffect(() => {
    let last = Date.now();
    const renew = () => {
      if (document.visibilityState !== "visible") return;
      if (Date.now() - last < MIN_GAP_MS) return;
      last = Date.now();
      void authClient.getSession().then((result) => {
        if (!result?.data) router.replace("/sign-in");
      });
    };
    const events = ["keydown", "pointerdown", "visibilitychange"] as const;
    for (const e of events) window.addEventListener(e, renew, { passive: true });
    return () => {
      for (const e of events) window.removeEventListener(e, renew);
    };
  }, [router]);
  return null;
}
