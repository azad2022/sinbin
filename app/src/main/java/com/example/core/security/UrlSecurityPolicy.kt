package com.example.core.security

import java.net.URI
import java.util.Locale

sealed class PolicyResult {
    data class Allowed(val normalizedUrl: String, val domain: String) : PolicyResult()
    data class Blocked(val rawUrl: String, val reason: String) : PolicyResult()
    data class Controlled(val rawUrl: String, val reason: String) : PolicyResult()
}

object UrlSecurityPolicy {

    private val BLOCKED_SCHEMES = setOf(
        "tg", "telegram", "market", "intent", "app",
        "whatsapp", "tel", "mailto", "sms", "geo",
        "file", "content", "javascript", "data", "blob", "ftp",
        "viber", "fb", "instagram", "twitter", "tiktok"
    )

    private val BLOCKED_HOSTS_EXACT = setOf(
        "localhost",
        "127.0.0.1",
        "0.0.0.0",
        "metadata.google.internal",
        "169.254.169.254",
        "::1"
    )

    private val BLOCKED_DOMAINS = setOf(
        "t.me",
        "telegram.me",
        "telegram.org",
        "play.google.com",
        "play.googleusercontent.com",
        "bazaar.cafebazaar.ir",
        "myket.ir",
        "wa.me",
        "chat.whatsapp.com"
    )

    private val BLOCKED_FILE_EXTENSIONS = setOf(
        ".apk", ".exe", ".dmg", ".bat", ".sh", ".zip", ".rar", ".7z", ".crx", ".msi"
    )

    /**
     * Evaluates any incoming navigation URL against SiteBin's strict security policy.
     */
    fun evaluateUrl(rawUrl: String?): PolicyResult {
        if (rawUrl.isNullOrBlank()) {
            return PolicyResult.Blocked("", "آدرس وب‌سایت نمی‌تواند خالی باشد.")
        }

        val trimmed = rawUrl.trim()

        // 1. Scheme Extraction
        val scheme = when {
            trimmed.contains("://") -> trimmed.substringBefore("://").lowercase(Locale.ROOT)
            trimmed.contains(":") -> trimmed.substringBefore(":").lowercase(Locale.ROOT)
            else -> "https"
        }

        if (BLOCKED_SCHEMES.contains(scheme)) {
            val friendlyReason = when (scheme) {
                "tg", "telegram" -> "انتقال به تلگرام در داخل محیط سایت بین مجاز نیست."
                "market" -> "انتقال به مارکت یا گوگل پلی مجاز نیست."
                "intent" -> "اجرای Intent خارجی مجاز نیست."
                "whatsapp" -> "انتقال به واتساپ مجاز نیست."
                "tel" -> "برقراری تماس مستقیم مجاز نیست."
                "mailto" -> "ارسال ایمیل مستقیم در این بخش مجاز نیست."
                "file", "content" -> "دسترسی به فایل‌های محلی مسدود است."
                else -> "پروتکل $scheme خارج از محیط اپلیکیشن مجاز نیست."
            }
            return PolicyResult.Blocked(trimmed, friendlyReason)
        }

        if (scheme != "https") {
            return PolicyResult.Blocked(trimmed, "تنها آدرس‌های HTTPS در سایت بین مجاز هستند.")
        }

        // 2. Host and SSRF / IP Range Check
        val javaUri = try {
            val urlToParse = if (trimmed.startsWith("https://", ignoreCase = true)) {
                trimmed
            } else {
                "https://$trimmed"
            }
            URI(urlToParse)
        } catch (e: Exception) {
            return PolicyResult.Blocked(trimmed, "ساختار URL نامعتبر است.")
        }

        // Bracketed authority syntax denotes an IPv6 literal; SiteBin does not allow literal-IP destinations.
        val rawAuthority = javaUri.rawAuthority.orEmpty()
        if (rawAuthority.contains("[") || rawAuthority.contains("]")) {
            return PolicyResult.Blocked(trimmed, "دسترسی به آدرس‌های IP خصوصی و محلی مسدود است.")
        }

        val host = javaUri.host?.lowercase(Locale.ROOT)
        if (host.isNullOrBlank()) {
            return PolicyResult.Blocked(trimmed, "دامنه مشخص نیست.")
        }

        if (BLOCKED_HOSTS_EXACT.contains(host)) {
            return PolicyResult.Blocked(trimmed, "دسترسی به هاست‌های داخلی یا لوکال مسدود است.")
        }

        // Check private IPv4 ranges, hex, decimal or octal IP tricks
        if (isPrivateOrSuspiciousIp(host)) {
            return PolicyResult.Blocked(trimmed, "دسترسی به آدرس‌های IP خصوصی و محلی مسدود است.")
        }

        // Check domain blacklist
        for (blockedDomain in BLOCKED_DOMAINS) {
            if (host == blockedDomain || host.endsWith(".$blockedDomain")) {
                val reason = when {
                    blockedDomain.contains("telegram") || blockedDomain.contains("t.me") ->
                        "کانال‌ها و لینک‌های تلگرام در سایت بین مجاز نیستند."
                    blockedDomain.contains("play.google") || blockedDomain.contains("cafebazaar") || blockedDomain.contains("myket") ->
                        "هدایت به استورهای دانلود برنامه مسدود است."
                    else -> "دامنه $host در لیست محدود شده پلتفرم قرار دارد."
                }
                return PolicyResult.Blocked(trimmed, reason)
            }
        }

        // 3. File Download Check
        val path = javaUri.path?.lowercase(Locale.ROOT) ?: ""
        for (ext in BLOCKED_FILE_EXTENSIONS) {
            if (path.endsWith(ext) || trimmed.lowercase(Locale.ROOT).contains(ext)) {
                return PolicyResult.Blocked(trimmed, "دانلود مستقیم فایل در سایت بین مجاز نیست.")
            }
        }

        val normalized = normalizeUrl(trimmed)
        return PolicyResult.Allowed(normalized, host)
    }

    private fun isPrivateOrSuspiciousIp(host: String): Boolean {
        // Hex representation (e.g. 0x7f000001)
        if (host.startsWith("0x", ignoreCase = true)) {
            return true
        }

        // Decimal integer representation of IP (e.g. 2130706433 for 127.0.0.1)
        if (host.matches(Regex("""^\d{8,11}$"""))) {
            return true
        }

        // IPv6 Loopback / Link-Local / Private
        if (host.startsWith("[") && host.endsWith("]")) {
            val inner = host.removeSurrounding("[", "]")
            if (inner == "::1" || inner.startsWith("fe80", ignoreCase = true) || inner.startsWith("fc", ignoreCase = true)) {
                return true
            }
        }

        // Standard Dotted Decimal IPv4
        if (host.matches(Regex("""^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"""))) {
            val parts = host.split(".").mapNotNull { it.toIntOrNull() }
            if (parts.size != 4) return true

            // 10.0.0.0/8
            if (parts[0] == 10) return true
            // 192.168.0.0/16
            if (parts[0] == 192 && parts[1] == 168) return true
            // 172.16.0.0/12
            if (parts[0] == 172 && parts[1] in 16..31) return true
            // 127.0.0.0/8 (loopback)
            if (parts[0] == 127) return true
            // 0.0.0.0
            if (parts[0] == 0) return true
            // 169.254.0.0/16 (link-local & cloud metadata)
            if (parts[0] == 169 && parts[1] == 254) return true
        }

        return false
    }

    fun normalizeUrl(rawUrl: String): String {
        var result = rawUrl.trim()
        if (!result.startsWith("https://", ignoreCase = true)) {
            result = "https://$result"
        }
        return try {
            val uri = URI(result)
            val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: "https"
            val host = uri.host?.lowercase(Locale.ROOT) ?: ""
            val port = if (uri.port != -1 && uri.port != 80 && uri.port != 443) ":${uri.port}" else ""
            val path = uri.rawPath.ifEmpty { "/" }
            val query = if (uri.rawQuery != null) "?${uri.rawQuery}" else ""
            "$scheme://$host$port$path$query"
        } catch (e: Exception) {
            result
        }
    }
}
