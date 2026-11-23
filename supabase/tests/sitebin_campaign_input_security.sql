-- Real PostgreSQL integration checks for campaign input hardening.
-- All mutations are rolled back.

BEGIN;

DO $$
DECLARE
  v_uid uuid;
  v_result json;
  v_before bigint;
  v_after bigint;
  v_token text := 'sitebin-input-security-token-20261123-abcdefghijklmnopqrstuvwxyz';
  v_token_hash text;
BEGIN
  IF has_function_privilege('anon','public.create_campaign(text,text,text,integer,integer,text)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: anonymous execution is still granted';
  END IF;

  IF has_function_privilege('authenticated','public.create_campaign(text,text,text,integer,integer,text)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: legacy 6-arg create_campaign remains executable';
  END IF;

  IF NOT has_function_privilege('authenticated','public.create_campaign(text,text,text,integer,integer,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated 7-arg preflight create_campaign execution is missing';
  END IF;

  SELECT id, available_coins
    INTO v_uid, v_before
  FROM public.profiles
  ORDER BY available_coins DESC
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'TEST_SETUP_FAILED: no profile';
  END IF;

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub',v_uid::text,'role','authenticated','is_anonymous',false)::text,
    true
  );

  BEGIN
    PERFORM public.create_campaign(
      'https://example.com/',
      'https://example.com/',
      'example.com',
      5,
      1,
      repeat('A',26),
      NULL
    );
    RAISE EXCEPTION 'TEST_FAILED: 26-character keyword accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF position('INVALID_KEYWORD:' IN SQLERRM) <> 1 THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM public.create_campaign(
      'https://2130706433/',
      'https://2130706433/',
      '2130706433',
      5,
      1,
      NULL,
      NULL
    );
    RAISE EXCEPTION 'TEST_FAILED: decimal IP obfuscation accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF position('INVALID_URL:' IN SQLERRM) <> 1 THEN RAISE; END IF;
  END;

  v_token_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
  INSERT INTO private.campaign_preflight_tokens (
    token_hash, user_id, source_url, normalized_url, domain, final_url,
    http_status, redirect_count, response_ms, content_type, content_length,
    viewer_compatibility, quality_score, diagnostics, created_at, expires_at
  ) VALUES (
    v_token_hash, v_uid,
    'https://example.com/', 'https://example.com/', 'example.com', 'https://example.com/',
    200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
    jsonb_build_object('referral_site_key', 'example.com'),
    clock_timestamp(), clock_timestamp() + interval '10 minutes'
  );

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

  IF v_after <> v_before - 15 THEN
    RAISE EXCEPTION 'TEST_FAILED: keyword campaign cost mismatch';
  END IF;

  RAISE NOTICE 'CAMPAIGN_INPUT_SECURITY_TEST_PASS';
END;
$$;

ROLLBACK;
