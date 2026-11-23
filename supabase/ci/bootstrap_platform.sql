\set ON_ERROR_STOP on
-- The original production database had this platform event trigger before the
-- first SiteBin migration, but it was never recorded in the repository.
-- Install the exact versioned definition before replaying historical migrations.
\ir ../migrations/20261123070300_sitebin_rls_auto_enable_event_trigger.sql
