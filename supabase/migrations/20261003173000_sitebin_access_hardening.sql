-- SiteBin access hardening: clients may read only data explicitly allowed by RLS; financial writes remain RPC-only.

REVOKE ALL ON TABLE
  public.duration_pricing,
  public.profiles,
  public.welcome_bonus_grants,
  public.campaigns,
  public.view_sessions,
  public.coin_ledger
FROM anon, authenticated;

GRANT SELECT ON public.duration_pricing TO anon, authenticated;
GRANT SELECT ON public.profiles TO authenticated;
GRANT SELECT ON public.welcome_bonus_grants TO authenticated;
GRANT SELECT ON public.campaigns TO authenticated;
GRANT SELECT ON public.view_sessions TO authenticated;
GRANT SELECT ON public.coin_ledger TO authenticated;
