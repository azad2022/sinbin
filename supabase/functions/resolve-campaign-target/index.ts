import { createClient } from "npm:@supabase/supabase-js@2";

const RESOLVER_VERSION = 1;
const MAX_PAGES = 12;
const MAX_HTML_BYTES = 1_000_000;
const FETCH_TIMEOUT_MS = 6_000;
const MAX_LINKS_FROM_PAGE = 40;

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function normalizeText(value: string): string {
  return value
    .normalize("NFKC")
    .replace(/[يى]/g, "ی")
    .replace(/ك/g, "ک")
    .replace(/ۀ/g, "ه")
    .replace(/ة/g, "ه")
    .replace(/ـ/g, "")
    .replace(/\u200c/g, " ")
    .toLocaleLowerCase("fa")
    .replace(/\s+/g, " ")
    .trim();
}

function tokenize(value: string): string[] {
  return normalizeText(value)
    .split(/[^\p{L}\p{N}]+/u)
    .filter((x) => x.length >= 2);
}

function decodeHtml(value: string): string {
  return value
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&#x27;/gi, "'")
    .replace(/&#x2F;/gi, "/");
}

function stripHtml(value: string): string {
  return decodeHtml(
    value
      .replace(/<script[\\s\\S]*?<\\/script>/gi, " ")
      .replace(/<style[\\s\\S]*?<\\/style>/gi, " ")
      .replace(/<noscript[\\s\\S]*?<\\/noscript>/gi, " ")
      .replace(/<[^>]+>/g, " "),
  ).replace(/\\s+/g, " ").trim();
}

function extractFirst(html: string, regex: RegExp): string {
  const match = regex.exec(html);
  return decodeHtml(match?.[1] ?? "").trim();
}

function extractAnchors(html: string, baseUrl: string, origin: string): string[] {
  const urls = new Set<string>();
  const re = /<a\\b[^>]*href\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))/gi;
  let match: RegExpExecArray | null;

  while ((match = re.exec(html)) !== null && urls.size < MAX_LINKS_FROM_PAGE) {
    const href = decodeHtml(match[1] ?? match[2] ?? match[3] ?? "").trim();
    if (!href || href.startsWith("#")) continue;

    try {
      const u = new URL(href, baseUrl);
      if (u.protocol !== "https:" || u.origin !== origin) continue;
      u.hash = "";
      const pathname = u.pathname.toLowerCase();
      if (/\\.(apk|exe|dmg|zip|rar|7z|pdf|docx?|xlsx?|pptx?|mp4|mp3)(?:$|\\?)/i.test(pathname)) continue;
      urls.add(u.toString());
    } catch {
      // Ignore malformed anchors.
    }
  }

  return [...urls];
}

function extractCanonical(html: string, baseUrl: string, origin: string): string | null {
  const re = /<link\\b[^>]*rel\\s*=\\s*["'][^"']*canonical[^"']*["'][^>]*>/i;
  const tag = re.exec(html)?.[0];
  if (!tag) return null;

  const href = extractFirst(tag, /href\\s*=\\s*["']([^"']+)["']/i);
  if (!href) return null;

  try {
    const u = new URL(href, baseUrl);
    if (u.protocol !== "https:" || u.origin !== origin) return null;
    u.hash = "";
    return u.toString();
  } catch {
    return null;
  }
}

function isPrivateIpv4(ip: string): boolean {
  const parts = ip.split(".").map((x) => Number(x));
  if (parts.length !== 4 || parts.some((x) => !Number.isInteger(x) || x < 0 || x > 255)) return true;
  const [a, b] = parts;
  return (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 0) ||
    (a === 192 && b === 168) ||
    (a === 198 && b >= 18 && b <= 19) ||
    (a === 198 && b === 51) ||
    (a === 203 && b === 0) ||
    a >= 224
  );
}

function isPrivateIpv6(ip: string): boolean {
  const v = ip.toLowerCase();
  if (v === "::" || v === "::1") return true;
  if (v.startsWith("fc") || v.startsWith("fd") || v.startsWith("fe80")) return true;
  if (v.startsWith("ff")) return true;
  if (v.startsWith("::ffff:")) {
    const mapped = v.slice("::ffff:".length);
    if (mapped.includes(".")) return isPrivateIpv4(mapped);
  }
  return false;
}

async function assertPublicHost(host: string): Promise<void> {
  const results = await Promise.allSettled([
    Deno.resolveDns(host, "A"),
    Deno.resolveDns(host, "AAAA"),
  ]);

  const addresses: string[] = [];
  for (const result of results) {
    if (result.status === "fulfilled") addresses.push(...result.value);
  }

  if (addresses.length === 0) {
    throw new Error("FETCH_FAILED: Target hostname has no public DNS address");
  }

  for (const address of addresses) {
    if (address.includes(".") && isPrivateIpv4(address)) {
      throw new Error("UNSAFE_TARGET: Target hostname resolves to a private or reserved IPv4 address");
    }
    if (address.includes(":") && isPrivateIpv6(address)) {
      throw new Error("UNSAFE_TARGET: Target hostname resolves to a private or reserved IPv6 address");
    }
  }
}

async function readLimited(response: Response): Promise<string> {
  if (!response.body) return "";

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_HTML_BYTES) {
        throw new Error("PAGE_TOO_LARGE: HTML document exceeds resolver safety limit");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return new TextDecoder("utf-8", { fatal: false }).decode(merged);
}

async function fetchHtml(
  url: string,
  origin: string,
  redirects = 0,
): Promise<{ url: string; html: string }> {
  if (redirects > 3) throw new Error("FETCH_FAILED: Too many redirects");

  const parsed = new URL(url);
  if (parsed.protocol !== "https:" || parsed.origin !== origin) {
    throw new Error("UNSAFE_TARGET: Navigation left the advertiser origin");
  }

  await assertPublicHost(parsed.hostname);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

  try {
    const response = await fetch(url, {
      method: "GET",
      redirect: "manual",
      signal: controller.signal,
      headers: {
        "Accept": "text/html,application/xhtml+xml",
        "Accept-Language": "fa,en;q=0.8",
        "User-Agent": "SiteBinKeywordResolver/1.0",
      },
    });

    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) throw new Error("FETCH_FAILED: Redirect response has no location");

      const next = new URL(location, url);
      if (next.protocol !== "https:" || next.origin !== origin) {
        throw new Error("UNSAFE_TARGET: Redirect leaves the advertiser origin");
      }
      return fetchHtml(next.toString(), origin, redirects + 1);
    }

    if (!response.ok) {
      throw new Error(`FETCH_FAILED: Advertiser page returned HTTP ${response.status}`);
    }

    const contentType = response.headers.get("content-type") ?? "";
    if (!/text/html|application/xhtml\+xml/i.test(contentType)) {
      throw new Error("FETCH_FAILED: Target did not return HTML");
    }

    const html = await readLimited(response);
    return { url, html };
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new Error("FETCH_FAILED: Resolver request timed out");
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function scorePage(
  keyword: string,
  pageUrl: string,
  title: string,
  description: string,
  headings: string,
  body: string,
): { score: number; matchedTokens: number; phrase: boolean } {
  const normalizedKeyword = normalizeText(keyword);
  const tokens = [...new Set(tokenize(keyword))];

  const nTitle = normalizeText(title);
  const nDescription = normalizeText(description);
  const nHeadings = normalizeText(headings);
  const nBody = normalizeText(body);
  const nUrl = normalizeText(new URL(pageUrl).pathname.replace(/[\/_-]+/g, " "));

  const phrase =
    normalizedKeyword.length >= 4 &&
    (nTitle.includes(normalizedKeyword) ||
      nHeadings.includes(normalizedKeyword) ||
      nDescription.includes(normalizedKeyword) ||
      nBody.includes(normalizedKeyword));

  let score = 0;
  if (nTitle.includes(normalizedKeyword)) score += 60;
  if (nHeadings.includes(normalizedKeyword)) score += 45;
  if (nDescription.includes(normalizedKeyword)) score += 30;
  if (nBody.includes(normalizedKeyword)) score += 10;

  let matchedTokens = 0;
  for (const token of tokens) {
    const hit = nTitle.includes(token) || nHeadings.includes(token) || nDescription.includes(token) || nBody.includes(token);
    if (!hit) continue;
    matchedTokens += 1;

    if (nTitle.includes(token)) score += 8;
    else if (nHeadings.includes(token)) score += 6;
    else if (nDescription.includes(token)) score += 4;
    else score += 2;

    if (nUrl.includes(token)) score += 3;
  }

  return { score, matchedTokens, phrase };
}

function rankLinks(links: string[], keyword: string): string[] {
  const tokens = [...new Set(tokenize(keyword))];

  return [...links].sort((a, b) => {
    const score = (url: string) => {
      const path = normalizeText(new URL(url).pathname.replace(/[\/_-]+/g, " "));
      return tokens.reduce((sum, token) => sum + (path.includes(token) ? 1 : 0), 0);
    };
    return score(b) - score(a);
  });
}

async function resolveFromSite(keyword: string, landingUrl: string): Promise<{
  resolvedUrl: string;
  score: number;
  matchedTokens: number;
  pagesScanned: number;
}> {
  const landing = new URL(landingUrl);
  if (landing.protocol !== "https:") throw new Error("UNSAFE_TARGET: Advertiser URL must be HTTPS");

  const origin = landing.origin;
  await assertPublicHost(landing.hostname);

  const queue: string[] = [landing.toString()];
  const visited = new Set<string>();
  let best: { resolvedUrl: string; score: number; matchedTokens: number } | null = null;

  for (let i = 0; i < queue.length && visited.size < MAX_PAGES; i += 1) {
    const current = queue[i];
    if (visited.has(current)) continue;
    visited.add(current);

    let page: { url: string; html: string };
    try {
      page = await fetchHtml(current, origin);
    } catch {
      continue;
    }

    const title = extractFirst(page.html, /<title[^>]*>([\\s\\S]*?)<\\/title>/i);
    const description = extractFirst(
      page.html,
      /<meta[^>]+(?:name|property)\\s*=\\s*["'](?:description|og:description)["'][^>]+content\\s*=\\s*["']([^"']*)["'][^>]*>/i,
    );
    const headings = stripHtml(
      page.html.match(/<h[1-3][^>]*>[\\s\\S]*?<\\/h[1-3]>/gi)?.join(" ") ?? "",
    );
    const body = stripHtml(page.html).slice(0, 300_000);

    const scored = scorePage(keyword, page.url, title, description, headings, body);
    if (
      best === null ||
      scored.score > best.score ||
      (scored.score === best.score && scored.matchedTokens > best.matchedTokens)
    ) {
      best = {
        resolvedUrl: page.url,
        score: scored.score,
        matchedTokens: scored.matchedTokens,
      };
    }

    const canonical = extractCanonical(page.html, page.url, origin);
    if (canonical && !visited.has(canonical)) queue.push(canonical);

    const links = rankLinks(extractAnchors(page.html, page.url, origin), keyword);
    for (const link of links) {
      if (!visited.has(link) && !queue.includes(link)) queue.push(link);
      if (queue.length >= MAX_PAGES * 3) break;
    }
  }

  if (
    best === null ||
    best.matchedTokens === 0 ||
    (best.score < 12 && !best.resolvedUrl.endsWith(new URL(landingUrl).pathname))
  ) {
    throw new Error("NO_MATCH: No sufficiently relevant page was found on the advertiser site for this keyword");
  }

  return {
    resolvedUrl: best.resolvedUrl,
    score: best.score,
    matchedTokens: best.matchedTokens,
    pagesScanned: visited.size,
  };
}

export default {
  fetch: async (req: Request): Promise<Response> => {
    if (req.method !== "POST") {
      return json({ code: "METHOD_NOT_ALLOWED", message: "POST is required" }, 405);
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
    if (!token) {
      return json({ code: "UNAUTHORIZED", message: "Authentication token required" }, 401);
    }

    const keysRaw = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
    if (!keysRaw) {
      return json({ code: "SERVER_CONFIG", message: "Supabase publishable key is unavailable" }, 500);
    }

    const publishableKeys = JSON.parse(keysRaw);
    const publishableKey = publishableKeys.default as string;
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, publishableKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });

    const { data: authData, error: authError } = await supabase.auth.getUser(token);
    if (authError || !authData.user) {
      return json({ code: "UNAUTHORIZED", message: "Invalid user session" }, 401);
    }

    let input: { campaign_id?: string };
    try {
      input = await req.json();
    } catch {
      return json({ code: "INVALID_ARGUMENT", message: "Invalid JSON body" }, 400);
    }

    const campaignId = (input.campaign_id ?? "").trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(campaignId)) {
      return json({ code: "INVALID_ARGUMENT", message: "Invalid campaign ID" }, 400);
    }

    const { data: campaign, error: campaignError } = await supabase
      .from("campaigns")
      .select("id,owner_id,url,domain,keyword,resolver_status,resolved_target_url")
      .eq("id", campaignId)
      .maybeSingle();

    if (campaignError) {
      return json({ code: "DATABASE_ERROR", message: campaignError.message }, 500);
    }

    if (!campaign) {
      return json({ code: "CAMPAIGN_NOT_FOUND", message: "Campaign not found" }, 404);
    }

    if (campaign.owner_id !== authData.user.id) {
      return json({ code: "FORBIDDEN", message: "Campaign does not belong to the caller" }, 403);
    }

    if (!campaign.keyword) {
      return json({ code: "INVALID_ARGUMENT", message: "Campaign does not have a keyword" }, 422);
    }

    if (campaign.resolver_status === "READY" && campaign.resolved_target_url) {
      return json({
        success: true,
        campaign_id: campaign.id,
        resolved_target_url: campaign.resolved_target_url,
        resolver_status: "READY",
        resolver_version: RESOLVER_VERSION,
        cached: true,
      });
    }

    try {
      const resolved = await resolveFromSite(campaign.keyword, campaign.url);

      const { data: saved, error: saveError } = await supabase.rpc("set_campaign_resolved_target", {
        p_campaign_id: campaign.id,
        p_resolved_target_url: resolved.resolvedUrl,
      });

      if (saveError) {
        return json({ code: "DATABASE_ERROR", message: saveError.message }, 500);
      }

      return json({
        success: true,
        campaign_id: campaign.id,
        resolved_target_url: resolved.resolvedUrl,
        resolver_status: saved?.resolver_status ?? "READY",
        resolver_version: RESOLVER_VERSION,
        cached: false,
        score: resolved.score,
        matched_tokens: resolved.matchedTokens,
        pages_scanned: resolved.pagesScanned,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : "Resolver failed";
      const [code, ...rest] = message.split(":");
      return json(
        { code: code || "RESOLVER_FAILED", message: rest.join(":").trim() || message },
        code === "NO_MATCH" ? 422 : 502,
      );
    }
  },
};
