BEGIN;

-- The preference RPC is idempotent and only updates the authenticated user's
-- own notification rows. A strict 2-per-10-second limit caused ordinary UI
-- permission/toggle retries to return HTTP 429; expensive token registration
-- and referral registration remain rate-limited separately.
CREATE OR REPLACE FUNCTION public.set_referral_push_notifications_enabled(p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
  END IF;

  IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
  END IF;

  UPDATE private.referral_push_tokens
  SET enabled = COALESCE(p_enabled, false),
      updated_at = pg_catalog.clock_timestamp()
  WHERE user_id = v_uid;

  RETURN pg_catalog.jsonb_build_object(
    'success', true,
    'enabled', COALESCE(p_enabled, false)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.set_referral_push_notifications_enabled(boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_referral_push_notifications_enabled(boolean)
  TO authenticated;

COMMIT;
