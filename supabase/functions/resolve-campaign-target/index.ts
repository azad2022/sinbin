import { createClient } from "npm:@supabase/supabase-js@2";

const RESOLVER_VERSION = 2;
const MAX_SITEMAP_URLS = 100;
const MAX_PAGES = 12;
const MAX_HTML_BYTES = 1_000_000;
const FETCH_TIMEOUT_MS = 6_000;
const MAX_LINKS_FROM_PAGE = 40;

function json(data: unknown, status: number = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
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
    .filter((token) => token.length >= 2);
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
      .replace(/<script[\s\S]*?<\/script>/gi, " ")
      .replace(/<style[\s\S]*?<\/style>/gi, " ")
      .replace(/<noscript[\s\S]*?<\/noscript>/gi, " ")
      .replace(/<[^>]+>/g, " "),
  ).replace(/\s+/g, " ").trim();
}

function extractFirst(html: string, regex: RegExp): string {
  return decodeHtml(regex.exec(html)?.[1] ?? "").trim();
}

function extractAnchors(html: string, baseUrl: string, origin: string): string[] {
  const urls = new Set<string>();
  const re = /<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi;
  let match: RegExpExecArray | null;

  while ((match = re.exec(html)) !== null && urls.size < MAX_LINKS_FROM_PAGE) {
    const href = decodeHtml(match[1] ?? match[2] ?? match[3] ?? "").trim();
    if (!href || href.startsWith("#")) continue;

    try {
      const url = new URL(href, baseUrl);
      if (url.protocol !== "https:" || url.origin !== origin) continue;
      url.hash = "";
      if (/\.(apk|exe|dmg|zip|rar|7z|pdf|docx?|xlsx?|pptx?|mp4|mp3)(?:$|\?)/i.test(url.pathname)) continue;
      urls.add(url.toString());
    } catch {
      // Ignore malformed or non-URL hrefs.
    }
  }

  return [...urls];
}

function extractCanonical(html: string, baseUrl: string, origin: string): string | null {
  const tag = html.match(/<link\b[^>]*rel\s*=\s*["'][^"']*canonical[^"']*["'][^>]*>/i)?.[0];
  if (!tag) return null;

  const href = extractFirst(tag, /href\s*=\s*["']([^"']+)["']/i);
  if (!href) return null;

  try {
    const url = new URL(href, baseUrl);
    if (url.protocol !== "https:" || url.origin !== origin) return null;
    url.hash = "";
    return url.toString();
  } catch {
    return null;
  }
}

function isPrivateIpv4(ip: string): boolean {
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return true;
  }

  const a = parts[0];
  const b = parts[1];

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
  const value = ip.toLowerCase();
  if (
    value === "::" ||
    value === "::1" ||
    value.startsWith("fc") ||
    value.startsWith("fd") ||
    value.startsWith("fe80") ||
    value.startsWith("ff")
  ) {
    return true;
  }

  if (value.startsWith("::ffff:")) {
    const mapped = value.slice("::ffff:".length);
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
    throw new Error("FETCH_FAILED: Target hostname has no DNS address");
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
      const result = await reader.read();
      if (result.done) break;

      total += result.value.byteLength;
      if (total > MAX_HTML_BYTES) {
        throw new Error("PAGE_TOO_LARGE: HTML document exceeds resolver safety limit");
      }
      chunks.push(result.value);
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

async function fetchHtml(url: string, origin: string, redirects: number = 0): Promise<{ url: string; html: string }> {
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
      throw new Error("FETCH_FAILED: Advertiser page returned HTTP " + response.status);
    }

    const contentType = response.headers.get("content-type") ?? "";
    if (!/(text\/html|application\/xhtml\+xml)/i.test(contentType)) {
      throw new Error("FETCH_FAILED: Target did not return HTML");
    }

    return { url, html: await readLimited(response) };
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
): { score: number; matchedTokens: number } {
  const normalizedKeyword = normalizeText(keyword);
  const tokens = [...new Set(tokenize(keyword))];

  const normalizedTitle = normalizeText(title);
  const normalizedDescription = normalizeText(description);
  const normalizedHeadings = normalizeText(headings);
  const normalizedBody = normalizeText(body);
  const normalizedPath = normalizeText(new URL(pageUrl).pathname.replace(/[\/_-]+/g, " "));

  let score = 0;
  if (normalizedTitle.includes(normalizedKeyword)) score += 60;
  if (normalizedHeadings.includes(normalizedKeyword)) score += 45;
  if (normalizedDescription.includes(normalizedKeyword)) score += 30;
  if (normalizedBody.includes(normalizedKeyword)) score += 10;

  let matchedTokens = 0;
  for (const token of tokens) {
    const inTitle = normalizedTitle.includes(token);
    const inHeadings = normalizedHeadings.includes(token);
    const inDescription = normalizedDescription.includes(token);
    const inBody = normalizedBody.includes(token);

    if (!(inTitle || inHeadings || inDescription || inBody)) continue;

    matchedTokens += 1;
    if (inTitle) score += 8;
    else if (inHeadings) score += 6;
    else if (inDescription) score += 4;
    else if (inBody) score += 2;

    if (normalizedPath.includes(token)) score += 3;
  }

  return { score, matchedTokens };
}

function rankLinks(links: string[], keyword: string): string[] {
  const tokens = [...new Set(tokenize(keyword))];

  return [...links].sort((a, b) => {
    const pathScore = (url: string): number => {
      const path = normalizeText(new URL(url).pathname.replace(/[\/_-]+/g, " "));
      return tokens.reduce((sum, token) => sum + (path.includes(token) ? 1 : 0), 0);
    };

    return pathScore(b) - pathScore(a);
  });
}


async function fetchSitemapUrls(origin: string): Promise<string[]> {
  const candidates = new Set<string>([
    new URL("/sitemap.xml", origin).toString(),
    new URL("/sitemap_index.xml", origin).toString(),
  ]);

  try {
    const robotsUrl = new URL("/robots.txt", origin).toString();
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    try {
      const response = await fetch(robotsUrl, {
        method: "GET",
        redirect: "manual",
        signal: controller.signal,
        headers: { "Accept": "text/plain" },
      });
      if (response.ok) {
        const text = await readLimited(response);
        for (const match of text.matchAll(/^\s*Sitemap\s*:\s*(\S+)\s*$/gim)) {
          try {
            const sitemap = new URL(match[1], origin);
            if (sitemap.protocol === "https:" && sitemap.origin === origin) {
              candidates.add(sitemap.toString());
            }
          } catch {}
        }
      }
    } finally {
      clearTimeout(timeout);
    }
  } catch {}

  const urls = new Set<string>();

  for (const sitemapUrl of candidates) {
    if (urls.size >= MAX_SITEMAP_URLS) break;

    try {
      const parsed = new URL(sitemapUrl);
      await assertPublicHost(parsed.hostname);

      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
      try {
        const response = await fetch(sitemapUrl, {
          method: "GET",
          redirect: "manual",
          signal: controller.signal,
          headers: { "Accept": "application/xml,text/xml,text/plain" },
        });

        if (!response.ok) continue;

        const xml = await readLimited(response);
        for (const match of xml.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/gi)) {
          try {
            const url = new URL(match[1], origin);
            if (url.protocol !== "https:" || url.origin !== origin) continue;
            url.hash = "";
            urls.add(url.toString());
            if (urls.size >= MAX_SITEMAP_URLS) break;
          } catch {}
        }
      } finally {
        clearTimeout(timeout);
      }
    } catch {}
  }

  return [...urls];
}

async function resolveFromSite(
  keyword: string,
  landingUrl: string,
): Promise<{ resolvedUrl: string; score: number; matchedTokens: number; pagesScanned: number }> {
  const landing = new URL(landingUrl);
  if (landing.protocol !== "https:") throw new Error("UNSAFE_TARGET: Advertiser URL must be HTTPS");

  const origin = landing.origin;
  await assertPublicHost(landing.hostname);

  const queue: string[] = [landing.toString()];
  const visited = new Set<string>();
  let best: { resolvedUrl: string; score: number; matchedTokens: number } | null = null;

  // Seed candidates from same-origin sitemap/robots declarations. This lets the
  // resolver find deep product/article pages that are not linked from the landing page.
  const sitemapUrls = await fetchSitemapUrls(origin);
  for (const sitemapUrl of rankLinks(sitemapUrls, keyword)) {
    if (!queue.includes(sitemapUrl)) queue.push(sitemapUrl);
  }

  while (queue.length > 0 && visited.size < MAX_PAGES) {
    const current = queue.shift()!;
    if (visited.has(current)) continue;
    visited.add(current);

    let page: { url: string; html: string };
    try {
      page = await fetchHtml(current, origin);
    } catch {
      continue;
    }

    const title = extractFirst(page.html, /<title[^>]*>([\s\S]*?)<\/title>/i);
    const description = extractFirst(
      page.html,
      /<meta[^>]+(?:name|property)\s*=\s*["'](?:description|og:description)["'][^>]+content\s*=\s*["']([^"']*)["'][^>]*>/i,
    );
    const headings = stripHtml(
      page.html.match(/<h[1-3][^>]*>[\s\S]*?<\/h[1-3]>/gi)?.join(" ") ?? "",
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
    if (canonical && !visited.has(canonical) && !queue.includes(canonical)) queue.push(canonical);

    for (const link of rankLinks(extractAnchors(page.html, page.url, origin), keyword)) {
      if (!visited.has(link) && !queue.includes(link)) queue.push(link);
      if (queue.length >= MAX_PAGES * 3) break;
    }
  }

  if (!best || best.matchedTokens === 0 || (best.score < 12 && best.resolvedUrl !== landing.toString())) {
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

    let publishableKey: string;
    try {
      const publishableKeys = JSON.parse(keysRaw) as Record<string, string>;
      publishableKey = publishableKeys.default;
    } catch {
      return json({ code: "SERVER_CONFIG", message: "Supabase publishable key configuration is invalid" }, 500);
    }

    if (!publishableKey) {
      return json({ code: "SERVER_CONFIG", message: "Default publishable key is unavailable" }, 500);
    }

    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, publishableKey, {
      global: { headers: { Authorization: "Bearer " + token } },
    });

    const authResult = await supabase.auth.getUser(token);
    if (authResult.error || !authResult.data.user) {
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

    if (campaign.owner_id !== authResult.data.user.id) {
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

      const { data: saved, error: saveError } = await supabase.rpc(
        "set_campaign_resolved_target",
        {
          p_campaign_id: campaign.id,
          p_resolved_target_url: resolved.resolvedUrl,
        },
      );

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
      const split = message.indexOf(":");
      const code = split > 0 ? message.slice(0, split) : "RESOLVER_FAILED";
      const detail = split > 0 ? message.slice(split + 1).trim() : message;

      return json(
        { code, message: detail },
        code === "NO_MATCH" ? 422 : 502,
      );
    }
  },
};
