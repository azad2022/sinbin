-- SiteBin defense-in-depth campaign destination validation.
-- Protect the authoritative campaigns table even if a future write path bypasses RPC-level validation.

CREATE OR REPLACE FUNCTION public.validate_campaign_destination()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_url text;
    v_authority text;
    v_host text;
    v_port_text text;
    v_ip inet;
    v_parts text[];
BEGIN
    v_url := trim(NEW.url);

    IF v_url IS NULL OR length(v_url) = 0
       OR length(v_url) > 2048
       OR v_url !~* '^https://'
       OR v_url ~ '[[:space:]]'
       OR position('@' in v_url) > 0
       OR position('[' in v_url) > 0
       OR position(']' in v_url) > 0 THEN
        RAISE EXCEPTION 'INVALID_URL: Campaign destination must be an HTTPS public URL';
    END IF;

    v_authority := substring(v_url FROM '^https://([^/?#]+)');
    IF v_authority IS NULL OR length(v_authority) = 0 THEN
        RAISE EXCEPTION 'INVALID_URL: Campaign destination host is missing';
    END IF;

    IF position(':' in v_authority) > 0 THEN
        IF length(v_authority) - length(replace(v_authority, ':', '')) <> 1 THEN
            RAISE EXCEPTION 'INVALID_URL: Campaign destination contains an invalid host or port';
        END IF;
        v_host := split_part(v_authority, ':', 1);
        v_port_text := split_part(v_authority, ':', 2);
        IF v_port_text !~ '^[0-9]{1,5}$'
           OR (v_port_text)::integer NOT BETWEEN 1 AND 65535 THEN
            RAISE EXCEPTION 'INVALID_URL: Campaign destination contains an invalid port';
        END IF;
    ELSE
        v_host := v_authority;
    END IF;

    v_host := lower(trim(v_host));

    IF v_host IS NULL OR length(v_host) = 0 OR length(v_host) > 253
       OR v_host !~ '^[a-z0-9.-]+$'
       OR v_host LIKE '%.localhost'
       OR v_host LIKE '%.local'
       OR v_host LIKE '%.internal'
       OR v_host IN ('localhost','localhost.localdomain','metadata.google.internal','metadata.google.com') THEN
        RAISE EXCEPTION 'INVALID_URL: Campaign destination host is not an allowed public hostname';
    END IF;

    IF v_host ~* '^0x[0-9a-f]+$' THEN
        RAISE EXCEPTION 'INVALID_URL: Campaign destination uses a non-standard hexadecimal IP representation';
    END IF;

    IF v_host ~ '^[0-9.]+$' THEN
        v_parts := string_to_array(v_host, '.');
        IF array_length(v_parts, 1) <> 4
           OR EXISTS (
               SELECT 1
               FROM unnest(v_parts) AS octet(value)
               WHERE value = '' OR value::integer NOT BETWEEN 0 AND 255
           ) THEN
            RAISE EXCEPTION 'INVALID_URL: Campaign destination uses a non-standard numeric IP representation';
        END IF;

        v_ip := v_host::inet;
        IF v_ip <<= inet '0.0.0.0/8'
           OR v_ip <<= inet '10.0.0.0/8'
           OR v_ip <<= inet '100.64.0.0/10'
           OR v_ip <<= inet '127.0.0.0/8'
           OR v_ip <<= inet '169.254.0.0/16'
           OR v_ip <<= inet '172.16.0.0/12'
           OR v_ip <<= inet '192.0.0.0/24'
           OR v_ip <<= inet '192.168.0.0/16'
           OR v_ip <<= inet '198.18.0.0/15'
           OR v_ip <<= inet '198.51.100.0/24'
           OR v_ip <<= inet '203.0.113.0/24'
           OR v_ip <<= inet '224.0.0.0/4'
           OR v_ip = inet '255.255.255.255' THEN
            RAISE EXCEPTION 'INVALID_URL: Campaign destination IP is private, reserved, multicast, or otherwise non-public';
        END IF;
    END IF;

    NEW.domain := v_host;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_campaign_destination ON public.campaigns;

CREATE TRIGGER trg_validate_campaign_destination
BEFORE INSERT OR UPDATE OF url, domain
ON public.campaigns
FOR EACH ROW
EXECUTE FUNCTION public.validate_campaign_destination();

REVOKE ALL ON FUNCTION public.validate_campaign_destination() FROM PUBLIC, anon, authenticated;
