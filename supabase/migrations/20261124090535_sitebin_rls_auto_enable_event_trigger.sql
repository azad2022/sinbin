BEGIN;

-- The live SiteBin database has this event-trigger helper installed outside the
-- original migration history. Record the exact live behavior as a forward-only
-- migration so new databases and fresh local replays get the same RLS default.
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'pg_catalog'
AS $function$
DECLARE
    cmd record;
BEGIN
    FOR cmd IN
        SELECT *
        FROM pg_catalog.pg_event_trigger_ddl_commands()
        WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
          AND object_type IN ('table', 'partitioned table')
    LOOP
        IF cmd.schema_name IS NOT NULL
           AND cmd.schema_name = 'public'
           AND cmd.schema_name NOT IN ('pg_catalog', 'information_schema')
           AND cmd.schema_name NOT LIKE 'pg_toast%'
           AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
            BEGIN
                EXECUTE pg_catalog.format(
                    'ALTER TABLE IF EXISTS %s ENABLE ROW LEVEL SECURITY',
                    cmd.object_identity
                );
                RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
            EXCEPTION
                WHEN OTHERS THEN
                    RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
            END;
        ELSE
            RAISE LOG
                'rls_auto_enable: skip % (either system schema or not in enforced list: %.)',
                cmd.object_identity,
                cmd.schema_name;
        END IF;
    END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;

-- Replace the manually provisioned event trigger atomically. Its function is
-- deliberately restricted to public tables and only enables RLS; it never
-- creates policies or grants access.
DROP EVENT TRIGGER IF EXISTS ensure_rls;

CREATE EVENT TRIGGER ensure_rls
ON ddl_command_end
WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
EXECUTE FUNCTION public.rls_auto_enable();

COMMENT ON FUNCTION public.rls_auto_enable() IS
    'Enables RLS on newly created public tables. Mirrors the pre-existing SiteBin production event trigger and grants no data access.';

COMMIT;
