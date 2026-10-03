package com.example.data.backend

import android.content.Context
import com.example.BuildConfig

/**
 * Backend Manager providing the active ServerAuthoritativeEngine instance.
 * Automatically connects to live Supabase if valid URL & Anon Key are injected,
 * otherwise falls back to the exact ServerEmulatedEngine for offline / testing stability.
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
