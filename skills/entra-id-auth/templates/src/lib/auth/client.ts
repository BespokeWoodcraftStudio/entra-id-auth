/**
 * The browser side of Better Auth. It talks only to this site's own
 * /api/auth; the browser never holds a Microsoft token (control M2).
 */
import { createAuthClient } from "better-auth/react";

export const authClient = createAuthClient();
