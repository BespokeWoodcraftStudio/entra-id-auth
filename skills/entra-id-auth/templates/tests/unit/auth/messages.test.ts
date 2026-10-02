/** Error codes become fixed words; nothing from the link is echoed (control C23). */
import { describe, expect, it } from "vitest";

import { messageForErrorCode, REFUSAL_MESSAGE, SOMETHING_WENT_WRONG } from "@/lib/auth/messages";

describe("messageForErrorCode", () => {
  it("maps each refusal to its own words", () => {
    for (const [code, words] of Object.entries(REFUSAL_MESSAGE)) expect(messageForErrorCode(code)).toBe(words);
  });
  it("gives a try-again line for a broken round trip, never 'refused'", () => {
    expect(messageForErrorCode("state_mismatch")).toBe(SOMETHING_WENT_WRONG);
    expect(messageForErrorCode("invalid_code")).toBe(SOMETHING_WENT_WRONG);
  });
  it("never repeats what an attacker put in the code", () => {
    expect(messageForErrorCode("<script>alert(1)</script>")).toBe(SOMETHING_WENT_WRONG);
  });
  it("says nothing without a code", () => {
    expect(messageForErrorCode(undefined)).toBeNull();
  });
});
