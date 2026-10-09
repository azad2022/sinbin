BEGIN;

-- Supports counting website sessions issued to a viewer in the current UTC week.
CREATE INDEX IF NOT EXISTS idx_view_sessions_viewer_started_at
  ON public.view_sessions (viewer_id, started_at DESC);

COMMIT;
