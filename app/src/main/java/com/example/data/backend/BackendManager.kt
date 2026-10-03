package com.example.data.backend

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
            System.getenv("SUPABASE_URL") ?: ""
        }
    }

    val apiKey: String by lazy {
        val buildKey = runCatching { BuildConfig.SUPABASE_ANON_KEY }.getOrDefault("")
        if (buildKey.isNotBlank() && !buildKey.contains("placeholder")) {
            buildKey
        } else {
            System.getenv("SUPABASE_ANON_KEY") ?: ""
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

    val engine: ServerAuthoritativeEngine by lazy {
        if (isSupabaseConfigured) {
            SupabaseApiClient(serverUrl, apiKey)
        } else {
            ServerEmulatedEngine()
        }
    }
}
