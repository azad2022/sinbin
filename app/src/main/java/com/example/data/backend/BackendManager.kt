package com.example.data.backend

import com.example.BuildConfig

/**
 * Backend Manager providing the active ServerAuthoritativeEngine instance.
 * Automatically connects to live Supabase if valid URL & Anon Key are injected,
 * otherwise falls back to the exact ServerEmulatedEngine for offline / testing stability.
 */
object BackendManager {

    val isSupabaseConfigured: Boolean by lazy {
        val url = runCatching { BuildConfig.SUPABASE_URL }.getOrDefault("")
        val key = runCatching { BuildConfig.SUPABASE_ANON_KEY }.getOrDefault("")

        url.isNotBlank() &&
                !url.contains("your-project") &&
                key.isNotBlank() &&
                !key.contains("placeholder")
    }

    val serverUrl: String by lazy {
        runCatching { BuildConfig.SUPABASE_URL }.getOrDefault("")
    }

    val backendName: String by lazy {
        if (isSupabaseConfigured) "سرور ابری Supabase (PostgreSQL)" else "موتور سرور اعتبارسنجی داخلی (Server-Authoritative)"
    }

    val engine: ServerAuthoritativeEngine by lazy {
        val url = runCatching { BuildConfig.SUPABASE_URL }.getOrDefault("")
        val key = runCatching { BuildConfig.SUPABASE_ANON_KEY }.getOrDefault("")

        if (isSupabaseConfigured) {
            SupabaseApiClient(url, key)
        } else {
            ServerEmulatedEngine()
        }
    }
}
