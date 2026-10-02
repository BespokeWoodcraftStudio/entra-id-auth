-- The site's access record is append-only, in the database itself.
--
-- people, person_identities, person_assignments and sign_in_events refuse
-- UPDATE, DELETE and TRUNCATE. A change is a new row; the newest row wins.
-- Better Auth's own tables (user, session, account, verification, rate_limit)
-- are not touched: they hold sign-in state and the library updates them.
--
-- How to add it: npx drizzle-kit generate --custom --name access_append_only
-- then paste this file into the empty migration drizzle-kit made, after the
-- migration that creates the four tables. Then npx drizzle-kit migrate.

CREATE OR REPLACE FUNCTION access_refuse_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'Table % is append-only. Write a new row instead.', TG_TABLE_NAME
    USING ERRCODE = 'check_violation';
END;
$$;
--> statement-breakpoint

-- Each trigger is dropped only when it is there, so a first migrate prints
-- no "does not exist, skipping" notices, and a second run replaces them.
DO $$
DECLARE
  t text;
  trig text;
BEGIN
  FOREACH t IN ARRAY ARRAY['people', 'person_identities', 'person_assignments', 'sign_in_events']
  LOOP
    FOREACH trig IN ARRAY ARRAY['access_append_only_' || t, 'access_no_truncate_' || t]
    LOOP
      IF EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = trig AND tgrelid = format('public.%I', t)::regclass AND NOT tgisinternal
      ) THEN
        EXECUTE format('DROP TRIGGER %I ON public.%I', trig, t);
      END IF;
    END LOOP;
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION access_refuse_change()',
      'access_append_only_' || t, t
    );
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION access_refuse_change()',
      'access_no_truncate_' || t, t
    );
  END LOOP;
END;
$$;
