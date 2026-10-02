/**
 * Every word a person reads about signing in, in one place. The sign-in page
 * maps `?error=<code>` to these fixed words and never shows
 * `error_description`, which can carry a provider's raw text or anything an
 * attacker puts on a link (control C23).
 *
 * No import here reaches back to server.ts, so server.ts can import it.
 */
import { SITE_NAME } from "./settings";

const ASK = "Ask an administrator if you think this is wrong.";

/** A refusal: the person reached us and we said no, for a reason they can act on. */
export const REFUSAL_MESSAGE = {
  refused_wrong_tenant: `That is not a work account for ${SITE_NAME}. Sign in with your work Microsoft account.`,
  refused_not_on_the_list: `This account is not on ${SITE_NAME}'s list. ${ASK}`,
  refused_switched_off: `Your access to ${SITE_NAME} was switched off. ${ASK}`,
  refused_identity_mismatch: `This Microsoft account is not the one ${SITE_NAME} knows for that address. ${ASK}`,
  refused_password_not_allowed_here: "Test sign-in is not available here.",
  refused_session_expired: "You were signed out after a long session. Sign in again.",
} as const;

export type RefusalCode = keyof typeof REFUSAL_MESSAGE;

export function isRefusalCode(code: string): code is RefusalCode {
  return Object.prototype.hasOwnProperty.call(REFUSAL_MESSAGE, code);
}

/**
 * Not a refusal: the trip to Microsoft and back went wrong (an expired sign-in
 * page, a replayed link). Never "refused", never "ask an administrator".
 */
export const SOMETHING_WENT_WRONG =
  "Something went wrong on the way back from Microsoft. Try signing in again.";

/** Codes Better Auth itself sends that mean the account could not be matched. */
export const ACCOUNT_PROBLEM_CODES = new Set([
  "account_not_linked",
  "unable_to_link_account",
  "account_already_linked_to_different_user",
  "email_not_found",
  "email_doesn't_match",
  "email_does_not_match",
]);

export const ACCOUNT_PROBLEM =
  `Your Microsoft account could not be matched to ${SITE_NAME}. It may have no email address set. ${ASK}`;

/** The one function the sign-in page calls. Unknown codes get the generic line. */
export function messageForErrorCode(code: string | undefined): string | null {
  if (!code) return null;
  if (isRefusalCode(code)) return REFUSAL_MESSAGE[code];
  if (ACCOUNT_PROBLEM_CODES.has(code)) return ACCOUNT_PROBLEM;
  return SOMETHING_WENT_WRONG;
}

export const PASSWORD_LANE_MESSAGE = {
  notATestAddress: "The test sign-in only works for a test account ending in .invalid. Use the Microsoft button.",
  testAccountHasMicrosoft: "This test account is also linked to a Microsoft sign-in. Use the Microsoft button.",
} as const;
