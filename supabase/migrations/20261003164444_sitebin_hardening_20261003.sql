-- SiteBin hardening: server-side session cancellation, financial invariants, FK indexes and event-trigger privilege cleanup.

CREATE OR REPLACE FUNCTION public.cancel_view_session(p_session_id uuid)
RETURNS boolean
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

  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_ARGUMENT: Session ID cannot be null';
  END IF;

  UPDATE public.view_sessions
  SET status='CANCELLED'
  WHERE id=p_session_id
    AND viewer_id=v_uid
    AND status IN ('INITIALIZED','CONTENT_READY');

  RETURN FOUND;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.cancel_view_session(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.cancel_view_session(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.cancel_view_session(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM anon;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM authenticated;

CREATE INDEX IF NOT EXISTS idx_campaigns_duration_seconds
  ON public.campaigns(duration_seconds);

CREATE INDEX IF NOT EXISTS idx_view_sessions_campaign_id
  ON public.view_sessions(campaign_id);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='campaigns_budget_parts_consistent'
      AND conrelid='public.campaigns'::regclass
  ) THEN
    ALTER TABLE public.campaigns
      ADD CONSTRAINT campaigns_budget_parts_consistent
      CHECK (spent_budget + reserved_budget = total_budget);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='campaigns_views_spend_consistent'
      AND conrelid='public.campaigns'::regclass
  ) THEN
    ALTER TABLE public.campaigns
      ADD CONSTRAINT campaigns_views_spend_consistent
      CHECK ((completed_views::numeric * cost_per_view::numeric) = spent_budget::numeric);
  END IF;
END
$$;
