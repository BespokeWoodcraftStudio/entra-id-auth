/**
 * Every Better Auth endpoint (sign-in, the Microsoft callback, session,
 * sign-out) is served from here. The proxy lets /api/auth through without a
 * cookie; Better Auth checks origin, state and PKCE itself.
 */
import { toNextJsHandler } from "better-auth/next-js";

import { auth } from "@/lib/auth/server";

export const { GET, POST } = toNextJsHandler(auth);
