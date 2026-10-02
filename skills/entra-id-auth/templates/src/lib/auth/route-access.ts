/**
 * Which paths answer without a session. Everything not named here is gated,
 * so a route added later is covered the day it exists (control C25).
 *
 * Each entry matches a whole segment: "/sign-in" matches "/sign-in" and
 * "/sign-in/anything", never "/sign-in-help".
 */
import { PUBLIC_PATHS, SERVER_TO_SERVER_PATHS } from "./settings";

const STATIC_PREFIXES = ["/_next/static", "/_next/image"];
const STATIC_FILES = new Set(["/favicon.ico", "/robots.txt", "/icon.svg", "/apple-icon.png"]);

function underSegment(pathname: string, base: string): boolean {
  return pathname === base || pathname.startsWith(`${base}/`);
}

export function isStaticAsset(pathname: string): boolean {
  return STATIC_FILES.has(pathname) || STATIC_PREFIXES.some((p) => underSegment(pathname, p));
}

export function isServerToServerPath(pathname: string): boolean {
  return SERVER_TO_SERVER_PATHS.some((p) => underSegment(pathname, p));
}

/** True when the request may pass the gate without a session cookie. */
export function isPublicPath(pathname: string): boolean {
  return (
    isStaticAsset(pathname) ||
    isServerToServerPath(pathname) ||
    PUBLIC_PATHS.some((p) => underSegment(pathname, p))
  );
}
