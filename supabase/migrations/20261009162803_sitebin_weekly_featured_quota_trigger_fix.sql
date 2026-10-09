BEGIN;

CREATE OR REPLACE FUNCTION private.record_weekly_featured_campaign_quota()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.leaderboard_feature_week IS NOT NULL
       AND OLD.leaderboard_feature_owner_id IS NOT NULL
       AND OLD.status IN ('INITIALIZED', 'CONTENT_READY') THEN
      UPDATE private.weekly_featured_campaign_quota q
      SET reserved_views = GREATEST(q.reserved_views - 1, 0),
          updated_at = pg_catalog.clock_timestamp()
      WHERE q.week_start = OLD.leaderboard_feature_week
        AND q.owner_id = OLD.leaderboard_feature_owner_id;
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.leaderboard_feature_week IS NOT NULL
     AND OLD.leaderboard_feature_owner_id IS NOT NULL
     AND OLD.status IN ('INITIALIZED', 'CONTENT_READY')
     AND NEW.status NOT IN ('INITIALIZED', 'CONTENT_READY') THEN
    UPDATE private.weekly_featured_campaign_quota q
    SET reserved_views = GREATEST(q.reserved_views - 1, 0),
        completed_views = q.completed_views
          + CASE WHEN NEW.status = 'COMPLETED' THEN 1 ELSE 0 END,
        updated_at = pg_catalog.clock_timestamp()
    WHERE q.week_start = OLD.leaderboard_feature_week
      AND q.owner_id = OLD.leaderboard_feature_owner_id;
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.record_weekly_featured_campaign_quota()
  FROM PUBLIC, anon, authenticated;

COMMIT;
