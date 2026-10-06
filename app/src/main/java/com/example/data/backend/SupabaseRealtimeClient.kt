package com.example.data.backend

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.cancel
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Lightweight Supabase Realtime transport used only while the app is foregrounded.
 *
 * The app already owns a hardened raw OkHttp client for Supabase Auth/PostgREST/RPC,
 * so this class speaks the documented Realtime v2 WebSocket protocol directly instead
 * of adding a second full Supabase client stack.
 */
class SupabaseRealtimeClient(
    private val supabaseUrl: String,
    private val publishableKey: String,
    private val onTableChanged: (String) -> Unit,
    private val onConnectionChanged: (Boolean) -> Unit
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val sequence = AtomicLong(0L)
    private val websocketClient = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build()

    @Volatile
    private var requested = false

    @Volatile
    private var userId: String? = null

    @Volatile
    private var accessToken: String? = null

    @Volatile
    private var socket: WebSocket? = null

    @Volatile
    private var joined = false

    private var reconnectJob: Job? = null
    private var heartbeatJob: Job? = null
    private var reconnectDelayMs = 5_000L
    private var connecting = false

    fun setActive(active: Boolean, userId: String?, accessToken: String?) {
        synchronized(this) {
            requested = active
            this.userId = userId
            this.accessToken = accessToken

            if (!active || userId.isNullOrBlank() || accessToken.isNullOrBlank()) {
                joined = false
                reconnectJob?.cancel()
                reconnectJob = null
                heartbeatJob?.cancel()
                heartbeatJob = null
                socket?.close(1000, "inactive")
                socket = null
                onConnectionChanged(false)
                return
            }

            if (joined && socket != null) {
                sendAccessToken(accessToken)
                return
            }
        }

        connectIfNeeded()
    }

    fun updateAccessToken(newToken: String?) {
        if (newToken.isNullOrBlank()) return
        accessToken = newToken
        if (requested && joined) {
            sendAccessToken(newToken)
        }
    }

    fun isConnected(): Boolean = joined && socket != null

    fun shutdown() {
        synchronized(this) {
            requested = false
            joined = false
            reconnectJob?.cancel()
            reconnectJob = null
            heartbeatJob?.cancel()
            heartbeatJob = null
            socket?.close(1000, "shutdown")
            socket = null
        }
        scope.coroutineContext.cancel()
    }

    private fun connectIfNeeded() {
        val uid = userId
        val token = accessToken
        synchronized(this) {
            if (!requested || uid.isNullOrBlank() || token.isNullOrBlank()) return
            if (socket != null || connecting) return
            connecting = true
            reconnectJob?.cancel()
            reconnectJob = null
        }

        val websocketBase = supabaseUrl
            .trimEnd('/')
            .replaceFirst("https://", "wss://")
            .replaceFirst("http://", "ws://")
        val encodedKey = URLEncoder.encode(publishableKey, "UTF-8")
        val url = "$websocketBase/realtime/v1/websocket?apikey=$encodedKey&vsn=2.0.0"

        val request = Request.Builder()
            .url(url)
            .build()

        val newSocket = websocketClient.newWebSocket(request, listener)
        synchronized(this) {
            if (requested && socket == null) {
                socket = newSocket
            } else {
                connecting = false
                newSocket.close(1000, "superseded")
            }
        }
    }

    private val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            synchronized(this@SupabaseRealtimeClient) {
                if (!requested) {
                    connecting = false
                    webSocket.close(1000, "inactive")
                    return
                }
                if (socket == null) {
                    socket = webSocket
                } else if (socket !== webSocket) {
                    connecting = false
                    webSocket.close(1000, "superseded")
                    return
                }
                connecting = false
                reconnectDelayMs = 5_000L
                joined = false
            }
            sendJoin(webSocket)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            handleMessage(webSocket, text)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            Log.w("SiteBinRealtime", "WebSocket failure: ${t.message}")
            handleSocketLost(webSocket)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            handleSocketLost(webSocket)
        }
    }

    private fun sendJoin(webSocket: WebSocket) {
        val uid = userId ?: return
        val token = accessToken ?: return
        val topic = "realtime:sitebin-$uid"
        val joinRef = nextRef()

        val postgresChanges = JSONArray()
            .put(
                JSONObject()
                    .put("event", "UPDATE")
                    .put("schema", "public")
                    .put("table", "profiles")
                    .put("filter", "id=eq.$uid")
            )
            .put(
                JSONObject()
                    .put("event", "INSERT")
                    .put("schema", "public")
                    .put("table", "coin_ledger")
                    .put("filter", "user_id=eq.$uid")
                    .put("select", JSONArray().put("id"))
            )
            .put(
                JSONObject()
                    .put("event", "*")
                    .put("schema", "public")
                    .put("table", "campaigns")
                    .put("filter", "owner_id=eq.$uid")
                    .put("select", JSONArray().put("id"))
            )

        val config = JSONObject()
            .put(
                "broadcast",
                JSONObject()
                    .put("ack", false)
                    .put("self", false)
            )
            .put("presence", JSONObject().put("enabled", false))
            .put("postgres_changes", postgresChanges)
            .put("private", false)

        val payload = JSONObject()
            .put("config", config)
            .put("access_token", token)

        val message = JSONArray()
            .put(joinRef)
            .put(joinRef)
            .put(topic)
            .put("phx_join")
            .put(payload)

        synchronized(this) {
            if (requested && socket === webSocket) {
                webSocket.send(message.toString())
            }
        }
    }

    private fun sendAccessToken(newToken: String) {
        val topic = "realtime:sitebin-${userId ?: return}"
        val joinRef = nextRef()
        val message = JSONArray()
            .put(joinRef)
            .put(joinRef)
            .put(topic)
            .put("access_token")
            .put(JSONObject().put("access_token", newToken))
        socket?.send(message.toString())
    }

    private fun sendHeartbeat() {
        val message = JSONArray()
            .put(JSONObject.NULL)
            .put(nextRef())
            .put("phoenix")
            .put("heartbeat")
            .put(JSONObject())
        socket?.send(message.toString())
    }

    private fun handleMessage(webSocket: WebSocket, text: String) {
        val array = runCatching { JSONArray(text) }.getOrNull() ?: return
        if (array.length() < 5) return

        val event = array.optString(3)
        val payload = array.opt(4).let { value ->
            value as? JSONObject ?: JSONObject()
        }

        when (event) {
            "phx_reply" -> {
                val status = payload.optString("status")
                if (status == "ok") {
                    val response = payload.optJSONObject("response")
                    if (response?.has("postgres_changes") == true) {
                        synchronized(this) {
                            if (socket === webSocket && requested) {
                                joined = true
                            }
                        }
                        onConnectionChanged(isConnected())
                        startHeartbeat()
                    }
                } else if (status == "error") {
                    val reason = payload.optJSONObject("response")?.optString("reason").orEmpty()
                    Log.w("SiteBinRealtime", "Join rejected: $reason")
                    handleSocketLost(webSocket)
                    webSocket.close(1000, "join rejected")
                }
            }

            "postgres_changes" -> {
                val data = payload.optJSONObject("data") ?: return
                val table = data.optString("table").trim()
                if (table.isNotEmpty() && isConnected()) {
                    onTableChanged(table)
                }
            }

            "phx_close", "phx_error" -> {
                handleSocketLost(webSocket)
            }

            "system" -> {
                val status = payload.optString("status")
                if (status == "error" && payload.optString("extension") != "postgres_changes") {
                    handleSocketLost(webSocket)
                }
            }
        }
    }

    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (isActive && requested && isConnected()) {
                delay(20_000L)
                if (!isActive || !requested || !isConnected()) break
                sendHeartbeat()
            }
        }
    }

    private fun handleSocketLost(webSocket: WebSocket) {
        synchronized(this) {
            if (socket !== webSocket) return
            socket = null
            connecting = false
            joined = false
            heartbeatJob?.cancel()
            heartbeatJob = null
        }
        onConnectionChanged(false)
        scheduleReconnect()
    }

    private fun scheduleReconnect() {
        synchronized(this) {
            if (!requested || reconnectJob?.isActive == true) return
            val waitMs = reconnectDelayMs
            reconnectDelayMs = (reconnectDelayMs * 2L).coerceAtMost(60_000L)
            reconnectJob = scope.launch {
                delay(waitMs)
                synchronized(this@SupabaseRealtimeClient) { reconnectJob = null }
                connectIfNeeded()
            }
        }
    }

    private fun nextRef(): String = sequence.incrementAndGet().toString()
}