import { createClient } from "npm:@supabase/supabase-js@2";

const APPLICATION_ID = "sitebin.azerakhsh.ir";
const MAX_REQUEST_CHARS = 32_768;
const RSA_PUBLIC_KEY_BASE64 =
  "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCnCDddwvZDJFcxQPeBLu7wH0C2tYn9KyKCTxcNzMq2JBQdgIk7J7iNM/paiIdUbC/vBsxWhMXFX1sxnhIbgmzol/Td8Z+5Wl947TFl1Yi5gQT4T+RsJbQmchhKCbJ9BU1nyttbEN5Z/5AU5aRwUpeTJqDwK2HlmSXoy9qnUlse8QIDAQAB";
const COIN_PRODUCTS = new Set([
  "coins_5000",
  "coins_10000",
  "coins_20000",
  "coins_50000",
]);

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function decodeBase64(value: string): ArrayBuffer {
  const compact = value.replace(/\s/g, "");
  if (!compact || !/^[A-Za-z0-9+/]+={0,2}$/.test(compact)) {
    throw new Error("INVALID_BASE64");
  }
  const binary = atob(compact);
  const output = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    output[index] = binary.charCodeAt(index);
  }
  return output.buffer;
}

function isBoundedString(value: unknown, maximumLength: number): value is string {
  return typeof value === "string" && value.trim().length > 0 && value.length <= maximumLength;
}

async function verifyReceiptSignature(originalJson: string, signatureBase64: string): Promise<boolean> {
  const publicKey = await crypto.subtle.importKey(
    "spki",
    decodeBase64(RSA_PUBLIC_KEY_BASE64),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-1" },
    false,
    ["verify"],
  );
  return await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    publicKey,
    decodeBase64(signatureBase64),
    new TextEncoder().encode(originalJson),
  );
}

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method !== "POST") {
    return jsonResponse({ code: "METHOD_NOT_ALLOWED", message: "Only POST is supported." }, 405);
  }

  const authorization = request.headers.get("authorization") ?? "";
  const bearerMatch = /^Bearer\s+(.+)$/i.exec(authorization);
  if (!bearerMatch) {
    return jsonResponse({ code: "UNAUTHORIZED", message: "Authentication is required." }, 401);
  }
  const accessToken = bearerMatch[1].trim();

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const publicKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !publicKey || !serviceRoleKey) {
    console.error("Coin purchase verification is missing required server configuration.");
    return jsonResponse({ code: "SERVER_CONFIGURATION_ERROR", message: "تأیید پرداخت موقتاً در دسترس نیست." }, 500);
  }

  const authClient = createClient(supabaseUrl, publicKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser(accessToken);
  const user = authData.user;
  if (authError || !user) {
    return jsonResponse({ code: "UNAUTHORIZED", message: "نشست کاربر معتبر نیست." }, 401);
  }
  if (user.is_anonymous === true) {
    return jsonResponse({ code: "ACCOUNT_REQUIRED", message: "برای ثبت خرید، حساب SiteBin باید فعال باشد." }, 403);
  }

  let requestText: string;
  try {
    requestText = await request.text();
  } catch {
    return jsonResponse({ code: "INVALID_REQUEST", message: "درخواست خرید قابل خواندن نیست." }, 400);
  }
  if (requestText.length === 0 || requestText.length > MAX_REQUEST_CHARS) {
    return jsonResponse({ code: "INVALID_REQUEST", message: "اندازه رسید خرید معتبر نیست." }, 413);
  }

  let body: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(requestText);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return jsonResponse({ code: "INVALID_REQUEST", message: "ساختار درخواست معتبر نیست." }, 400);
    }
    body = parsed as Record<string, unknown>;
  } catch {
    return jsonResponse({ code: "INVALID_JSON", message: "ساختار رسید خرید معتبر نیست." }, 400);
  }

  const originalJson = body.originalJson;
  const signature = body.dataSignature;
  if (!isBoundedString(originalJson, 16_384) || !isBoundedString(signature, 8_192)) {
    return jsonResponse({ code: "INVALID_RECEIPT", message: "داده امضاشده رسید ناقص است." }, 400);
  }

  let signatureValid = false;
  let receipt: Record<string, unknown>;
  try {
    signatureValid = await verifyReceiptSignature(originalJson, signature);
    if (!signatureValid) {
      return jsonResponse({ code: "INVALID_SIGNATURE", message: "امضای رسید خرید معتبر نیست." }, 400);
    }
    const parsedReceipt: unknown = JSON.parse(originalJson);
    if (typeof parsedReceipt !== "object" || parsedReceipt === null || Array.isArray(parsedReceipt)) {
      return jsonResponse({ code: "INVALID_RECEIPT", message: "محتوای رسید خرید معتبر نیست." }, 400);
    }
    receipt = parsedReceipt as Record<string, unknown>;
  } catch {
    return jsonResponse({ code: "INVALID_RECEIPT", message: "رسید خرید قابل اعتبارسنجی نیست." }, 400);
  }

  const productId = receipt.productId;
  const packageName = receipt.packageName;
  const purchaseToken = receipt.token ?? receipt.purchaseToken;
  const storeOrderId = receipt.orderId;
  const payload = receipt.developerPayload ?? receipt.payload;
  const purchaseTimeMs = Number(receipt.purchaseTime);
  const purchaseState = Number(receipt.purchaseState);

  if (packageName !== APPLICATION_ID) {
    return jsonResponse({ code: "PACKAGE_MISMATCH", message: "رسید متعلق به بسته نرم‌افزاری SiteBin نیست." }, 400);
  }
  if (typeof productId !== "string" || !COIN_PRODUCTS.has(productId)) {
    return jsonResponse({ code: "PRODUCT_NOT_ALLOWED", message: "محصول سکه در فهرست مجاز قرار ندارد." }, 400);
  }
  if (!isBoundedString(purchaseToken, 2_048) || !isBoundedString(storeOrderId, 512)) {
    return jsonResponse({ code: "INVALID_RECEIPT", message: "شناسه سفارش یا رسید خرید معتبر نیست." }, 400);
  }
  if (typeof payload !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(payload)) {
    return jsonResponse({ code: "INVALID_ORDER_PAYLOAD", message: "رسید به سفارش معتبر SiteBin متصل نیست." }, 400);
  }
  if (!Number.isSafeInteger(purchaseTimeMs) || purchaseTimeMs <= 0 || purchaseState !== 0) {
    return jsonResponse({ code: "PURCHASE_NOT_COMPLETED", message: "وضعیت پرداخت کامل و معتبر نیست." }, 400);
  }

  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(originalJson));
  const receiptHash = Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await serviceClient.rpc("finalize_myket_coin_purchase_from_verified_receipt", {
    p_user_id: user.id,
    p_payload: payload,
    p_product_id: productId,
    p_purchase_token: purchaseToken,
    p_store_order_id: storeOrderId,
    p_purchase_time_ms: purchaseTimeMs,
    p_package_name: packageName,
    p_receipt_sha256: receiptHash,
  });

  if (error) {
    const message = error.message ?? "";
    if (message.includes("PURCHASE_TOKEN_REPLAY") || message.includes("STORE_ORDER_REPLAY")) {
      return jsonResponse({ code: "RECEIPT_ALREADY_USED", message: "این رسید قبلاً برای حساب دیگری ثبت شده است." }, 409);
    }
    if (
      message.includes("PURCHASE_INTENT_NOT_FOUND") ||
      message.includes("PURCHASE_INTENT_EXPIRED") ||
      message.includes("PURCHASE_PRODUCT_MISMATCH") ||
      message.includes("PURCHASE_ACCOUNT_MISMATCH") ||
      message.includes("PURCHASE_NOT_PENDING")
    ) {
      return jsonResponse({ code: "ORDER_NOT_VALID", message: "سفارش با رسید خرید تطبیق ندارد؛ موجودی تغییر نکرده است." }, 409);
    }
    console.error("Coin purchase finalization failed.", { code: error.code });
    return jsonResponse({ code: "PURCHASE_NOT_CREDITED", message: "تأیید و ثبت سکه کامل نشد؛ رسید مصرف‌نشده باقی می‌ماند." }, 503);
  }

  if (!data || data.success !== true) {
    return jsonResponse({ code: "PURCHASE_NOT_CREDITED", message: "سرور ثبت سکه را تأیید نکرد." }, 503);
  }
  return jsonResponse(data);
});
