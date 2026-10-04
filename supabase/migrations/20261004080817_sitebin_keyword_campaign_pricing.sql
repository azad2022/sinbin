-- SiteBin: optional keyword campaigns with server-authoritative premium pricing.
-- Keyword is optional. NULL means a normal direct-visit campaign.
-- Premium keyword prices are 3x the normal advertiser per-view prices.

BEGIN;

ALTER TABLE public.duration_pricing ADD COLUMN IF NOT EXISTS keyword_advertiser_cost BIGINT;
UPDATE public.duration_pricing
SET keyword_advertiser_cost = CASE duration_seconds
  WHEN 5 THEN 15 WHEN 10 THEN 27 WHEN 15 THEN 42 WHEN 30 THEN 78 WHEN 60 THEN 150
  ELSE advertiser_cost * 3 END
WHERE keyword_advertiser_cost IS NULL OR keyword_advertiser_cost <= 0;
ALTER TABLE public.duration_pricing ALTER COLUMN keyword_advertiser_cost SET NOT NULL;
ALTER TABLE public.duration_pricing DROP CONSTRAINT IF EXISTS duration_pricing_keyword_advertiser_cost_check;
ALTER TABLE public.duration_pricing ADD CONSTRAINT duration_pricing_keyword_advertiser_cost_check CHECK (keyword_advertiser_cost > 0 AND keyword_advertiser_cost >= advertiser_cost);

ALTER TABLE public.campaigns ADD COLUMN IF NOT EXISTS keyword TEXT;
ALTER TABLE public.campaigns DROP CONSTRAINT IF EXISTS campaigns_keyword_check;
ALTER TABLE public.campaigns ADD CONSTRAINT campaigns_keyword_check CHECK (keyword IS NULL OR (pg_catalog.length(pg_catalog.btrim(keyword)) BETWEEN 1 AND 128 AND keyword !~ '[[:cntrl:]]'));

ALTER TABLE public.view_sessions ADD COLUMN IF NOT EXISTS keyword TEXT;
ALTER TABLE public.view_sessions DROP CONSTRAINT IF EXISTS view_sessions_keyword_check;
ALTER TABLE public.view_sessions ADD CONSTRAINT view_sessions_keyword_check CHECK (keyword IS NULL OR (pg_catalog.length(pg_catalog.btrim(keyword)) BETWEEN 1 AND 128 AND keyword !~ '[[:cntrl:]]'));

CREATE OR REPLACE FUNCTION public.create_campaign(p_url TEXT,p_normalized_url TEXT,p_domain TEXT,p_duration_seconds INTEGER,p_target_views INTEGER,p_keyword TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid UUID := (select auth.uid()); v_price RECORD; v_profile RECORD; v_new_campaign RECORD;
  v_clean_url TEXT; v_clean_normalized TEXT; v_clean_domain TEXT; v_clean_keyword TEXT;
  v_total_cost BIGINT; v_authority TEXT; v_host TEXT; v_port_text TEXT; v_ip INET; v_advertiser_cost BIGINT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required'; END IF;
  IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed'; END IF;
  v_clean_url := trim(p_url); v_clean_normalized := trim(p_normalized_url); v_clean_keyword := NULLIF(pg_catalog.btrim(p_keyword), '');
  IF v_clean_url IS NULL OR pg_catalog.length(v_clean_url)=0 OR pg_catalog.length(v_clean_url)>2048 OR v_clean_url !~* '^https://' OR v_clean_url ~ '[[:space:]]' OR position('@' in v_clean_url)>0 OR position('[' in v_clean_url)>0 OR position(']' in v_clean_url)>0 THEN RAISE EXCEPTION 'INVALID_URL: Target URL must be an HTTPS address without userinfo, IPv6 literals, or whitespace, up to 2048 characters'; END IF;
  v_authority := substring(v_clean_url FROM '^https://([^/?#]+)');
  IF v_authority IS NULL OR pg_catalog.length(v_authority)=0 THEN RAISE EXCEPTION 'INVALID_URL: Target URL host is missing'; END IF;
  IF (pg_catalog.length(v_authority)-pg_catalog.length(replace(v_authority,':','')))>1 THEN RAISE EXCEPTION 'INVALID_URL: Target URL contains an invalid host or port'; END IF;
  IF position(':' in v_authority)>0 THEN v_host:=split_part(v_authority,':',1); v_port_text:=split_part(v_authority,':',2); IF v_port_text !~ '^[0-9]{1,5}$' OR (v_port_text)::integer NOT BETWEEN 1 AND 65535 THEN RAISE EXCEPTION 'INVALID_URL: Target URL contains an invalid port'; END IF; ELSE v_host:=v_authority; END IF;
  v_host:=lower(trim(v_host));
  IF v_host IS NULL OR pg_catalog.length(v_host)=0 OR pg_catalog.length(v_host)>253 OR v_host !~ '^[a-z0-9.-]+$' OR v_host LIKE '%.localhost' OR v_host LIKE '%.local' OR v_host LIKE '%.internal' OR v_host IN ('localhost','localhost.localdomain','metadata.google.internal','metadata.google.com') THEN RAISE EXCEPTION 'INVALID_URL: Target host is not an allowed public hostname'; END IF;
  IF v_host ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' THEN
    IF EXISTS (SELECT 1 FROM unnest(string_to_array(v_host,'.')) AS octet(value) WHERE octet.value::integer NOT BETWEEN 0 AND 255) THEN RAISE EXCEPTION 'INVALID_URL: Target IPv4 address is invalid'; END IF;
    v_ip:=v_host::inet;
    IF v_ip <<= inet '0.0.0.0/8' OR v_ip <<= inet '10.0.0.0/8' OR v_ip <<= inet '100.64.0.0/10' OR v_ip <<= inet '127.0.0.0/8' OR v_ip <<= inet '169.254.0.0/16' OR v_ip <<= inet '172.16.0.0/12' OR v_ip <<= inet '192.0.0.0/24' OR v_ip <<= inet '192.168.0.0/16' OR v_ip <<= inet '198.18.0.0/15' OR v_ip <<= inet '198.51.100.0/24' OR v_ip <<= inet '203.0.113.0/24' OR v_ip <<= inet '224.0.0.0/4' OR v_ip=inet '255.255.255.255' THEN RAISE EXCEPTION 'INVALID_URL: Target IPv4 address is private, reserved, multicast, or otherwise non-public'; END IF;
  END IF;
  v_clean_domain:=v_host;
  IF v_clean_normalized IS NULL OR pg_catalog.length(v_clean_normalized)=0 OR pg_catalog.length(v_clean_normalized)>2048 THEN RAISE EXCEPTION 'INVALID_NORMALIZED_URL: Normalized URL cannot be empty'; END IF;
  IF v_clean_keyword IS NOT NULL AND (pg_catalog.length(v_clean_keyword)>128 OR v_clean_keyword ~ '[[:cntrl:]]') THEN RAISE EXCEPTION 'INVALID_KEYWORD: Keyword must be between 1 and 128 characters and cannot contain control characters'; END IF;
  IF p_target_views<=0 OR p_target_views>1000000 THEN RAISE EXCEPTION 'INVALID_TARGET_VIEWS: Target views must be between 1 and 1,000,000'; END IF;
  SELECT * INTO v_price FROM public.duration_pricing WHERE duration_seconds=p_duration_seconds;
  IF v_price IS NULL THEN RAISE EXCEPTION 'INVALID_DURATION: Unsupported duration option'; END IF;
  v_advertiser_cost:=CASE WHEN v_clean_keyword IS NULL THEN v_price.advertiser_cost ELSE v_price.keyword_advertiser_cost END;
  v_total_cost:=v_advertiser_cost*p_target_views;
  SELECT * INTO v_profile FROM public.profiles WHERE id=v_uid FOR UPDATE;
  IF v_profile IS NULL THEN RAISE EXCEPTION 'PROFILE_NOT_FOUND: User profile does not exist'; END IF;
  IF v_profile.available_coins<v_total_cost THEN RAISE EXCEPTION 'INSUFFICIENT_BALANCE: Available balance (%) coins is less than required budget (%) coins',v_profile.available_coins,v_total_cost; END IF;
  UPDATE public.profiles SET available_coins=available_coins-v_total_cost,reserved_coins=reserved_coins+v_total_cost,updated_at=pg_catalog.clock_timestamp() WHERE id=v_uid;
  INSERT INTO public.campaigns(owner_id,url,normalized_url,domain,keyword,duration_seconds,target_views,completed_views,cost_per_view,total_budget,spent_budget,reserved_budget,status,created_at,updated_at) VALUES(v_uid,v_clean_url,v_clean_normalized,v_clean_domain,v_clean_keyword,p_duration_seconds,p_target_views,0,v_advertiser_cost,v_total_cost,0,v_total_cost,'ACTIVE',pg_catalog.clock_timestamp(),pg_catalog.clock_timestamp()) RETURNING * INTO v_new_campaign;
  INSERT INTO public.coin_ledger(user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at) VALUES(v_uid,-v_total_cost,'CAMPAIGN_RESERVATION',CASE WHEN v_clean_keyword IS NULL THEN 'رزرو بودجه برای سفارش '||p_target_views||' بازدید از '||v_clean_domain ELSE 'رزرو بودجه برای سفارش '||p_target_views||' بازدید از '||v_clean_domain||' با کلمه کلیدی «'||v_clean_keyword||'»' END,v_new_campaign.id::text,'camp_res_'||v_new_campaign.id::text,pg_catalog.clock_timestamp());
  RETURN pg_catalog.row_to_json(v_new_campaign);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_campaign(p_url TEXT,p_normalized_url TEXT,p_domain TEXT,p_duration_seconds INTEGER,p_target_views INTEGER)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN RETURN public.create_campaign(p_url,p_normalized_url,p_domain,p_duration_seconds,p_target_views,NULL); END;
$function$;

CREATE OR REPLACE FUNCTION public.request_view_session()
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid UUID := (select auth.uid()); v_campaign RECORD; v_price RECORD; v_existing_active RECORD; v_new_session RECORD;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required'; END IF;
  IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean),false) THEN RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('view_session_req_'||v_uid::text));
  SELECT vs.*,c.url,c.domain,c.keyword INTO v_existing_active FROM public.view_sessions vs JOIN public.campaigns c ON c.id=vs.campaign_id WHERE vs.viewer_id=v_uid AND vs.status IN('INITIALIZED','CONTENT_READY') ORDER BY vs.started_at DESC LIMIT 1;
  IF v_existing_active IS NOT NULL THEN
    IF v_existing_active.started_at>(pg_catalog.clock_timestamp()-INTERVAL '3 minutes') THEN
      RETURN pg_catalog.json_build_object('id',v_existing_active.id,'campaign_id',v_existing_active.campaign_id,'target_url',v_existing_active.url,'domain',v_existing_active.domain,'keyword',v_existing_active.keyword,'required_duration_seconds',v_existing_active.required_duration_seconds,'reward_coins',v_existing_active.reward_coins,'started_at',extract(epoch from v_existing_active.started_at)*1000);
    ELSE UPDATE public.view_sessions SET status='EXPIRED' WHERE id=v_existing_active.id; END IF;
  END IF;
  SELECT c.* INTO v_campaign FROM public.campaigns c WHERE c.status='ACTIVE' AND c.owner_id<>v_uid AND c.completed_views<c.target_views AND c.reserved_budget>=c.cost_per_view AND NOT EXISTS(SELECT 1 FROM public.view_sessions vs WHERE vs.campaign_id=c.id AND vs.viewer_id=v_uid AND vs.status='COMPLETED' AND vs.completed_at>(pg_catalog.clock_timestamp()-INTERVAL '15 minutes')) ORDER BY c.created_at ASC FOR UPDATE SKIP LOCKED LIMIT 1;
  IF v_campaign IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_price FROM public.duration_pricing WHERE duration_seconds=v_campaign.duration_seconds;
  INSERT INTO public.view_sessions(campaign_id,viewer_id,keyword,required_duration_seconds,reward_coins,status,started_at,created_at) VALUES(v_campaign.id,v_uid,v_campaign.keyword,v_campaign.duration_seconds,v_price.viewer_reward,'INITIALIZED',pg_catalog.clock_timestamp(),pg_catalog.clock_timestamp()) RETURNING * INTO v_new_session;
  RETURN pg_catalog.json_build_object('id',v_new_session.id,'campaign_id',v_campaign.id,'target_url',v_campaign.url,'domain',v_campaign.domain,'keyword',v_new_session.keyword,'required_duration_seconds',v_new_session.required_duration_seconds,'reward_coins',v_new_session.reward_coins,'started_at',extract(epoch from v_new_session.started_at)*1000);
END;
$function$;

COMMIT;