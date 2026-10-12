import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const FCM_TOKEN_TTL_SECONDS = 3600;
const CLAIM_LEASE_MINUTES = 3;

type OutboxEvent = {
  event_id: string;
  referral_id: string;
  event_type: string;
  actor_id: string;
  recipient_id: string;
  payload: Record<string, unknown>;
  attempt_count: number;
};

type PushToken = { token: string; user_id: string };

let cachedAccessToken: { value: string; expiresAt: number } | null = null;

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function utf8Base64Url(value: string): string {
  return base64Url(new TextEncoder().encode(value));
}

function decodePem(value: string): ArrayBuffer {
  const clean = value.replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");
  const raw = atob(clean);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes.buffer;
}

function getServiceAccount(): { project_id: string; client_email: string; private_key: string } {
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!raw) throw new Error("FCM_NOT_CONFIGURED");
  let account: Record<string, unknown>;
  try {
    account = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    throw new Error("FCM_SERVICE_ACCOUNT_INVALID");
  }
  const projectId = typeof account.project_id === "string" ? account.project_id.trim() : "";
  const email = typeof account.client_email === "string" ? account.client_email.trim() : "";
  const privateKey = typeof account.private_key === "string" ? account.private_key : "";
  if (!projectId || !email || !privateKey.includes("PRIVATE KEY")) {
    throw new Error("FCM_SERVICE_ACCOUNT_INVALID");
  }
  return { project_id: projectId, client_email: email, private_key: privateKey };
}

async function createFcmAccessToken(): Promise<string> {
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (cachedAccessToken && cachedAccessToken.expiresAt > nowSeconds + 60) {
    return cachedAccessToken.value;
  }

  const serviceAccount = getServiceAccount();
  const unsigned = [
    utf8Base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" })),
    utf8Base64Url(JSON.stringify({
      iss: serviceAccount.client_email,
      scope: FCM_SCOPE,
      aud: TOKEN_ENDPOINT,
      iat: nowSeconds,
      exp: nowSeconds + FCM_TOKEN_TTL_SECONDS,
    })),
  ].join(".");

  const key = await crypto.subtle.importKey(
    "pkcs8",
    decodePem(serviceAccount.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const assertion = unsigned + "." + base64Url(new Uint8Array(signature));
  const response = await fetch(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.json().catch(() => ({})) as Record<string, unknown>;
  if (!response.ok || typeof body.access_token !== "string") {
    throw new Error("FCM_OAUTH_FAILED_" + response.status);
  }
  const expiresIn = typeof body.expires_in === "number" ? body.expires_in : FCM_TOKEN_TTL_SECONDS;
  cachedAccessToken = { value: body.access_token, expiresAt: nowSeconds + expiresIn };
  return body.access_token;
}

async function getAdminClient(): Promise<SupabaseClient> {
  const url = Deno.env.get("SUPABASE_URL");
  const secretJson = Deno.env.get("SUPABASE_SECRET_KEYS");
  const legacySecret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  let secret = legacySecret ?? "";
  if (secretJson) {
    try {
      secret = (JSON.parse(secretJson) as Record<string, string>).default ?? secret;
    } catch {
      // Accept the legacy secret only if the JSON-form secret is malformed.
    }
  }
  if (!url || !secret) throw new Error("SUPABASE_SERVER_CONFIG_MISSING");
  return createClient(url, secret, { auth: { persistSession: false, autoRefreshToken: false } });
}

function safeError(error: unknown): string {
  const message = error instanceof Error ? error.message : "DELIVERY_FAILED";
  return message.replace(/[\r\n\t]/g, " ").slice(0, 240);
}

async function dispatchOne(
  admin: SupabaseClient,
  accessToken: string,
  event: OutboxEvent & { tokens: Array<{ token: string }>; has_registered_tokens: boolean },
): Promise<"sent" | "skipped" | "retry"> {
  const tokens = event.tokens ?? [];
  if (tokens.length === 0) {
    const outcome = event.has_registered_tokens ? "SKIPPED" : "NO_TOKEN";
    const { error } = await admin.rpc("finish_referral_notification_delivery", {
      p_event_id: event.event_id,
      p_outcome: outcome,
      p_error: outcome === "NO_TOKEN" ? "No FCM token is registered for this recipient." : null,
      p_invalid_tokens: [],
    });
    if (error) throw new Error("OUTBOX_FINISH_FAILED");
    return outcome === "SKIPPED" ? "skipped" : "retry";
  }

  const serviceAccount = getServiceAccount();
  const payload = event.payload ?? {};
  const title = typeof payload.title === "string" ? payload.title : "زیرمجموعه جدید";
  const body = typeof payload.body === "string" ? payload.body : "یک کاربر زیرمجموعه مستقیم شما شد.";
  let anySent = false;
  const invalidTokens: string[] = [];
  const errors: string[] = [];

  for (const target of tokens) {
    try {
      const response = await fetch(
        "https://fcm.googleapis.com/v1/projects/" + encodeURIComponent(serviceAccount.project_id) + "/messages:send",
        {
          method: "POST",
          headers: {
            "Authorization": "Bearer " + accessToken,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              token: target.token,
              data: {
                type: "REFERRAL_REGISTERED",
                event_id: event.event_id,
                referral_id: event.referral_id,
                title,
                body,
              },
              android: { priority: "HIGH", ttl: "3600s" },
            },
          }),
          signal: AbortSignal.timeout(10_000),
        },
      );
      if (response.ok) {
        anySent = true;
        continue;
      }
      const responseBody = await response.text();
      if (responseBody.includes("UNREGISTERED")) {
        invalidTokens.push(target.token);
      } else {
        errors.push("FCM_" + response.status);
      }
    } catch {
      errors.push("FCM_NETWORK_ERROR");
    }
  }

  const outcome = anySent ? "SENT" : "RETRY";
  const { error } = await admin.rpc("finish_referral_notification_delivery", {
    p_event_id: event.event_id,
    p_outcome: outcome,
    p_error: errors.slice(0, 3).join(",") || (anySent ? null : "NO_FCM_TARGET_ACCEPTED"),
    p_invalid_tokens: invalidTokens,
  });
  if (error) throw new Error("OUTBOX_FINISH_FAILED");
  return anySent ? "sent" : "retry";
}

export default {
  fetch: async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ code: "METHOD_NOT_ALLOWED" }, 405);
    try {
      const authorization = req.headers.get("Authorization") ?? "";
      const token = authorization.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
      if (!token) return json({ code: "UNAUTHORIZED" }, 401);

      const url = Deno.env.get("SUPABASE_URL");
      const publishableKeys = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
      if (!url || !publishableKeys) return json({ code: "SUPABASE_SERVER_CONFIG_MISSING" }, 500);

      let publishableKey = "";
      try {
        publishableKey = (JSON.parse(publishableKeys) as Record<string, string>).default ?? "";
      } catch {
        return json({ code: "SUPABASE_PUBLISHABLE_KEYS_INVALID" }, 500);
      }
      if (!publishableKey) return json({ code: "SUPABASE_PUBLISHABLE_KEYS_MISSING" }, 500);

      const userClient = createClient(url, publishableKey, {
        global: { headers: { Authorization: "Bearer " + token } },
        auth: { persistSession: false, autoRefreshToken: false },
      });
      const { data: auth, error: authError } = await userClient.auth.getUser(token);
      if (authError || !auth.user || auth.user.is_anonymous) return json({ code: "UNAUTHORIZED" }, 401);

      let input: { event_id?: string | null; limit?: number };
      try {
        input = await req.json();
      } catch {
        input = {};
      }
      const eventId = typeof input.event_id === "string" && /^[0-9a-f-]{36}$/i.test(input.event_id)
        ? input.event_id
        : null;
      const limit = typeof input.limit === "number" ? Math.min(Math.max(Math.floor(input.limit), 1), 10) : 10;

      // Fail closed before claiming events so an unconfigured FCM secret cannot
      // strand outbox rows behind a retry lease.
      getServiceAccount();
      const admin = await getAdminClient();

      const { data: claimed, error: claimError } = await userClient.rpc("claim_referral_notifications", {
        p_event_id: eventId,
        p_limit: limit,
      });
      if (claimError) return json({ code: "CLAIM_FAILED" }, 500);

      const ids = Array.isArray(claimed)
        ? claimed.map((entry: { event_id?: unknown }) => entry?.event_id).filter((id): id is string => typeof id === "string")
        : [];
      if (ids.length === 0) return json({ success: true, sent: 0, skipped: 0, retry: 0 });

      const { data: events, error: eventError } = await admin.rpc("load_referral_notification_delivery", {
        p_event_ids: ids,
      });
      if (eventError) throw new Error("OUTBOX_READ_FAILED");

      const parsedEvents = Array.isArray(events) ? events as Array<OutboxEvent & {
        tokens: Array<{ token: string }>;
        has_registered_tokens: boolean;
      }> : [];
      if (parsedEvents.length === 0) return json({ success: true, sent: 0, skipped: 0, retry: 0 });

      const accessToken = await createFcmAccessToken();
      let sent = 0;
      let skipped = 0;
      let retry = 0;
      for (const event of parsedEvents) {
        const result = await dispatchOne(admin, accessToken, event);
        if (result === "sent") sent++;
        else if (result === "skipped") skipped++;
        else retry++;
      }
      return json({ success: true, sent, skipped, retry });
    } catch (error) {
      const message = safeError(error);
      const code = message.includes("FCM_NOT_CONFIGURED") || message.includes("FCM_SERVICE_ACCOUNT_INVALID")
        ? "FCM_NOT_CONFIGURED"
        : "REFERRAL_PUSH_FAILED";
      return json({ code }, code === "FCM_NOT_CONFIGURED" ? 503 : 500);
    }
  },
};
