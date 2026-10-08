package com.example.ui

import android.app.Application
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.BuildConfig
import com.example.core.security.PolicyResult
import com.example.core.security.UrlSecurityPolicy
import com.example.data.model.Campaign
import com.example.data.model.CampaignStatus
import com.example.data.model.CoinTransaction
import com.example.data.model.DailyBonusResult
import com.example.data.model.WeeklyLeaderboard
import com.example.data.model.TransactionType
import com.example.data.model.DurationOption
import com.example.data.model.UserAccount
import com.example.data.model.ViewSession
import com.example.data.backend.RateLimitException
import com.example.data.backend.WebsitePreflightResult
import com.example.data.backend.WebsiteViewerCompatibility
import com.example.data.repository.ServerInitializationState
import com.example.data.repository.SiteBinRepository
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

enum class AppScreen {
    HOME,
    VIEWER,
    CREATE_CAMPAIGN,
    CAMPAIGNS,
    WALLET,
    SETTINGS,
    HELP
}

sealed class ViewerState {
    object Idle : ViewerState()
    data class Loading(val session: ViewSession) : ViewerState()
    data class Viewing(
        val session: ViewSession,
        val elapsedSeconds: Int,
        val totalSeconds: Int
    ) : ViewerState()
    data class Completed(val session: ViewSession, val rewardEarned: Long) : ViewerState()
    data class Blocked(val rawUrl: String, val reason: String) : ViewerState()
    data class Error(val message: String) : ViewerState()
}

sealed interface WebsitePreflightState {
    data object Idle : WebsitePreflightState
    data object Checking : WebsitePreflightState
    data class Completed(val result: WebsitePreflightResult) : WebsitePreflightState
    data class RateLimited(val retryAfterSeconds: Long) : WebsitePreflightState
    data class Failed(val message: String) : WebsitePreflightState
}

class SiteBinViewModel(application: Application) : AndroidViewModel(application) {

    val repository = SiteBinRepository(application.applicationContext)

    val serverState: StateFlow<ServerInitializationState> = repository.serverState
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), repository.serverState.value)

    val account: StateFlow<UserAccount> = repository.account
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), repository.account.value)

    val transactions: StateFlow<List<CoinTransaction>> = repository.transactions
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val dailyBonus: StateFlow<DailyBonusResult?> = repository.dailyBonus
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), repository.dailyBonus.value)

    val weeklyLeaderboard: StateFlow<WeeklyLeaderboard?> = repository.weeklyLeaderboard
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), repository.weeklyLeaderboard.value)

    val campaigns: StateFlow<List<Campaign>> = repository.campaigns
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val durationOptions: List<DurationOption>
        get() = repository.durationOptions

    private val prefs = application.applicationContext.getSharedPreferences("sitebin_secure_prefs", android.content.Context.MODE_PRIVATE)

    // Theme Mode: defaults to false (Day / Light Mode)
    private val _isDarkTheme = MutableStateFlow(prefs.getBoolean("is_dark_theme", false))
    val isDarkTheme: StateFlow<Boolean> = _isDarkTheme.asStateFlow()

    private val _notificationsEnabled = MutableStateFlow(
        prefs.getBoolean("coin_transfer_notifications_enabled", true)
    )
    val notificationsEnabled: StateFlow<Boolean> = _notificationsEnabled.asStateFlow()

    private val _autoViewEnabled = MutableStateFlow(
        prefs.getBoolean("auto_view_enabled", false)
    )
    val autoViewEnabled: StateFlow<Boolean> = _autoViewEnabled.asStateFlow()

    private val _isUpdatingAutoView = MutableStateFlow(false)
    val isUpdatingAutoView: StateFlow<Boolean> = _isUpdatingAutoView.asStateFlow()

    fun setNotificationsEnabled(enabled: Boolean) {
        _notificationsEnabled.value = enabled
        prefs.edit().putBoolean("coin_transfer_notifications_enabled", enabled).apply()
    }

    fun setAutoViewEnabled(enabled: Boolean) {
        if (!enabled) {
            _autoViewEnabled.value = false
            prefs.edit().putBoolean("auto_view_enabled", false).apply()
            return
        }

        if (_isUpdatingAutoView.value) return

        viewModelScope.launch {
            _isUpdatingAutoView.value = true

            val status = repository.getAutoViewStatus().getOrNull()
            if (status?.active == true) {
                _autoViewEnabled.value = true
                prefs.edit().putBoolean("auto_view_enabled", true).apply()
                _isUpdatingAutoView.value = false
                return@launch
            }

            val result = repository.activateAutoView()
            _isUpdatingAutoView.value = false

            result.onSuccess {
                _autoViewEnabled.value = true
                prefs.edit().putBoolean("auto_view_enabled", true).apply()
                showMessage("بازدید خودکار برای ۷ روز فعال شد و ۱۰۰ سکه کسر شد.")
            }.onFailure { error ->
                _autoViewEnabled.value = false
                showMessage(autoViewActivationUserMessage(error))
            }
        }
    }

    private fun autoViewActivationUserMessage(error: Throwable): String {
        val message = error.message.orEmpty()
        return when {
            message.contains("INSUFFICIENT_BALANCE", ignoreCase = true) ||
                message.contains("insufficient balance", ignoreCase = true) ||
                message.contains("less than 100", ignoreCase = true) ->
                "موجودی سکه شما کافی نیست. برای فعال‌سازی بازدید خودکار حداقل ۱۰۰ سکه نیاز دارید."
            else ->
                message.ifBlank { "فعال‌سازی بازدید خودکار ناموفق بود." }
        }
    }

    fun setDarkTheme(enabled: Boolean) {
        _isDarkTheme.value = enabled
        prefs.edit().putBoolean("is_dark_theme", enabled).apply()
    }

    init {
        viewModelScope.launch {
            while (repository.serverState.value !is ServerInitializationState.Ready) {
                delay(250)
            }

            repository.autoViewStatus.value.let { status ->
                if (!status.active && _autoViewEnabled.value) {
                    _autoViewEnabled.value = false
                    prefs.edit().putBoolean("auto_view_enabled", false).apply()
                }
            }

            repository.transactions.value
                .filter { it.type == TransactionType.COIN_TRANSFER_RECEIVED }
                .forEach { seenIncomingTransferIds.add(it.id) }
            notificationBaselineReady = true

            // Realtime is the primary low-latency path. Polling is only a safety
            // reconciliation path: 60s when the socket is healthy, 15s if it is not.
            while (true) {
                delay(if (repository.isRealtimeConnected()) 60_000L else 15_000L)
                if (
                    repository.serverState.value is ServerInitializationState.Ready &&
                    isAppInForeground
                ) {
                    refreshFinancialStateForIncomingTransfers()
                    repository.refreshAutoViewStatus()
                    repository.refreshWeeklyLeaderboard()
                    if (_currentScreen.value != AppScreen.VIEWER) {
                        repository.refreshCampaigns()
                    }

                    val now = System.currentTimeMillis()
                    if (now - lastDailyBonusAttemptAt >= 60_000L) {
                        lastDailyBonusAttemptAt = now
                        repository.claimDailyBonus()
                    }
                }
            }
        }

        // A database change is only a hint. The UI never trusts the event payload as
        // authoritative financial state; it always re-reads from PostgREST/RPC-backed data.
        viewModelScope.launch {
            repository.realtimeEvents
                .debounce(250L)
                .collect { table ->
                    if (!isAppInForeground || repository.serverState.value !is ServerInitializationState.Ready) {
                        return@collect
                    }

                    if (table == "profiles" || table == "coin_ledger") {
                        refreshFinancialStateForIncomingTransfers()
                    }
                    if (table == "campaigns" && _currentScreen.value != AppScreen.VIEWER) {
                        repository.refreshCampaigns()
                    }
                    if (table == "view_sessions") {
                        repository.refreshWeeklyLeaderboard()
                    }
                }
        }
    }

    fun retryServerInitialization() {
        viewModelScope.launch {
            repository.initializeServerState()
        }
    }

    private val _currentScreen = MutableStateFlow(AppScreen.HOME)
    val currentScreen: StateFlow<AppScreen> = _currentScreen.asStateFlow()

    private val _viewerState = MutableStateFlow<ViewerState>(ViewerState.Idle)
    val viewerState: StateFlow<ViewerState> = _viewerState.asStateFlow()

    private val _snackBarMessage = MutableSharedFlow<String>()
    val snackBarMessage: SharedFlow<String> = _snackBarMessage.asSharedFlow()

    private val _isTransferringCoins = MutableStateFlow(false)
    val isTransferringCoins: StateFlow<Boolean> = _isTransferringCoins.asStateFlow()

    private val seenIncomingTransferIds = linkedSetOf<String>()
    private var notificationBaselineReady = false

    // Create Campaign Form State
    val urlInput = MutableStateFlow("")
    val keywordInput = MutableStateFlow("")
    val selectedDuration = MutableStateFlow(15)
    val targetViewsInput = MutableStateFlow(100)
    val urlError = MutableStateFlow<String?>(null)
    val isSubmittingCampaign = MutableStateFlow(false)

    private var websitePreflightJob: Job? = null
    private val _websitePreflightState = MutableStateFlow<WebsitePreflightState>(WebsitePreflightState.Idle)
    val websitePreflightState: StateFlow<WebsitePreflightState> = _websitePreflightState.asStateFlow()

    // Viewer Timer State
    private var timerJob: Job? = null
    private var isAppInForeground = true
    private var isRequestingViewSession = false
    private var contentReadySessionId: String? = null
    private var lastDailyBonusAttemptAt = 0L
    private var viewerFlowGeneration = 0L

    // Local single-flight guard reduces duplicate taps/coroutines. This is only
    // a UX/reliability layer; the authoritative protection is server-side.
    private val inFlightActions = ConcurrentHashMap.newKeySet<String>()

    private fun beginAction(key: String): Boolean = inFlightActions.add(key)

    private fun endAction(key: String) {
        inFlightActions.remove(key)
    }

    fun navigateTo(screen: AppScreen) {
        if (screen != AppScreen.VIEWER && _currentScreen.value == AppScreen.VIEWER) {
            viewerFlowGeneration += 1L
            cancelViewerTimer()
            val activeSession = currentViewerSession()
            contentReadySessionId = null
            // Reset the viewer state before leaving the screen so a pending auto-advance
            // cannot treat the old Completed state as a valid trigger.
            _viewerState.value = ViewerState.Idle
            if (activeSession != null) {
                viewModelScope.launch {
                    repository.cancelViewSession(activeSession.id)
                }
            }
        }
        _currentScreen.value = screen
        if (screen == AppScreen.HOME) {
            viewModelScope.launch {
                repository.refreshDailyLeaderboard()
            }
        }
    }

    fun showMessage(msg: String) {
        viewModelScope.launch {
            _snackBarMessage.emit(msg)
        }
    }

    // --- Viewer Engine ---

    fun startViewing(expectedViewerFlowGeneration: Long? = null) {
        if (expectedViewerFlowGeneration != null && _currentScreen.value != AppScreen.VIEWER) return
        if (isRequestingViewSession) return

        val requestGeneration = viewerFlowGeneration
        viewModelScope.launch {
            isRequestingViewSession = true
            try {
                val requestStartedAt = SystemClock.elapsedRealtime()
                val sessionResult = repository.getNextViewSession()
                if (
                    expectedViewerFlowGeneration != null &&
                    (requestGeneration != viewerFlowGeneration || _currentScreen.value != AppScreen.VIEWER)
                ) {
                    return@launch
                }
                val elapsedMs = SystemClock.elapsedRealtime() - requestStartedAt
                if (BuildConfig.DEBUG) {
                    android.util.Log.d("SiteBinPerf", "operation=request_view_session elapsedMs=$elapsedMs")
                }

                val nextSession = sessionResult.getOrNull()
                if (nextSession == null) {
                    showMessage("در حال حاضر وب‌سایت جدیدی برای مشاهده موجود نیست. لطفاً دقایقی دیگر امتحان کنید.")
                    return@launch
                }

                contentReadySessionId = null
                _viewerState.value = ViewerState.Loading(nextSession)
                _currentScreen.value = AppScreen.VIEWER
            } finally {
                isRequestingViewSession = false
            }
        }
    }

    fun onWebViewContentVisible() {
        val currentState = _viewerState.value
        if (currentState !is ViewerState.Loading) return

        val session = currentState.session
        if (contentReadySessionId == session.id) return

        contentReadySessionId = session.id
        viewModelScope.launch {
            val result = repository.signalContentReady(session.id)
            if (result.isSuccess && result.getOrNull() == true) {
                startCountdown(session)
            } else {
                contentReadySessionId = null
                _viewerState.value = ViewerState.Error(
                    result.exceptionOrNull()?.message
                        ?: "سرور هنوز شروع معتبر بازدید را تأیید نکرده است."
                )
            }
        }
    }

    private fun startCountdown(session: ViewSession) {
        timerJob?.cancel()
        timerJob = viewModelScope.launch {
            if (_viewerState.value !is ViewerState.Completed) {
                _viewerState.value = ViewerState.Viewing(session, 0, session.requiredDurationSeconds)
            }
            var elapsed = 0
            val total = session.requiredDurationSeconds

            while (elapsed < total) {
                if (isAppInForeground) {
                    _viewerState.value = ViewerState.Viewing(session, elapsed, total)
                    delay(1000)
                    elapsed++
                } else {
                    // Paused when in background
                    delay(500)
                }
            }

            // Server-authoritative view completion validation
            val result = repository.completeViewSession(session)
            result.onSuccess { completion ->
                _viewerState.value = ViewerState.Completed(session, completion.reward)
            }.onFailure { err ->
                _viewerState.value = ViewerState.Error(err.message ?: "اعتبارسنجی بازدید توسط سرور ناموفق بود.")
            }
        }
    }

    fun onForegroundChanged(inForeground: Boolean) {
        isAppInForeground = inForeground
        repository.setRealtimeActive(inForeground)

        if (!inForeground || repository.serverState.value !is ServerInitializationState.Ready) return

        viewModelScope.launch {
            // Foreground entry is a hard reconciliation point for both financial state
            // and the daily leaderboard. Both remain server-authoritative.
            refreshFinancialStateForIncomingTransfers()
            repository.refreshAutoViewStatus()
            repository.refreshDailyLeaderboard()
            if (_currentScreen.value != AppScreen.VIEWER) {
                repository.refreshCampaigns()
            }

            val now = System.currentTimeMillis()
            if (now - lastDailyBonusAttemptAt >= 60_000L) {
                lastDailyBonusAttemptAt = now
                repository.claimDailyBonus()
            }
        }
    }

    fun onUrlBlockedInViewer(url: String, reason: String) {
        showMessage("مسدود شد: $reason")
    }

    fun skipCurrentSite() {
        if (!beginAction("skip_current_site")) return

        cancelViewerTimer()
        viewModelScope.launch {
            try {
                val activeSession = currentViewerSession()
                contentReadySessionId = null
                if (activeSession != null) {
                    repository.cancelViewSession(activeSession.id)
                }

                val nextResult = repository.getNextViewSession()
                val next = nextResult.getOrNull()
                if (next != null) {
                    contentReadySessionId = null
                    _viewerState.value = ViewerState.Loading(next)
                } else {
                    _viewerState.value = ViewerState.Idle
                    _currentScreen.value = AppScreen.HOME
                    showMessage("وب‌سایت دیگری یافت نشد.")
                }
            } finally {
                endAction("skip_current_site")
            }
        }
    }

    fun nextSiteAfterCompletion() {
        if (!_autoViewEnabled.value) {
            startViewing()
            return
        }

        val requestGeneration = viewerFlowGeneration
        if (_currentScreen.value != AppScreen.VIEWER) return

        viewModelScope.launch {
            val status = repository.autoViewStatus.value
            val serverStatus = if (status.active) {
                status
            } else {
                repository.getAutoViewStatus().getOrNull()
            }

            if (viewerFlowGeneration != requestGeneration || _currentScreen.value != AppScreen.VIEWER) {
                return@launch
            }

            if (serverStatus?.active == true) {
                startViewing(expectedViewerFlowGeneration = requestGeneration)
            } else {
                _autoViewEnabled.value = false
                prefs.edit().putBoolean("auto_view_enabled", false).apply()
                showMessage("دوره بازدید خودکار شما به پایان رسیده است.")
                _currentScreen.value = AppScreen.HOME
            }
        }
    }

    fun submitReport(reason: String, details: String) {
        val currentSession = when (val state = _viewerState.value) {
            is ViewerState.Loading -> state.session
            is ViewerState.Viewing -> state.session
            is ViewerState.Completed -> state.session
            else -> null
        }

        if (currentSession != null) {
            repository.submitReport(
                campaignId = currentSession.campaignId,
                domain = currentSession.domain,
                reason = reason,
                details = details
            )
            showMessage("گزارش شما ثبت و بررسی خواهد شد.")
            skipCurrentSite()
        }
    }

    private fun currentViewerSession(): ViewSession? {
        return when (val state = _viewerState.value) {
            is ViewerState.Loading -> state.session
            is ViewerState.Viewing -> state.session
            is ViewerState.Completed -> state.session
            else -> null
        }
    }

    private fun cancelViewerTimer() {
        timerJob?.cancel()
        timerJob = null
    }

    // --- Campaign Creation Engine ---

    fun onUrlChanged(newUrl: String) {
        urlInput.value = newUrl
        websitePreflightJob?.cancel()
        websitePreflightJob = null
        _websitePreflightState.value = WebsitePreflightState.Idle

        if (newUrl.isNotBlank()) {
            val check = UrlSecurityPolicy.evaluateUrl(newUrl)
            if (check is PolicyResult.Blocked) {
                urlError.value = check.reason
            } else if (UrlSecurityPolicy.isReadyForPreflight(newUrl)) {
                urlError.value = null
                scheduleWebsitePreflight(newUrl.trim())
            } else {
                // Do not touch the network while the user is still typing an incomplete URL.
                urlError.value = null
            }
        } else {
            urlError.value = null
        }
    }

    private fun preflightUserMessage(error: Throwable): String {
        val message = error.message?.trim().orEmpty()

        return when {
            error is java.net.UnknownHostException ->
                "آدرس وب‌سایت پیدا نشد. دامنه را بررسی کنید."
            error is java.net.SocketTimeoutException ->
                "پاسخ وب‌سایت بیش از حد طول کشید. لطفاً دوباره تلاش کنید."
            error is javax.net.ssl.SSLException ->
                "ارتباط امن با وب‌سایت برقرار نشد. گواهی SSL سایت را بررسی کنید."
            error is java.net.ConnectException ->
                "ارتباط با وب‌سایت برقرار نشد. لطفاً آدرس و وضعیت سایت را بررسی کنید."
            message.contains("Expected URL scheme", ignoreCase = true) ||
                message.contains("Malformed URL", ignoreCase = true) ||
                message.contains("Illegal character", ignoreCase = true) ->
                "آدرس وب‌سایت قابل بررسی نیست. لطفاً یک آدرس معتبر HTTPS وارد کنید."
            message.startsWith("INVALID_URL:", ignoreCase = true) ->
                message.substringAfter(":", message).trim().ifBlank {
                    "آدرس وب‌سایت معتبر نیست. لطفاً یک آدرس HTTPS وارد کنید."
                }
            message.startsWith("UNSAFE_TARGET:", ignoreCase = true) -> {
                val detail = message.substringAfter(":", "").trim()
                when {
                    detail.contains("Private or reserved IPv4", ignoreCase = true) ||
                        detail.contains("private or reserved address", ignoreCase = true) ->
                        "این وب‌سایت از سمت سرور به یک آدرس IP خصوصی یا رزروشده متصل می‌شود و برای حفظ امنیت قابل بررسی نیست."
                    detail.contains("IPv6", ignoreCase = true) ->
                        "آدرس‌های IPv6 در بررسی خودکار وب‌سایت پشتیبانی نمی‌شوند."
                    detail.contains("Redirect left", ignoreCase = true) ||
                        detail.contains("Redirect", ignoreCase = true) ->
                        "وب‌سایت به یک مقصد ناامن یا خارج از دامنه اصلی هدایت می‌شود."
                    detail.contains("Internal", ignoreCase = true) ->
                        "این مقصد داخلی است و برای حفظ امنیت قابل بررسی نیست."
                    else ->
                        "این آدرس از نظر امنیتی قابل بررسی نیست. لطفاً آدرس وب‌سایت عمومی خود را بررسی کنید."
                }
            }
            else ->
                "بررسی وب‌سایت در حال حاضر انجام نشد. لطفاً چند لحظه دیگر دوباره تلاش کنید."
        }
    }

    private fun scheduleWebsitePreflight(url: String) {
        websitePreflightJob = viewModelScope.launch {
            delay(650L)
            if (urlInput.value.trim() != url) return@launch

            _websitePreflightState.value = WebsitePreflightState.Checking
            val result = repository.preflightCampaignUrl(url)

            if (urlInput.value.trim() != url) return@launch

            result.onSuccess {
                _websitePreflightState.value = WebsitePreflightState.Completed(it)
            }.onFailure { error ->
                _websitePreflightState.value = when (error) {
                    is RateLimitException -> WebsitePreflightState.RateLimited(error.retryAfterSeconds)
                    else -> WebsitePreflightState.Failed(
                        preflightUserMessage(error)
                    )
                }
            }
        }
    }

    private suspend fun getFreshPreflightForSubmit(url: String): Result<WebsitePreflightResult> {
        val normalized = (UrlSecurityPolicy.evaluateUrl(url) as? PolicyResult.Allowed)?.normalizedUrl
            ?: return Result.failure(IllegalArgumentException("آدرس وب‌سایت قابل بررسی نیست."))

        val cached = (_websitePreflightState.value as? WebsitePreflightState.Completed)?.result
        if (
            cached != null &&
            cached.normalizedUrl == normalized &&
            cached.expiresAtEpochMs > System.currentTimeMillis() + 15_000L
        ) {
            return Result.success(cached)
        }

        _websitePreflightState.value = WebsitePreflightState.Checking
        val result = repository.preflightCampaignUrl(url)
        result.onSuccess {
            _websitePreflightState.value = WebsitePreflightState.Completed(it)
        }.onFailure {
            _websitePreflightState.value = when (it) {
                is RateLimitException -> WebsitePreflightState.RateLimited(it.retryAfterSeconds)
                else -> WebsitePreflightState.Failed(
                    preflightUserMessage(it)
                )
            }
        }
        return result
    }

    fun onKeywordChanged(newKeyword: String) {
        keywordInput.value = newKeyword
            .filterNot(Char::isISOControl)
            .take(25)
    }

    fun submitCampaign(onSuccess: () -> Unit) {
        val url = urlInput.value.trim()
        val keyword = keywordInput.value.trim().ifBlank { null }
        if (keyword != null && keyword.length > 25) {
            showMessage("کلمه کلیدی نمی‌تواند بیشتر از ۲۵ کاراکتر باشد.")
            return
        }
        if (keyword != null && keyword.any(Char::isISOControl)) {
            showMessage("کلمه کلیدی شامل کاراکتر غیرمجاز است.")
            return
        }
        if (url.isBlank()) {
            urlError.value = "لطفاً آدرس وب‌سایت را وارد کنید."
            return
        }

        val check = UrlSecurityPolicy.evaluateUrl(url)
        if (check is PolicyResult.Blocked) {
            urlError.value = check.reason
            return
        }

        if (!beginAction("create_campaign")) return

        isSubmittingCampaign.value = true
        viewModelScope.launch {
            try {
                val preflightResult = getFreshPreflightForSubmit(url)
                if (preflightResult.isFailure) {
                    val error = preflightResult.exceptionOrNull()
                    when (error) {
                        is RateLimitException -> showMessage(
                            "تعداد بررسی‌های آدرس بیش از حد مجاز است. لطفاً " + error.retryAfterSeconds + " ثانیه دیگر دوباره تلاش کنید."
                        )
                        null -> showMessage("بررسی نهایی وب‌سایت ناموفق بود.")
                        else -> showMessage(preflightUserMessage(error))
                    }
                    return@launch
                }

                val preflight = preflightResult.getOrThrow()
                if (preflight.viewerCompatibility == WebsiteViewerCompatibility.INCOMPATIBLE) {
                    showMessage("این وب‌سایت در بازدیدکننده سایت بین قابل نمایش نیست و سفارش ثبت نشد.")
                    return@launch
                }

                val result = repository.createCampaign(
                    rawUrl = preflight.normalizedUrl,
                    durationSeconds = selectedDuration.value,
                    targetViews = targetViewsInput.value,
                    keyword = keyword,
                    preflightToken = preflight.preflightToken
                )

                result.onSuccess { campaign ->
                    urlInput.value = ""
                    keywordInput.value = ""
                    _websitePreflightState.value = WebsitePreflightState.Idle
                    if (campaign.keyword != null && campaign.resolverStatus != "READY") {
                        showMessage("سفارش ثبت شد؛ در حال آماده‌سازی صفحه مرتبط با کلمه کلیدی است.")
                    } else {
                        showMessage("سفارش شما با موفقیت ثبت و فعال شد!")
                    }
                    onSuccess()
                }.onFailure { error ->
                    showMessage(error.message ?: "خطا در ثبت سفارش")
                }
            } finally {
                isSubmittingCampaign.value = false
                endAction("create_campaign")
            }
        }
    }

    fun transferCoins(
        recipientHandle: String,
        amount: Long,
        onSuccess: () -> Unit
    ) {
        val cleanHandle = recipientHandle.trim()
        if (cleanHandle.isBlank()) {
            showMessage("شناسه کاربری مقصد را وارد کنید.")
            return
        }
        if (amount <= 0L) {
            showMessage("مقدار سکه باید بیشتر از صفر باشد.")
            return
        }
        if (!beginAction("transfer_coins")) return

        _isTransferringCoins.value = true
        viewModelScope.launch {
            try {
                val result = repository.transferCoins(cleanHandle, amount)
                result.onSuccess { transfer ->
                    showMessage(transfer.amount.toString() + " سکه با موفقیت به " + transfer.recipientHandle + " منتقل شد.")
                    onSuccess()
                }.onFailure { error ->
                    showMessage(error.message ?: "انتقال سکه ناموفق بود.")
                }
            } finally {
                _isTransferringCoins.value = false
                endAction("transfer_coins")
            }
        }
    }

    private suspend fun refreshFinancialStateForIncomingTransfers() {
        val result = repository.refreshFinancialState()
        if (result.isFailure) return

        val current = transactions.value.filter {
            it.type == TransactionType.COIN_TRANSFER_RECEIVED
        }
        if (!notificationBaselineReady) {
            current.forEach { seenIncomingTransferIds.add(it.id) }
            notificationBaselineReady = true
            return
        }

        current.filterNot { it.id in seenIncomingTransferIds }
            .sortedBy { it.timestamp }
            .forEach { tx ->
                seenIncomingTransferIds.add(tx.id)
                if (_notificationsEnabled.value) {
                    com.example.notifications.SiteBinNotificationManager.showCoinReceived(
                        getApplication(),
                        tx.amount,
                        tx.description
                    )
                }
                showMessage(tx.amount.toString() + " سکه به حساب شما واریز شد.")
            }

        while (seenIncomingTransferIds.size > 100) {
            val first = seenIncomingTransferIds.firstOrNull() ?: break
            seenIncomingTransferIds.remove(first)
        }
    }
    fun pauseCampaign(id: String) {
        val actionKey = "pause_campaign:$id"
        if (!beginAction(actionKey)) return

        viewModelScope.launch {
            try {
                repository.pauseCampaign(id)
                    .onSuccess { changed ->
                        if (changed) showMessage("سفارش با موفقیت متوقف شد.")
                        else showMessage("تغییری انجام نشد؛ وضعیت سفارش احتمالاً قبلاً تغییر کرده است.")
                    }
                    .onFailure { error ->
                        showMessage(error.message ?: "توقف سفارش ناموفق بود.")
                    }
            } finally {
                endAction(actionKey)
            }
        }
    }

    fun resumeCampaign(id: String) {
        val actionKey = "resume_campaign:$id"
        if (!beginAction(actionKey)) return

        viewModelScope.launch {
            try {
                repository.resumeCampaign(id)
                    .onSuccess { changed ->
                        if (changed) showMessage("سفارش مجدداً فعال شد.")
                        else showMessage("تغییری انجام نشد؛ وضعیت سفارش احتمالاً قبلاً تغییر کرده است.")
                    }
                    .onFailure { error ->
                        showMessage(error.message ?: "فعال‌سازی مجدد سفارش ناموفق بود.")
                    }
            } finally {
                endAction(actionKey)
            }
        }
    }

    fun cancelCampaign(id: String) {
        val actionKey = "cancel_campaign:$id"
        if (!beginAction(actionKey)) return

        viewModelScope.launch {
            try {
                val result = repository.cancelCampaign(id)
                result.onSuccess { refunded ->
                    showMessage("سفارش لغو و $refunded سکه به حسابتان بازگشت.")
                }.onFailure {
                    showMessage(it.message ?: "خطا در لغو سفارش")
                }
            } finally {
                endAction(actionKey)
            }
        }
    }
}
