-- Real PostgreSQL integration checks for campaign input hardening.
-- All mutations are rolled back.

BEGIN;

DO $$
DECLARE
  v_uid uuid;
  v_result json;
  v_before bigint;
  v_after bigint;
BEGIN
  IF has_function_privilege('anon','public.create_campaign(text,text,text,integer,integer,text)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: anonymous execution is still granted';
  END IF;

  IF NOT has_function_privilege('authenticated','public.create_campaign(text,text,text,integer,integer,text)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated execution is missing';
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
      repeat('A',26)
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
      NULL
    );
    RAISE EXCEPTION 'TEST_FAILED: decimal IP obfuscation accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF position('INVALID_URL:' IN SQLERRM) <> 1 THEN RAISE; END IF;
  END;

  SELECT public.create_campaign(
    'https://example.com/',
    'https://example.com/',
    'example.com',
    5,
    1,
    'safe'' OR 1=1 --'
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
