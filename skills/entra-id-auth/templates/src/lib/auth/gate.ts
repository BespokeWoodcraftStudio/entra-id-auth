/**
 * The site's own door: who gets a session. Called from the one place every
 * sign-in passes through, Better Auth's `databaseHooks.session.create.before`
 * (server.ts). Throwing there becomes `/sign-in?error=<code>`; throwing from
 * `mapProfileToUser` does not, and shows raw JSON.
 *
 * The decision is a pure function over a small lookup interface, so every
 * branch is unit tested without a database (control C4).
 *
 * Order, and why:
 *  1. A password sign-in: only the test lane, only a .invalid address, only
 *     one with no Microsoft account (control C27).
 *  2. A Microsoft sign-in: the tenant on the stored id token must be ours,
 *     again, after the provider's own tenant lock (control C1, C4), and the
 *     token must name our app as its audience (refused the same way). See
 *     tenant.ts for what the token's authenticity rests on.
 *  3. The person is found by Entra object id + tenant, never by email
 *     (control C5). The first time, email matches a listed person with no
 *     binding yet and the binding is written; after that email is ignored.
 *     Someone not on the list is refused, unless JOIN_MODE is "group": then a
 *     person Microsoft let through (a member of the site's group) is added as
 *     a member at this first sign-in, bound by object id, and the row says so;
 *     with ALLOW_GUESTS "no", only when the address is on the organisation's
 *     own domains, so a guest put into the group in Microsoft is refused.
 *  4. Their newest assignment must be active (control C6).
 *  5. With ROLE_SOURCE "entra" only: the role comes from the id token's
 *     `roles` claim. When it differs from their newest assignment, a new row
 *     is appended, recorded as set by the Entra app role at sign-in.
 *
 * No import here may reach back to server.ts (it runs while that is built).
 */
import { emailOnDomains } from "./settings";
import { claimsFromIdToken } from "./tenant";

/** The roles inside the site (the person_role enum in db/schema/access.ts). */
export type SiteRole = "administrator" | "member";

/** The value of the Entra app role that makes someone an administrator here. */
export const ENTRA_ADMINISTRATOR_ROLE = "administrator";

/** The site role an id token's `roles` claim gives: administrator only with that app role, else member. */
export function roleFromEntraRoles(roles: readonly string[]): SiteRole {
  return roles.some((r) => r.trim().toLowerCase() === ENTRA_ADMINISTRATOR_ROLE) ? "administrator" : "member";
}

export type SignInOutcome =
  | "granted"
  | "refused_wrong_tenant"
  | "refused_not_on_the_list"
  | "refused_switched_off"
  | "refused_identity_mismatch"
  | "refused_password_not_allowed_here"
  | "refused_other";

export type PasswordRefusal = "not_a_test_address" | "test_account_has_microsoft" | "lane_off";

/** Why a Microsoft token was refused, when the tenant alone does not say. Logged as the row's detail. */
export type TokenRefusal = "wrong_audience";

/** Why a JOIN_MODE "group" join was refused. Logged as the row's detail. */
export type JoinRefusal = "outside_org_domains";

/** What a granted sign-in changed on the list, if anything. Logged as the row's detail. */
export type GrantNote = "joined_from_group" | "role_from_entra";

export interface JoinInput {
  email: string;
  displayName: string;
  tenantId: string;
  objectId: string;
}

export interface GateLookups {
  /** The Microsoft account linked to this Better Auth user, newest first. */
  microsoftAccountFor(userId: string): Promise<{ objectId: string; idToken: string | null } | null>;
  /** The lower-cased email Better Auth stored for this user. */
  emailFor(userId: string): Promise<string | null>;
  /** The display name Better Auth stored for this user (from the token's `name`). */
  nameFor(userId: string): Promise<string | null>;
  personByIdentity(tenantId: string, objectId: string): Promise<{ personId: string } | null>;
  personByEmail(email: string): Promise<{ personId: string; boundObjectId: string | null } | null>;
  /** Writes the binding. Returns false if another sign-in bound it first. */
  bindIdentity(personId: string, tenantId: string, objectId: string): Promise<boolean>;
  latestAssignment(personId: string): Promise<{ active: boolean; role: SiteRole } | null>;
  /**
   * JOIN_MODE "group": adds the person, binds the identity and appends an
   * active member row, in one transaction. Returns null if another sign-in
   * added this address or bound this identity first.
   */
  joinPerson(input: JoinInput): Promise<{ personId: string } | null>;
  /** ROLE_SOURCE "entra": appends an active row with this role, set by the Entra app role at sign-in. */
  setRoleFromEntra(personId: string, role: SiteRole): Promise<void>;
}

export interface GateInput {
  userId: string;
  /** Better Auth's endpoint path: "/sign-in/email" for a password, "/callback/:id" for Microsoft (the route pattern, not the provider id). */
  path: string | null;
  expectedTenantId: string | null;
  /** The app's client id: the id token's `aud` must name it. */
  expectedClientId: string | null;
  passwordLaneOn: boolean;
  /** settings.ts ROLE_SOURCE: "entra" reads the role from the id token. */
  roleSource: "site" | "entra";
  /** settings.ts JOIN_MODE: "group" adds a group member who is not on the list yet. */
  joinMode: "listed" | "group";
  /** settings.ts ALLOW_GUESTS: false refuses a join from an address outside orgEmailDomains. */
  allowGuests: boolean;
  /** settings.ts ORG_EMAIL_DOMAINS. */
  orgEmailDomains: readonly string[];
}

export interface GateDecision {
  outcome: SignInOutcome;
  personId: string | null;
  email: string | null;
  tenantIdSeen: string | null;
  objectIdSeen: string | null;
  passwordRefusal?: PasswordRefusal;
  tokenRefusal?: TokenRefusal;
  joinRefusal?: JoinRefusal;
  grantNote?: GrantNote;
  /** True when the refused user's Better Auth rows should be removed (control C14). */
  removeAuthRows: boolean;
}

const TEST_SUFFIX = ".invalid";

export async function decideSignIn(input: GateInput, look: GateLookups): Promise<GateDecision> {
  const email = (await look.emailFor(input.userId))?.toLowerCase() ?? null;
  const microsoft = await look.microsoftAccountFor(input.userId);
  const base: Omit<GateDecision, "outcome"> = { email, tenantIdSeen: null, objectIdSeen: null, personId: null, removeAuthRows: false };

  // 1. The test password lane.
  if (input.path === "/sign-in/email") {
    if (!input.passwordLaneOn) return { ...base, outcome: "refused_password_not_allowed_here", passwordRefusal: "lane_off" };
    if (microsoft) return { ...base, outcome: "refused_password_not_allowed_here", passwordRefusal: "test_account_has_microsoft" };
    if (!email || !email.endsWith(TEST_SUFFIX)) {
      return { ...base, outcome: "refused_password_not_allowed_here", passwordRefusal: "not_a_test_address" };
    }
    const person = await look.personByEmail(email);
    if (!person) return { ...base, outcome: "refused_not_on_the_list" };
    const assignment = await look.latestAssignment(person.personId);
    if (!assignment?.active) return { ...base, personId: person.personId, outcome: "refused_switched_off" };
    return { ...base, personId: person.personId, outcome: "granted" };
  }

  // Anything else that tries to make a session must be a Microsoft sign-in.
  if (!microsoft || !input.expectedTenantId || !input.expectedClientId) {
    return { ...base, outcome: "refused_other", removeAuthRows: Boolean(microsoft) };
  }
  const expectedTenantId: string = input.expectedTenantId;

  // 2. The tenant, again, then the audience.
  // GUIDs compare case-insensitively: a tenant id typed in capitals must not lock everyone out.
  const claims = microsoft.idToken ? claimsFromIdToken(microsoft.idToken) : null;
  const tenantIdSeen = claims?.tid?.toLowerCase() ?? null;
  const seen: Omit<GateDecision, "outcome"> = { ...base, tenantIdSeen, objectIdSeen: microsoft.objectId, removeAuthRows: true };
  if (!claims || tenantIdSeen === null || tenantIdSeen !== expectedTenantId.toLowerCase()) return { ...seen, outcome: "refused_wrong_tenant" };
  const clientId = input.expectedClientId.toLowerCase();
  if (!claims.aud.some((a) => a.toLowerCase() === clientId)) {
    return { ...seen, outcome: "refused_wrong_tenant", tokenRefusal: "wrong_audience" };
  }
  const tenantId: string = tenantIdSeen;
  let grantNote: GrantNote | undefined;

  // 3. Identity by object id; email only to make the first binding.
  let personId = (await look.personByIdentity(tenantId, microsoft.objectId))?.personId ?? null;
  if (!personId) {
    if (!email) return { ...seen, outcome: "refused_not_on_the_list" };
    const byEmail = await look.personByEmail(email);
    if (!byEmail) {
      if (input.joinMode !== "group") return { ...seen, outcome: "refused_not_on_the_list" };
      if (!input.allowGuests && !emailOnDomains(email, input.orgEmailDomains)) {
        return { ...seen, outcome: "refused_not_on_the_list", joinRefusal: "outside_org_domains" };
      }
      // Microsoft let them through, so they hold an assignment on this app: the sign-in group, or, with
      // ROLE_SOURCE=entra, the administrators group, which also carries an assignment (the tenant setup puts
      // that group under the same Conditional Access policy). Either way, add them as a member.
      const displayName = (await look.nameFor(input.userId))?.trim() || email;
      const joined = await look.joinPerson({ email, displayName, tenantId, objectId: microsoft.objectId });
      if (joined) {
        personId = joined.personId;
        grantNote = "joined_from_group";
      } else {
        // Another sign-in added this address or bound this identity a moment ago.
        const again = await look.personByIdentity(tenantId, microsoft.objectId);
        if (!again) return { ...seen, outcome: "refused_identity_mismatch" };
        personId = again.personId;
      }
    } else {
      if (byEmail.boundObjectId && byEmail.boundObjectId !== microsoft.objectId) {
        return { ...seen, personId: byEmail.personId, outcome: "refused_identity_mismatch" };
      }
      if (!byEmail.boundObjectId) {
        const bound = await look.bindIdentity(byEmail.personId, tenantId, microsoft.objectId);
        if (!bound) {
          // Someone else's sign-in bound this person or this identity a moment ago.
          const again = await look.personByIdentity(tenantId, microsoft.objectId);
          if (again?.personId !== byEmail.personId) {
            return { ...seen, personId: byEmail.personId, outcome: "refused_identity_mismatch" };
          }
        }
      }
      personId = byEmail.personId;
    }
  }

  // 4. Switched on?
  const assignment = await look.latestAssignment(personId);
  if (!assignment?.active) return { ...seen, personId, outcome: "refused_switched_off" };

  // 5. The role from Entra, when the site takes it from there.
  if (input.roleSource === "entra") {
    const role = roleFromEntraRoles(claims.roles);
    if (role !== assignment.role) {
      await look.setRoleFromEntra(personId, role);
      grantNote ??= "role_from_entra";
    }
  }
  return { ...seen, personId, outcome: "granted", removeAuthRows: false, ...(grantNote ? { grantNote } : {}) };
}
