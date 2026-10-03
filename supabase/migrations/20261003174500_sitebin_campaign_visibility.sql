-- Campaigns are an advertiser-owned resource. Viewers receive target URLs through request_view_session instead of a broad campaign list.

DROP POLICY IF EXISTS campaigns_select_own_or_active ON public.campaigns;
DROP POLICY IF EXISTS campaigns_select_own_or_active_authenticated ON public.campaigns;

CREATE POLICY campaigns_select_own_authenticated
ON public.campaigns
FOR SELECT
TO authenticated
USING (owner_id = (select auth.uid()));
