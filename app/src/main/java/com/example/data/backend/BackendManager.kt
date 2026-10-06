package com.example.data.backend

import android.content.Context
import com.example.BuildConfig
import com.example.core.security.AppIdentityGuard

/**
 * Backend Manager providing the active ServerAuthoritativeEngine instance.
 * Connects only to the configured live Supabase backend. A missing or invalid
 * backend configuration is a hard failure; the client never falls back to a local engine.
 */
object BackendManager {

    val serverUrl: String by lazy {
        val buildUrl = runCatching { BuildConfig.SUPABASE_URL }.getOrDefault("")
        if (buildUrl.isNotBlank() && !buildUrl.contains("your-project")) {
            buildUrl
        } else {
            ""
        }
    }

    val apiKey: String by lazy {
        val buildKey = runCatching { BuildConfig.SUPABASE_PUBLISHABLE_KEY }.getOrDefault("")
        if (buildKey.isNotBlank() && !buildKey.contains("placeholder")) {
            buildKey
        } else {
            ""
        }
    }

    val isSupabaseConfigured: Boolean by lazy {
        serverUrl.isNotBlank() &&
                !serverUrl.contains("your-project") &&
                apiKey.isNotBlank() &&
                !apiKey.contains("placeholder")
    }

    val backendName: String by lazy {
        if (isSupabaseConfigured) "سرور ابری Supabase (PostgreSQL)" else "موتور سرور اعتبارسنجی داخلی (Server-Authoritative)"
    }

    @Volatile
    private var _cachedEngine: ServerAuthoritativeEngine? = null

    fun getEngine(context: Context? = null): ServerAuthoritativeEngine {
        if (!BuildConfig.DEBUG && context != null &&
            !AppIdentityGuard.isTrustedInstallation(context)
        ) {
            throw SecurityException("SiteBin release integrity check failed.")
        }

        val existing = _cachedEngine
        if (existing != null) return existing

        check(isSupabaseConfigured) {
            "SiteBin backend is not configured for the selected build. Refusing to silently use ServerEmulatedEngine."
        }

        synchronized(this) {
            if (_cachedEngine == null) {
                _cachedEngine = if (isSupabaseConfigured) {
                    SupabaseApiClient(serverUrl, apiKey, context)
                } else {
                    throw IllegalStateException("Supabase backend configuration missing")
                }
            }
            return _cachedEngine!!
        }
    }

    val engine: ServerAuthoritativeEngine
        get() = getEngine(null)
}
