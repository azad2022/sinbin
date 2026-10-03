-- Corrective migration for the original permissive campaign visibility policy.
DROP POLICY IF EXISTS "Users read own or active campaigns" ON public.campaigns;
