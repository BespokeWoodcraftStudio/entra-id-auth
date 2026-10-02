/**
 * Who may use the site, and every sign-in. The site's own list, the second
 * door after Microsoft's.
 *
 * All four tables are append-only: the database refuses UPDATE, DELETE and
 * TRUNCATE on them (drizzle/access_append_only.sql). A change is a new row;
 * the newest row wins. That keeps who had access, when, and who changed it.
 *
 * Identity is the Entra object id plus tenant id (`person_identities`), never
 * the email address, which an administrator can change (control C5). Email is
 * how a person is first matched, once, and then display only.
 */
import { sql } from "drizzle-orm";
import { boolean, index, pgEnum, pgTable, text, timestamp, uniqueIndex, uuid } from "drizzle-orm/pg-core";

/** Add roles here if the site needs more. The gate only cares about `active`. */
export const personRoleEnum = pgEnum("person_role", ["administrator", "member"]);

export const signInOutcomeEnum = pgEnum("sign_in_outcome", [
  "granted",
  "refused_wrong_tenant",
  "refused_not_on_the_list",
  "refused_switched_off",
  "refused_identity_mismatch",
  "refused_password_not_allowed_here",
  "refused_session_expired",
  "refused_other",
]);

/** One row per person, written once. Nothing here is ever edited. */
export const people = pgTable(
  "people",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    /** The work address first used to match the person. Display only after that. */
    email: text("email").notNull(),
    displayName: text("display_name").notNull(),
    addedByPersonId: uuid("added_by_person_id"),
    addedAt: timestamp("added_at", { withTimezone: true }).notNull().defaultNow(),
    note: text("note"),
  },
  (t) => [uniqueIndex("people_email_unique").on(sql`lower(${t.email})`)],
);

/**
 * The stable identity: Entra `tid` + `oid`. Bound at first sign-in (when the
 * email and tenant match a listed person who has no binding yet), or at the
 * moment an administrator adds the person with their object id. One binding
 * per person and per identity; never changed.
 */
export const personIdentities = pgTable(
  "person_identities",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    personId: uuid("person_id")
      .notNull()
      .references(() => people.id),
    tenantId: text("tenant_id").notNull(),
    objectId: text("object_id").notNull(),
    boundAt: timestamp("bound_at", { withTimezone: true }).notNull().defaultNow(),
    /** "first sign-in" or "added with object id". */
    boundBy: text("bound_by").notNull(),
  },
  (t) => [
    uniqueIndex("person_identities_identity_unique").on(t.tenantId, t.objectId),
    uniqueIndex("person_identities_person_unique").on(t.personId),
  ],
);

/** Append-only. A person's newest row is their current role and on/off state. */
export const personAssignments = pgTable(
  "person_assignments",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    personId: uuid("person_id")
      .notNull()
      .references(() => people.id),
    role: personRoleEnum("role").notNull(),
    active: boolean("active").notNull(),
    /**
     * Who made the change. Null for a row no person on the list made: the
     * first administrator, a seeded person, a person who joined at first
     * sign-in, or a role set by the Entra app role; the note says which.
     */
    setByPersonId: uuid("set_by_person_id").references(() => people.id),
    setAt: timestamp("set_at", { withTimezone: true }).notNull().defaultNow(),
    note: text("note"),
  },
  (t) => [index("person_assignments_person_idx").on(t.personId, t.setAt)],
);

/** Every decided sign-in and every failed attempt, refused ones included. */
export const signInEvents = pgTable(
  "sign_in_events",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    at: timestamp("at", { withTimezone: true }).notNull().defaultNow(),
    /** The address that tried. Staff, or a stranger. */
    emailAttempted: text("email_attempted"),
    tenantIdSeen: text("tenant_id_seen"),
    objectIdSeen: text("object_id_seen"),
    outcome: signInOutcomeEnum("outcome").notNull(),
    /** A fixed code (a Better Auth error code, a refusal reason). Never provider text. */
    detail: text("detail"),
    /** Which endpoint, as Better Auth's route pattern: "/callback/:id", "/sign-in/email" and so on. */
    path: text("path"),
    personId: uuid("person_id").references(() => people.id),
    ipAddress: text("ip_address"),
    userAgent: text("user_agent"),
  },
  (t) => [index("sign_in_events_at_idx").on(t.at), index("sign_in_events_person_idx").on(t.personId, t.at)],
);
