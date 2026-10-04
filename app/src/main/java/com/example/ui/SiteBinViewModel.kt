package com.example.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.core.security.PolicyResult
import com.example.core.security.UrlSecurityPolicy
import com.example.data.model.Campaign
import com.example.data.model.CampaignStatus
import com.example.data.model.CoinTransaction
import com.example.data.model.DurationOption
import com.example.data.model.UserAccount
import com.example.data.model.ViewSession
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
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class AppScreen {
    HOME,
    VIEWER,
    CREATE_CAMPAIGN,
    CAMPAIGNS,
    WALLET,
    SETTINGS
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

class SiteBinViewModel(application: Application) : AndroidViewModel(application) {

    val repository = SiteBinRepository(application.applicationContext)

    val serverState: StateFlow<ServerInitializationState> = repository.serverState
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), repository.serverState.value)

    val account: StateFlow<UserAccount> = repository.account
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), repository.account.value)

    val transactions: StateFlow<List<CoinTransaction>> = repository.transactions
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val campaigns: StateFlow<List<Campaign>> = repository.campaigns
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val durationOptions: List<DurationOption>
        get() = repository.durationOptions

    private val prefs = application.applicationContext.getSharedPreferences("sitebin_secure_prefs", android.content.Context.MODE_PRIVATE)

    // Theme Mode: defaults to false (Day / Light Mode)
    private val _isDarkTheme = MutableStateFlow(prefs.getBoolean("is_dark_theme", false))
    val isDarkTheme: StateFlow<Boolean> = _isDarkTheme.asStateFlow()

    fun setDarkTheme(enabled: Boolean) {
        _isDarkTheme.value = enabled
        prefs.edit().putBoolean("is_dark_theme", enabled).apply()
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

    // Viewer Timer State
    private var timerJob: Job? = null
    private var isAppInForeground = true
    private var contentReadySessionId: String? = null

    fun navigateTo(screen: AppScreen) {
        if (screen != AppScreen.VIEWER && _currentScreen.value == AppScreen.VIEWER) {
            cancelViewerTimer()
            val activeSession = currentViewerSession()
            contentReadySessionId = null
            if (activeSession != null) {
                viewModelScope.launch {
                    repository.cancelViewSession(activeSession.id)
                }
            }
        }
        _currentScreen.value = screen
    }

    fun showMessage(msg: String) {
        viewModelScope.launch {
            _snackBarMessage.emit(msg)
        }
    }

    // --- Viewer Engine ---

    fun startViewing() {
        viewModelScope.launch {
            val sessionResult = repository.getNextViewSession()
            val nextSession = sessionResult.getOrNull()
            if (nextSession == null) {
                showMessage("در حال حاضر وب‌سایت جدیدی برای مشاهده موجود نیست. لطفاً دقایقی دیگر امتحان کنید.")
                return@launch
            }

            contentReadySessionId = null
            _viewerState.value = ViewerState.Loading(nextSession)
            _currentScreen.value = AppScreen.VIEWER
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
            result.onSuccess { reward ->
                _viewerState.value = ViewerState.Completed(session, reward)
            }.onFailure { err ->
                _viewerState.value = ViewerState.Error(err.message ?: "اعتبارسنجی بازدید توسط سرور ناموفق بود.")
            }
        }
    }

    fun onForegroundChanged(inForeground: Boolean) {
        isAppInForeground = inForeground
    }

    fun onUrlBlockedInViewer(url: String, reason: String) {
        showMessage("مسدود شد: $reason")
    }

    fun skipCurrentSite() {
        cancelViewerTimer()
        viewModelScope.launch {
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
        }
    }

    fun nextSiteAfterCompletion() {
        startViewing()
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
        if (newUrl.isNotBlank()) {
            val check = UrlSecurityPolicy.evaluateUrl(newUrl)
            if (check is PolicyResult.Blocked) {
                urlError.value = check.reason
            } else {
                urlError.value = null
            }
        } else {
            urlError.value = null
        }
    }

    fun onKeywordChanged(newKeyword: String) {
        keywordInput.value = newKeyword.take(128)
    }

    fun submitCampaign(onSuccess: () -> Unit) {
        val url = urlInput.value.trim()
        val keyword = keywordInput.value.trim().ifBlank { null }
        if (url.isBlank()) {
            urlError.value = "لطفاً آدرس وب‌سایت را وارد کنید."
            return
        }

        val check = UrlSecurityPolicy.evaluateUrl(url)
        if (check is PolicyResult.Blocked) {
            urlError.value = check.reason
            return
        }

        isSubmittingCampaign.value = true
        viewModelScope.launch {
            val result = repository.createCampaign(
                rawUrl = url,
                durationSeconds = selectedDuration.value,
                targetViews = targetViewsInput.value,
                keyword = keyword
            )
            isSubmittingCampaign.value = false

            result.onSuccess { campaign ->
                urlInput.value = ""
                keywordInput.value = ""
                showMessage("سفارش شما با موفقیت ثبت و فعال شد!")
                onSuccess()
            }.onFailure { error ->
                showMessage(error.message ?: "خطا در ثبت سفارش")
            }
        }
    }

    fun transferCoins(
        recipientHandle: String,
        amount: Long,
        note: String?,
        onSuccess: () -> Unit
    ) {
        val cleanHandle = recipientHandle.trim()
        val cleanNote = note?.trim()?.ifBlank { null }
        if (cleanHandle.isBlank()) {
            showMessage("شناسه کاربری مقصد را وارد کنید.")
            return
        }
        if (amount <= 0L) {
            showMessage("مقدار سکه باید بیشتر از صفر باشد.")
            return
        }
        _isTransferringCoins.value = true
        viewModelScope.launch {
            val result = repository.transferCoins(cleanHandle, amount, cleanNote)
            _isTransferringCoins.value = false
            result.onSuccess { transfer ->
                showMessage(transfer.amount.toString() + " سکه با موفقیت به " + transfer.recipientHandle + " منتقل شد.")
                onSuccess()
            }.onFailure { error ->
                showMessage(error.message ?: "انتقال سکه ناموفق بود.")
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
                com.example.notifications.SiteBinNotificationManager.showCoinReceived(
                    getApplication(),
                    tx.amount,
                    tx.description
                )
                showMessage(tx.amount.toString() + " سکه به حساب شما واریز شد.")
            }

        while (seenIncomingTransferIds.size > 100) {
            val first = seenIncomingTransferIds.firstOrNull() ?: break
            seenIncomingTransferIds.remove(first)
        }
    }
    fun pauseCampaign(id: String) {
        viewModelScope.launch {
            repository.pauseCampaign(id)
                .onSuccess { changed ->
                    if (changed) showMessage("سفارش با موفقیت متوقف شد.")
                    else showMessage("تغییری انجام نشد؛ وضعیت سفارش احتمالاً قبلاً تغییر کرده است.")
                }
                .onFailure { error ->
                    showMessage(error.message ?: "توقف سفارش ناموفق بود.")
                }
        }
    }

    fun resumeCampaign(id: String) {
        viewModelScope.launch {
            repository.resumeCampaign(id)
                .onSuccess { changed ->
                    if (changed) showMessage("سفارش مجدداً فعال شد.")
                    else showMessage("تغییری انجام نشد؛ وضعیت سفارش احتمالاً قبلاً تغییر کرده است.")
                }
                .onFailure { error ->
                    showMessage(error.message ?: "فعال‌سازی مجدد سفارش ناموفق بود.")
                }
        }
    }

    fun cancelCampaign(id: String) {
        viewModelScope.launch {
            val result = repository.cancelCampaign(id)
            result.onSuccess { refunded ->
                showMessage("سفارش لغو و $refunded سکه به حسابتان بازگشت.")
            }.onFailure {
                showMessage(it.message ?: "خطا در لغو سفارش")
            }
        }
    }
}
