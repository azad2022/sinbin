import { createClient } from "npm:@supabase/supabase-js@2";

const MAX_URL_LENGTH = 2_048;
const MAX_REDIRECTS = 3;
const DNS_TIMEOUT_MS = 2_000;
const FETCH_TIMEOUT_MS = 6_000;
const MAX_BODY_BYTES = 512 * 1024;
const TOKEN_TTL_MS = 10 * 60 * 1000;
const BLOCKED_HOSTS = new Set([
  "localhost",
  "localhost.localdomain",
  "metadata.google.internal",
  "metadata.google.com",
]);

function json(data: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...headers,
    },
  });
}

function errorResponse(code: string, message: string, status: number, retryAfterSeconds?: number): Response {
  const headers: Record<string, string> = {};
  if (retryAfterSeconds !== undefined) headers["Retry-After"] = String(Math.max(1, retryAfterSeconds));
  return json({ code, message, ...(retryAfterSeconds !== undefined ? { retry_after_seconds: retryAfterSeconds } : {}) }, status, headers);
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error("DNS_TIMEOUT")), timeoutMs)),
  ]);
}

function isIpv4Literal(host: string): boolean {
  const parts = host.split(".");
  return parts.length === 4 && parts.every((part) => /^\d{1,3}$/.test(part));
}

function isPrivateIpv4(ip: string): boolean {
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return true;
  const [a, b, c] = parts;
  return (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 0 && c === 0) ||
    (a === 192 && b === 0 && c === 2) ||
    (a === 192 && b === 168) ||
    (a === 198 && b >= 18 && b <= 19) ||
    (a === 198 && b === 51 && c === 100) ||
    (a === 203 && b === 0 && c === 113) ||
    a >= 224
  );
}

function expandIpv6(ip: string): bigint[] | null {
  let value = ip.toLowerCase();
  if (value.includes(".")) {
    const lastColon = value.lastIndexOf(":");
    if (lastColon < 0) return null;
    const ipv4 = value.slice(lastColon + 1);
    const parts = ipv4.split(".").map(Number);
    if (parts.length !== 4 || parts.some((p) => !Number.isInteger(p) || p < 0 || p > 255)) return null;
    const high = ((parts[0] << 8) | parts[1]).toString(16);
    const low = ((parts[2] << 8) | parts[3]).toString(16);
    value = value.slice(0, lastColon) + ":" + high + ":" + low;
  }

  const halves = value.split("::");
  if (halves.length > 2) return null;

  const left = halves[0] ? halves[0].split(":").filter(Boolean) : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(":").filter(Boolean) : [];
  if (halves.length === 1 && left.length !== 8) return null;
  if (halves.length === 2 && left.length + right.length > 7) return null;

  const zeros = halves.length === 2 ? 8 - left.length - right.length : 0;
  const parts = [...left, ...Array(zeros).fill("0"), ...right];
  if (parts.length !== 8 || parts.some((p) => !/^[0-9a-f]{1,4}$/.test(p))) return null;
  return parts.map((p) => BigInt("0x" + p));
}

function isPrivateIpv6(ip: string): boolean {
  const parts = expandIpv6(ip);
  if (!parts) return true;

  let value = 0n;
  for (const part of parts) value = (value << 16n) | part;

  if (value === 0n || value === 1n) return true;

  if ((parts[0] & 0xfe00n) === 0xfc00n) return true; // fc00::/7
  if ((parts[0] & 0xffc0n) === 0xfe80n) return true; // fe80::/10
  if ((parts[0] & 0xff00n) === 0xff00n) return true; // ff00::/8

  if (parts[0] === 0 && parts[1] === 0 && parts[2] === 0 && parts[3] === 0xffffn) {
    const ipv4 = [
      Number(parts[4] >> 8n),
      Number(parts[4] & 0xffn),
      Number(parts[5] >> 8n),
      Number(parts[5] & 0xffn),
    ].join(".");
    return isPrivateIpv4(ipv4);
  }

  return false;
}

function isPublicAddress(address: string): boolean {
  return address.includes(":") ? !isPrivateIpv6(address) : !isPrivateIpv4(address);
}

async function assertPublicHost(host: string): Promise<void> {
  if (host.includes(":")) throw new Error("UNSAFE_TARGET: IPv6 literal destinations are not allowed");
  if (BLOCKED_HOSTS.has(host)) throw new Error("UNSAFE_TARGET: Internal destinations are not allowed");
  if (isIpv4Literal(host) && isPrivateIpv4(host)) {
    throw new Error("UNSAFE_TARGET: Private or reserved IPv4 destinations are not allowed");
  }

  const results = await Promise.allSettled([
    withTimeout(Deno.resolveDns(host, "A"), DNS_TIMEOUT_MS),
    withTimeout(Deno.resolveDns(host, "AAAA"), DNS_TIMEOUT_MS),
  ]);

  const addresses: string[] = [];
  for (const result of results) {
    if (result.status === "fulfilled") addresses.push(...result.value);
  }

  if (addresses.length === 0) {
    throw new Error("FETCH_FAILED: Target hostname could not be resolved");
  }

  if (addresses.some((address) => !isPublicAddress(address))) {
    throw new Error("UNSAFE_TARGET: Target hostname resolves to a private or reserved address");
  }
}

async function validateUrl(rawUrl: string): Promise<{ normalizedUrl: string; domain: string }> {
  const trimmed = rawUrl.trim();
  if (!trimmed || trimmed.length > MAX_URL_LENGTH) {
    throw new Error("INVALID_URL: آدرس وب‌سایت خالی یا بیش از ۲۰۴۸ کاراکتر است.");
  }
  if (/\s/.test(trimmed) || /@/.test(trimmed)) {
    throw new Error("INVALID_URL: آدرس وب‌سایت شامل کاراکتر یا اطلاعات کاربری غیرمجاز است.");
  }

  const candidate = /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : "https://" + trimmed;
  let parsed: URL;
  try {
    parsed = new URL(candidate);
  } catch {
    throw new Error("INVALID_URL: ساختار آدرس وب‌سایت نامعتبر است.");
  }

  if (parsed.protocol !== "https:") {
    throw new Error("INVALID_URL: فقط آدرس‌های HTTPS مجاز هستند.");
  }
  if (parsed.username || parsed.password || parsed.hostname.includes(":")) {
    throw new Error("INVALID_URL: اطلاعات کاربری و IPهای IPv6 مجاز نیستند.");
  }

  parsed.hash = "";
  const host = parsed.hostname.toLowerCase();
  if (
    !host ||
    host.length > 253 ||
    !/^[a-z0-9.-]+$/i.test(host) ||
    host.includes("..") ||
    host.startsWith(".") ||
    host.endsWith(".") ||
    host.endsWith(".local") ||
    host.endsWith(".localhost") ||
    host.endsWith(".internal") ||
    BLOCKED_HOSTS.has(host)
  ) {
    throw new Error("INVALID_URL: دامنه عمومی معتبر نیست.");
  }

  await assertPublicHost(host);
  return { normalizedUrl: parsed.toString(), domain: host };
}

async function fetchHtml(url: string, origin: string): Promise<{
  finalUrl: string;
  status: number;
  redirects: number;
  responseMs: number;
  contentType: string | null;
  contentLength: number | null;
  bodyBytes: number;
  bodyTruncated: boolean;
  contentDisposition: string | null;
}> {
  let currentUrl = url;
  let redirects = 0;
  const startedAt = performance.now();
  const deadline = startedAt + FETCH_TIMEOUT_MS;

  while (true) {
    const current = await validateUrl(currentUrl);
    if (new URL(current.normalizedUrl).origin !== origin) {
      throw new Error("UNSAFE_TARGET: Redirect left the advertiser origin");
    }

    const remainingMs = deadline - performance.now();
    if (remainingMs <= 0) throw new Error("TIMEOUT: مهلت بررسی وب‌سایت به پایان رسید.");

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), remainingMs);

    try {
      const response = await fetch(current.normalizedUrl, {
        method: "GET",
        redirect: "manual",
        signal: controller.signal,
        headers: {
          "Accept": "text/html,application/xhtml+xml",
          "Accept-Language": "fa,en;q=0.8",
          "User-Agent": "SiteBinCampaignPreflight/1.1",
          "Range": "bytes=0-524287",
        },
      });

      // Measure time to the final response headers (TTFB-like latency), not time spent
      // streaming the diagnostic body. Otherwise larger HTML responses are incorrectly
      // scored as slower websites.
      const responseMs = Math.max(0, Math.round(performance.now() - startedAt));

      if (response.status >= 300 && response.status < 400) {
        if (redirects >= MAX_REDIRECTS) {
          throw new Error("REDIRECT_LIMIT: تعداد تغییر مسیرهای وب‌سایت بیش از حد مجاز است.");
        }
        const location = response.headers.get("location");
        if (!location) throw new Error("FETCH_FAILED: پاسخ تغییر مسیر مقصدی اعلام نکرد.");

        let next: URL;
        try {
          next = new URL(location, current.normalizedUrl);
        } catch {
          throw new Error("INVALID_REDIRECT: مقصد تغییر مسیر نامعتبر است.");
        }

        const checked = await validateUrl(next.toString());
        if (new URL(checked.normalizedUrl).origin !== origin) {
          throw new Error("UNSAFE_TARGET: تغییر مسیر به دامنه دیگری مجاز نیست.");
        }

        currentUrl = checked.normalizedUrl;
        redirects += 1;
        continue;
      }

      const contentType = response.headers.get("content-type");
      const contentDisposition = response.headers.get("content-disposition");
      const rawLength = response.headers.get("content-length");
      const parsedLength = rawLength && /^\d+$/.test(rawLength) ? Number(rawLength) : null;

      let bodyBytes = 0;
      let bodyTruncated = false;
      if (response.body) {
        const reader = response.body.getReader();
        try {
          while (true) {
            const chunk = await reader.read();
            if (chunk.done) break;
            bodyBytes += chunk.value.byteLength;
            if (bodyBytes > MAX_BODY_BYTES) {
              bodyTruncated = true;
              await reader.cancel();
              break;
            }
          }
        } finally {
          reader.releaseLock();
        }
      }

      return {
        finalUrl: current.normalizedUrl,
        status: response.status,
        redirects,
        responseMs,
        contentType,
        contentLength: parsedLength,
        bodyBytes,
        bodyTruncated,
        contentDisposition,
      };
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") {
        throw new Error("TIMEOUT: سرور وب‌سایت در مهلت بررسی پاسخ نداد.");
      }
      throw error;
    } finally {
      clearTimeout(timeout);
    }
  }
}


function compatibilityFor(
  status: number,
  contentType: string | null,
  contentDisposition: string | null,
  bodyBytes: number,
  bodyTruncated: boolean,
  contentLength: number | null,
): { level: "COMPATIBLE" | "NEEDS_ATTENTION" | "INCOMPATIBLE"; message: string } {
  if (status < 200 || status >= 300) {
    return { level: "INCOMPATIBLE", message: "پاسخ HTTP موفق نبود." };
  }
  if (!contentType || !/(text\/html|application\/xhtml\+xml)/i.test(contentType)) {
    return { level: "INCOMPATIBLE", message: "محتوای مقصد HTML قابل نمایش در بازدیدکننده نیست." };
  }
  if (/attachment/i.test(contentDisposition ?? "")) {
    return { level: "INCOMPATIBLE", message: "مقصد به‌صورت فایل برای دانلود ارائه می‌شود." };
  }
  if (bodyBytes === 0) {
    return { level: "INCOMPATIBLE", message: "سند HTML خالی است." };
  }
  if (bodyTruncated || (contentLength != null && contentLength > 4 * 1024 * 1024)) {
    return { level: "NEEDS_ATTENTION", message: "صفحه HTML نسبتاً بزرگ است و ممکن است در بازدیدکننده کندتر نمایش داده شود." };
  }
  return { level: "COMPATIBLE", message: "ساختار پاسخ برای نمایش اولیه در بازدیدکننده مناسب است." };
}

function qualityScore(
  responseMs: number,
  redirects: number,
  compatibility: "COMPATIBLE" | "NEEDS_ATTENTION" | "INCOMPATIBLE",
  contentLength: number | null,
): number {
  const speed = responseMs <= 800 ? 25 : responseMs <= 1500 ? 20 : responseMs <= 2500 ? 15 : responseMs <= 5000 ? 8 : 0;
  const redirect = redirects === 0 ? 15 : redirects === 1 ? 10 : redirects === 2 ? 6 : 2;
  const viewer = compatibility === "COMPATIBLE" ? 20 : compatibility === "NEEDS_ATTENTION" ? 10 : 0;
  const size = contentLength == null ? 5 : contentLength <= 2 * 1024 * 1024 ? 10 : contentLength <= 5 * 1024 * 1024 ? 6 : 2;
  return Math.max(0, Math.min(100, 30 + speed + redirect + viewer + size));
}

function diagnostic(code: string, severity: "INFO" | "WARNING" | "BLOCK", message: string) {
  return { code, severity, message };
}

async function rateLimitOrThrow(
  userClient: ReturnType<typeof createClient>,
): Promise<void> {
  const { error } = await userClient.rpc("consume_campaign_url_preflight_rate_limit");
  if (!error) return;

  const details = typeof error.details === "string" ? error.details : "";
  let retryAfter = 0;
  try {
    const parsed = JSON.parse(details);
    retryAfter = Number(parsed?.retry_after_seconds ?? 0);
  } catch {
    const match = details.match(/retry_after_seconds["':\s]+(\d+)/i);
    retryAfter = Number(match?.[1] ?? 0);
  }

  if (String(error.code) === "PGRST" || error.message.includes("SITEBIN_RATE_LIMITED")) {
    throw Object.assign(new Error("RATE_LIMITED: تعداد بررسی‌های آدرس بیش از حد مجاز است."), {
      retryAfterSeconds: Math.max(1, retryAfter),
    });
  }

  throw new Error("SERVER_RATE_LIMIT_FAILED: بررسی محدودیت درخواست ممکن نشد.");
}

function pickSecretKey(): string {
  const secretJson = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (secretJson) {
    try {
      const parsed = JSON.parse(secretJson) as Record<string, string>;
      if (parsed.default) return parsed.default;
    } catch {
      // Fall through to legacy secret.
    }
  }
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  throw new Error("SERVER_CONFIG: Server secret key is unavailable");
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

async function sha256Hex(value: string): Promise<string> {
  const buffer = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export default {
  fetch: async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return errorResponse("METHOD_NOT_ALLOWED", "POST لازم است.", 405);

    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
    if (!token) return errorResponse("UNAUTHORIZED", "نیاز به نشست کاربر وجود دارد.", 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const publishableKeys = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
    if (!supabaseUrl || !publishableKeys) return errorResponse("SERVER_CONFIG", "پیکربندی Supabase کامل نیست.", 500);

    let publishableKey = "";
    try {
      publishableKey = (JSON.parse(publishableKeys) as Record<string, string>).default ?? "";
    } catch {
      return errorResponse("SERVER_CONFIG", "کلید عمومی Supabase نامعتبر است.", 500);
    }
    if (!publishableKey) return errorResponse("SERVER_CONFIG", "کلید عمومی Supabase در دسترس نیست.", 500);

    const userClient = createClient(supabaseUrl, publishableKey, {
      global: { headers: { Authorization: "Bearer " + token } },
    });

    const auth = await userClient.auth.getUser(token);
    if (auth.error || !auth.data.user) return errorResponse("UNAUTHORIZED", "نشست کاربر معتبر نیست.", 401);

    try {
      await rateLimitOrThrow(userClient);

      let input: { url?: string };
      try {
        input = await req.json();
      } catch {
        return errorResponse("INVALID_ARGUMENT", "بدنه درخواست نامعتبر است.", 400);
      }

      const url = typeof input.url === "string" ? input.url.trim() : "";
      const validated = await validateUrl(url);

      const fetched = await fetchHtml(validated.normalizedUrl, new URL(validated.normalizedUrl).origin);

      if (fetched.status < 200 || fetched.status >= 300) {
        return errorResponse("HTTP_ERROR", "وب‌سایت با وضعیت HTTP " + fetched.status + " پاسخ داد.", 422);
      }

      const contentType = fetched.contentType ?? "";
      const compatibility = compatibilityFor(
        fetched.status,
        fetched.contentType,
        fetched.contentDisposition,
        fetched.bodyBytes,
        fetched.bodyTruncated,
        fetched.contentLength,
      );

      const score = qualityScore(
        fetched.responseMs,
        fetched.redirects,
        compatibility.level,
        fetched.contentLength,
      );

      const diagnostics = [
        diagnostic("URL_SECURE", "INFO", "آدرس HTTPS و مقصد نهایی تحت سیاست امنیتی SiteBin بررسی شد."),
        diagnostic("DNS_PUBLIC", "INFO", "مقصد به آدرس عمومی resolve شد."),
        diagnostic(
          "HTTP_STATUS",
          fetched.status === 200 ? "INFO" : "WARNING",
          "وضعیت پاسخ HTTP: " + fetched.status,
        ),
        diagnostic(
          "REDIRECTS",
          fetched.redirects === 0 ? "INFO" : "WARNING",
          fetched.redirects === 0
            ? "تغییر مسیر وجود نداشت."
            : fetched.redirects + " تغییر مسیر امن و هم‌مبدأ دنبال شد.",
        ),
        diagnostic(
          "RESPONSE_TIME",
          fetched.responseMs <= 2500 ? "INFO" : "WARNING",
          "زمان دریافت پاسخ اولیه: " + fetched.responseMs + "ms.",
        ),
        diagnostic(
          "VIEWER_COMPATIBILITY",
          compatibility.level === "COMPATIBLE" ? "INFO" : compatibility.level === "NEEDS_ATTENTION" ? "WARNING" : "BLOCK",
          compatibility.message,
        ),
        ...(fetched.contentLength != null
          ? [diagnostic("CONTENT_LENGTH", fetched.contentLength <= 4 * 1024 * 1024 ? "INFO" : "WARNING", "حجم اعلام‌شده پاسخ: " + fetched.contentLength + " بایت.")]
          : []),
      ];

      if (compatibility.level === "INCOMPATIBLE") {
        return errorResponse("VIEWER_INCOMPATIBLE", compatibility.message, 422);
      }

      const rawTokenBytes = new Uint8Array(32);
      crypto.getRandomValues(rawTokenBytes);
      const preflightToken = base64Url(rawTokenBytes);
      const tokenHash = await sha256Hex(preflightToken);
      const expiresAtEpochMs = Date.now() + TOKEN_TTL_MS;
      const expiresAt = new Date(expiresAtEpochMs).toISOString();

      const admin = createClient(supabaseUrl, pickSecretKey(), {
        auth: { persistSession: false, autoRefreshToken: false },
      });

      const { error: storeError } = await admin.rpc("store_campaign_preflight_token", {
        p_token_hash: tokenHash,
        p_user_id: auth.data.user.id,
        p_source_url: validated.normalizedUrl,
        p_normalized_url: validated.normalizedUrl,
        p_domain: validated.domain,
        p_final_url: fetched.finalUrl,
        p_http_status: fetched.status,
        p_redirect_count: fetched.redirects,
        p_response_ms: fetched.responseMs,
        p_content_type: contentType || null,
        p_content_length: fetched.contentLength,
        p_viewer_compatibility: compatibility.level,
        p_quality_score: score,
        p_diagnostics: diagnostics,
        p_expires_at: expiresAt,
      });

      if (storeError) {
        return errorResponse("DATABASE_ERROR", "ذخیره نتیجه بررسی وب‌سایت ناموفق بود.", 500);
      }

      return json({
        success: true,
        source_url: validated.normalizedUrl,
        normalized_url: validated.normalizedUrl,
        domain: validated.domain,
        final_url: fetched.finalUrl,
        http_status: fetched.status,
        redirect_count: fetched.redirects,
        response_ms: fetched.responseMs,
        content_type: fetched.contentType,
        content_length: fetched.contentLength,
        viewer_compatibility: compatibility.level,
        quality_score: score,
        diagnostics,
        expires_at: expiresAt,
        expires_at_epoch_ms: expiresAtEpochMs,
        preflight_token: preflightToken,
      });
    } catch (error) {
      const retryAfter = Number((error as { retryAfterSeconds?: number }).retryAfterSeconds ?? 0);
      const message = error instanceof Error ? error.message : "Preflight failed";
      const separator = message.indexOf(":");
      const code = separator > 0 ? message.slice(0, separator) : "PREFLIGHT_FAILED";
      const detail = separator > 0 ? message.slice(separator + 1).trim() : message;

      if (code === "RATE_LIMITED") {
        return errorResponse(code, detail, 429, Math.max(1, retryAfter));
      }
      if (code === "TIMEOUT") return errorResponse(code, detail, 504);
      if (code === "INVALID_REDIRECT" || code === "REDIRECT_LIMIT" || code === "UNSAFE_TARGET" || code === "INVALID_URL") {
        return errorResponse(code, detail, 422);
      }
      if (code === "FETCH_FAILED") return errorResponse(code, detail, 502);
      return errorResponse(code, detail, 500);
    }
  },
};
