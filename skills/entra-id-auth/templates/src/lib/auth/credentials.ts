/**
 * When the site's Microsoft credentials end, read from the dates the setup
 * wrote beside them (never from the secrets themselves), so administrators
 * are warned in the site 30 days ahead and the daily check logs it
 * (control M11: an expiry date typed by hand drifts from the real one).
 */
import { authEnv } from "./env";
import { CREDENTIAL_WARNING_DAYS } from "./settings";

export interface CredentialStatus {
  name: string;
  endsOn: string | null;
  daysLeft: number | null;
  warn: boolean;
}

function status(name: string, iso: string | undefined, now: Date): CredentialStatus {
  if (!iso) return { name, endsOn: null, daysLeft: null, warn: true };
  const ends = new Date(iso);
  if (Number.isNaN(ends.getTime())) return { name, endsOn: null, daysLeft: null, warn: true };
  const daysLeft = Math.floor((ends.getTime() - now.getTime()) / 86_400_000);
  return { name, endsOn: ends.toISOString().slice(0, 10), daysLeft, warn: daysLeft <= CREDENTIAL_WARNING_DAYS };
}

export function credentialStatuses(now: Date = new Date()): CredentialStatus[] {
  const env = authEnv();
  const out: CredentialStatus[] = [];
  if (env.MICROSOFT_ENTRA_CLIENT_ID) out.push(status("Microsoft sign-in secret", env.MICROSOFT_ENTRA_CLIENT_SECRET_EXPIRES, now));
  if (env.M365_READER_CLIENT_ID) out.push(status("Microsoft 365 reader certificate", env.M365_READER_CERTIFICATE_EXPIRES, now));
  return out;
}

/** The one line an administrator sees in the site, or null when all is well. */
export function credentialWarning(now: Date = new Date()): string | null {
  const due = credentialStatuses(now).filter((c) => c.warn);
  if (due.length === 0) return null;
  return due
    .map((c) =>
      c.endsOn === null
        ? `${c.name}: its end date is not recorded. Renew it and record the date.`
        : c.daysLeft !== null && c.daysLeft < 0
          ? `${c.name} ended on ${c.endsOn}. Sign-in stops working until it is renewed.`
          : `${c.name} ends on ${c.endsOn}, in ${c.daysLeft} days. Renew it now.`,
    )
    .join(" ");
}
