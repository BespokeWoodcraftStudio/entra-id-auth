/**
 * Turns `?next=` into a path this site will navigate to, or refuses it
 * (control C22). Better Auth's own check is not borrowed: `/\evil.com` resolves
 * off-site in every browser, and this check must hold wherever `next` is
 * read, not only where the library sees it.
 *
 * Takes `unknown`: Next 16 hands a repeated `?next=` over as an array, and a
 * crafted link must not crash the page. Anything but a single string is
 * refused, an array included (which of two values was meant is not ours to guess).
 *
 * Refuses anything that is empty; does not start with one "/"; starts with
 * "//"; contains a backslash, a control character, or an encoded slash or
 * backslash; or does not resolve to the same origin.
 */
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/;
const ENCODED_SLASH = /%2f|%5c/i;

export function safeNextPath(next: unknown): string | undefined {
  if (typeof next !== "string" || !next) return undefined;
  if (!next.startsWith("/") || next.startsWith("//")) return undefined;
  if (next.includes("\\") || CONTROL.test(next) || ENCODED_SLASH.test(next)) return undefined;
  const origin = "https://site.invalid";
  try {
    if (new URL(next, origin).origin !== origin) return undefined;
  } catch {
    return undefined;
  }
  return next;
}
