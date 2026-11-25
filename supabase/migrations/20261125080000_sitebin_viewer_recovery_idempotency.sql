-- SiteBin Viewer recovery hardening.
-- Content Ready and cancellation are idempotent so a lost HTTP response can be retried
-- without losing or duplicating a server-authoritative viewing session.

CREATE OR REPLACE FUNCTION public.signal_content_ready(p_session_id UUID)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_uid UUID := (select auth.uid());
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ARGUMENT: Session ID cannot be null';
    END IF;

    UPDATE public.view_sessions
    SET content_ready_at = COALESCE(content_ready_at, pg_catalog.clock_timestamp()),
        status = 'CONTENT_READY'
    WHERE id = p_session_id
      AND viewer_id = v_uid
      AND status IN ('INITIALIZED', 'CONTENT_READY');

    RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_view_session(p_session_id UUID)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_uid UUID := (select auth.uid());
    v_status TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ARGUMENT: Session ID cannot be null';
    END IF;

    SELECT status
    INTO v_status
    FROM public.view_sessions
    WHERE id = p_session_id
      AND viewer_id = v_uid
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Repeated cancellation is successful and never mutates a completed session.
    IF v_status IN ('CANCELLED', 'EXPIRED') THEN
        RETURN TRUE;
    END IF;

    IF v_status NOT IN ('INITIALIZED', 'CONTENT_READY') THEN
        RETURN FALSE;
    END IF;

    UPDATE public.view_sessions
    SET status = 'CANCELLED'
    WHERE id = p_session_id
      AND viewer_id = v_uid
      AND status IN ('INITIALIZED', 'CONTENT_READY');

    RETURN FOUND;
END;
$function$;

REVOKE ALL ON FUNCTION public.signal_content_ready(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.signal_content_ready(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.cancel_view_session(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_view_session(UUID) TO authenticated;
