-- Fix Welcome Bonus false negatives caused by optional App Set ID.
-- Valid Android ID + installation-key evidence remains sufficient for the
-- one-time 300-coin grant. App Set ID is advisory/secondary only.

BEGIN;

    IF p_app_set_id IS NOT NULL THEN
        v_app_set_id := NULLIF(pg_catalog.lower(pg_catalog.btrim(p_app_set_id)), '');
        IF v_app_set_id IS NULL
           OR v_app_set_id !~
              '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
            -- App Set ID is optional/secondary evidence. A malformed or
            -- unavailable value must not invalidate valid Android ID +
            -- installation-key evidence.
            v_app_set_id := NULL;
        END IF;
    END IF;



COMMIT;
