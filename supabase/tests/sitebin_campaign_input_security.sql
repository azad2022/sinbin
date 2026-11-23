-- Real PostgreSQL integration checks for campaign input hardening.
-- This test owns its fixture and rolls every mutation back.

BEGIN;

DO $$
DECLARE
  v_tag text := substr(md5(clock_timestamp()::text || random()::text), 1, 10);
  v_uid uuid := gen_random_uuid();
  v_result json;
  v_before bigint;
  v_after bigint;
  v_token text := 'sitebin-input-security-token-' || substr(md5(clock_timestamp()::text),1,24);
  v_token_hash text;
  v_keyword_token text := 'sitebin-input-keyword-' || substr(md5(clock_timestamp()::text || random()::text),1,24);
  v_keyword_token_hash text;
  v_ip_token text := 'sitebin-input-ip-' || substr(md5(clock_timestamp()::text || random()::text),1,24);
  v_ip_token_hash text;
BEGIN
  INSERT INTO auth.users(
    id, aud, role, email, email_confirmed_at,
    created_at, updated_at, is_sso_user, is_anonymous
  )
  VALUES(
    v_uid, 'authenticated', 'authenticated',
    'sitebin_input_' || v_tag || '@sitebin.internal',
    clock_timestamp(), clock_timestamp(), clock_timestamp(), false, false
  );

  INSERT INTO public.profiles(
    id, user_handle, app_install_id, available_coins, reserved_coins,
    lifetime_earned, lifetime_spent, trust_score, completed_views_count,
    received_views_count, welcome_bonus_claimed, created_at, updated_at
  )
  VALUES(
    v_uid, 's2_input_' || v_tag, 's2_input_inst_' || v_tag,
    1000, 0, 1000, 0, 100, 0, 0, true,
    clock_timestamp(), clock_timestamp()
  );

  IF has_function_privilege('anon','public.create_campaign(text,text,text,integer,integer,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: anonymous execution is still granted';
  END IF;

  IF has_function_privilege('authenticated','public.create_campaign(text,text,text,integer,integer,text)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: legacy 6-arg create_campaign remains executable';
  END IF;

  IF NOT has_function_privilege('authenticated','public.create_campaign(text,text,text,integer,integer,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated 7-arg preflight create_campaign execution is missing';
  END IF;

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub',v_uid::text,'role','authenticated','is_anonymous',false)::text,
    true
  );
  PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);

  v_keyword_token_hash := encode(extensions.digest(v_keyword_token, 'sha256'), 'hex');
  INSERT INTO private.campaign_preflight_tokens(
    token_hash, user_id, source_url, normalized_url, domain, final_url,
    http_status, redirect_count, response_ms, content_type, content_length,
    viewer_compatibility, quality_score, diagnostics, created_at, expires_at
  ) VALUES (
    v_keyword_token_hash, v_uid,
    'https://example.com/', 'https://example.com/', 'example.com', 'https://example.com/',
    200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
    jsonb_build_object('referral_site_key', 'example.com'),
    clock_timestamp(), clock_timestamp() + interval '10 minutes'
  );

  BEGIN
    PERFORM public.create_campaign(
      'https://example.com/',
      'https://example.com/',
      'example.com',
      5,
      1,
      repeat('A',26),
      v_keyword_token
    );
    RAISE EXCEPTION 'TEST_FAILED: 26-character keyword accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF position('INVALID_KEYWORD:' IN SQLERRM) <> 1 THEN RAISE; END IF;
  END;

  v_ip_token_hash := encode(extensions.digest(v_ip_token, 'sha256'), 'hex');
  INSERT INTO private.campaign_preflight_tokens(
    token_hash, user_id, source_url, normalized_url, domain, final_url,
    http_status, redirect_count, response_ms, content_type, content_length,
    viewer_compatibility, quality_score, diagnostics, created_at, expires_at
  ) VALUES (
    v_ip_token_hash, v_uid,
    'https://2130706433/', 'https://2130706433/', '2130706433', 'https://2130706433/',
    200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
    jsonb_build_object('referral_site_key', '2130706433'),
    clock_timestamp(), clock_timestamp() + interval '10 minutes'
  );

  BEGIN
    PERFORM public.create_campaign(
      'https://2130706433/',
      'https://2130706433/',
      '2130706433',
      5,
      1,
      NULL,
      v_ip_token
    );
    RAISE EXCEPTION 'TEST_FAILED: decimal IP obfuscation accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF position('INVALID_URL:' IN SQLERRM) <> 1 THEN RAISE; END IF;
  END;

  v_token_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
  INSERT INTO private.campaign_preflight_tokens(
    token_hash, user_id, source_url, normalized_url, domain, final_url,
    http_status, redirect_count, response_ms, content_type, content_length,
    viewer_compatibility, quality_score, diagnostics, created_at, expires_at
  )
  VALUES(
    v_token_hash, v_uid,
    'https://example.com/', 'https://example.com/', 'example.com', 'https://example.com/',
    200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
    jsonb_build_object('referral_site_key', 'example.com'),
    clock_timestamp(), clock_timestamp() + interval '10 minutes'
  );

  SELECT available_coins INTO v_before
  FROM public.profiles
  WHERE id = v_uid;

  SELECT public.create_campaign(
    'https://example.com/',
    'https://example.com/',
    'example.com',
    5,
    1,
    'safe'' OR 1=1 --',
    v_token
  ) INTO v_result;

  IF v_result IS NULL OR (v_result->>'keyword') <> 'safe'' OR 1=1 --' THEN
    RAISE EXCEPTION 'TEST_FAILED: keyword was not stored as data';
  END IF;

  SELECT available_coins INTO v_after
  FROM public.profiles
  WHERE id=v_uid;

  -- A single 5-second keyword campaign costs 15 coins under current pricing.
  IF v_before - v_after <> 15 THEN
    RAISE EXCEPTION 'TEST_FAILED: keyword campaign cost mismatch';
  END IF;

  RAISE NOTICE 'PASS: campaign keyword/URL validation and preflight token boundary';
END;
$$;

ROLLBACK;
