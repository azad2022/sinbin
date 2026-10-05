package com.example

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.MonetizationOn
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.MonetizationOn
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlin.math.max
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.example.data.model.TransactionType
import com.example.data.repository.ServerInitializationState
import com.example.ui.AppScreen
import com.example.ui.SiteBinViewModel
import com.example.ui.ViewerState
import com.example.ui.screens.CampaignsScreen
import com.example.ui.screens.CreateCampaignScreen
import com.example.ui.screens.HelpGuideScreen
import com.example.ui.screens.HomeScreen
import com.example.ui.screens.OnboardingScreen
import com.example.ui.screens.SettingsScreen
import com.example.ui.screens.ViewerScreen
import com.example.ui.screens.WalletScreen
import com.example.ui.theme.SiteBinTheme
import kotlinx.coroutines.flow.collectLatest

class MainActivity : ComponentActivity() {

    private val viewModel: SiteBinViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            val isDarkTheme by viewModel.isDarkTheme.collectAsState()
            SiteBinTheme(darkTheme = isDarkTheme) {
                MainAppContent(viewModel = viewModel)
            }
        }
    }
}

@Composable
fun MainAppContent(viewModel: SiteBinViewModel) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("sitebin_prefs", Context.MODE_PRIVATE) }
    var isOnboardingCompleted by remember {
        mutableStateOf(prefs.getBoolean("onboarding_done", false))
    }

    val serverState by viewModel.serverState.collectAsState()
    val currentScreen by viewModel.currentScreen.collectAsState()
    val account by viewModel.account.collectAsState()
    val campaigns by viewModel.campaigns.collectAsState()
    val transactions by viewModel.transactions.collectAsState()
    val dailyBonus by viewModel.dailyBonus.collectAsState()
    val viewerState by viewModel.viewerState.collectAsState()
    val autoViewEnabled by viewModel.autoViewEnabled.collectAsState()
    val isUpdatingAutoView by viewModel.isUpdatingAutoView.collectAsState()

    val snackbarHostState = remember { SnackbarHostState() }

    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        viewModel.setNotificationsEnabled(granted)
        prefs.edit().putBoolean("coin_transfer_notification_permission_asked", true).apply()
    }

    val notificationsEnabled by viewModel.notificationsEnabled.collectAsState()

    LaunchedEffect(currentScreen, notificationsEnabled) {
        if (
            currentScreen == AppScreen.SETTINGS &&
            notificationsEnabled &&
            android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED &&
            !prefs.getBoolean("coin_transfer_notification_permission_asked", false)
        ) {
            prefs.edit().putBoolean("coin_transfer_notification_permission_asked", true).apply()
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    // Listen to ViewModel snackbar events
    LaunchedEffect(Unit) {
        viewModel.snackBarMessage.collectLatest { msg ->
            snackbarHostState.showSnackbar(message = msg)
        }
    }

    // Observe foreground/background lifecycle to pause timer
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START, Lifecycle.Event.ON_RESUME -> {
                    viewModel.onForegroundChanged(true)
                }
                Lifecycle.Event.ON_PAUSE, Lifecycle.Event.ON_STOP -> {
                    viewModel.onForegroundChanged(false)
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    when (val state = serverState) {
        ServerInitializationState.Initializing -> {
            StartupScreen(isRetry = false, message = null, onRetry = {})
        }

        is ServerInitializationState.Failed -> {
            StartupScreen(
                isRetry = true,
                message = state.message,
                onRetry = viewModel::retryServerInitialization
            )
        }

        ServerInitializationState.Ready -> {
            if (!isOnboardingCompleted) {
                OnboardingScreen(
                    onFinish = {
                        prefs.edit().putBoolean("onboarding_done", true).apply()
                        isOnboardingCompleted = true
                    }
                )
            } else {
        Scaffold(
            snackbarHost = { SnackbarHost(hostState = snackbarHostState) },
            bottomBar = {
                // Hide bottom navigation when in viewer mode to maximize space & prevent distractions
                if (currentScreen != AppScreen.VIEWER) {
                    SiteBinBottomBar(
                        currentScreen = currentScreen,
                        onScreenSelected = { viewModel.navigateTo(it) },
                        onStartViewing = { viewModel.startViewing() }
                    )
                }
            },
            modifier = Modifier.fillMaxSize()
        ) { innerPadding ->
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding)
            ) {
                AnimatedContent(
                    targetState = currentScreen,
                    transitionSpec = { fadeIn() togetherWith fadeOut() },
                    label = "screen_transition"
                ) { screen ->
                    when (screen) {
                        AppScreen.HOME -> {
                            val latestWelcomeBonus = transactions
                                .filter { it.type == TransactionType.WELCOME_REWARD }
                                .maxByOrNull { it.timestamp }
                            val welcomeBonusAmount = latestWelcomeBonus
                                ?.amount
                                ?.takeIf { it > 0L }
                            val welcomeBonusGrantedAt = latestWelcomeBonus?.timestamp
                            val showWelcomeBonus =
                                welcomeBonusGrantedAt?.let {
                                    com.example.ui.screens.isWelcomeBonusBannerVisible(
                                        grantedAtMillis = it,
                                        nowMillis = System.currentTimeMillis()
                                    )
                                } == true
                            val showWelcomeCelebration =
                                welcomeBonusAmount != null &&
                                    !prefs.getBoolean("welcome_bonus_celebration_seen", false)

                            val dailyBonusDate = dailyBonus?.grantDate
                            val showDailyBonusCelebration =
                                dailyBonus?.granted == true &&
                                    !dailyBonusDate.isNullOrBlank() &&
                                    prefs.getString("daily_bonus_celebration_seen_date", null) != dailyBonusDate

                            HomeScreen(
                                account = account,
                                campaigns = campaigns,
                                welcomeBonusAmount = welcomeBonusAmount,
                                welcomeBonusGrantedAt = welcomeBonusGrantedAt,
                                showWelcomeBonus = showWelcomeBonus,
                                showWelcomeCelebration = showWelcomeCelebration,
                                onWelcomeCelebrationConsumed = {
                                    prefs.edit()
                                        .putBoolean("welcome_bonus_celebration_seen", true)
                                        .apply()
                                },
                                dailyBonus = dailyBonus,
                                showDailyBonusCelebration = showDailyBonusCelebration,
                                onDailyBonusCelebrationConsumed = {
                                    val date = dailyBonus?.grantDate
                                    if (!date.isNullOrBlank()) {
                                        prefs.edit()
                                            .putString("daily_bonus_celebration_seen_date", date)
                                            .apply()
                                    }
                                },
                                onStartViewing = { viewModel.startViewing() },
                                onNavigate = { viewModel.navigateTo(it) }
                            )
                        }

                        AppScreen.VIEWER -> {
                            ViewerScreen(
                                viewerState = viewerState,
                                autoViewEnabled = autoViewEnabled,
                                onContentReady = { viewModel.onWebViewContentVisible() },
                                onUrlBlocked = { url, reason -> viewModel.onUrlBlockedInViewer(url, reason) },
                                onSkip = { viewModel.skipCurrentSite() },
                                onNextSite = { viewModel.nextSiteAfterCompletion() },
                                onReport = { reason, details -> viewModel.submitReport(reason, details) },
                                onBack = { viewModel.navigateTo(AppScreen.HOME) }
                            )
                        }

                        AppScreen.CREATE_CAMPAIGN -> {
                            CreateCampaignScreen(
                                viewModel = viewModel,
                                account = account,
                                onBack = { viewModel.navigateTo(AppScreen.HOME) },
                                onSuccess = { viewModel.navigateTo(AppScreen.CAMPAIGNS) }
                            )
                        }

                        AppScreen.CAMPAIGNS -> {
                            BackHandler { viewModel.navigateTo(AppScreen.HOME) }
                            CampaignsScreen(
                                campaigns = campaigns,
                                onAddCampaign = { viewModel.navigateTo(AppScreen.CREATE_CAMPAIGN) },
                                onPauseCampaign = { viewModel.pauseCampaign(it) },
                                onResumeCampaign = { viewModel.resumeCampaign(it) },
                                onCancelCampaign = { viewModel.cancelCampaign(it) }
                            )
                        }

                        AppScreen.WALLET -> {
                            BackHandler { viewModel.navigateTo(AppScreen.HOME) }
                            WalletScreen(
                                account = account,
                                transactions = transactions,
                                isTransferringCoins = viewModel.isTransferringCoins.collectAsState().value,
                                onTransferCoins = { recipient, amount, onSuccess ->
                                    viewModel.transferCoins(recipient, amount, onSuccess)
                                },
                                onNavigate = { screen -> viewModel.navigateTo(screen) }
                            )
                        }

                        AppScreen.HELP -> {
                            BackHandler { viewModel.navigateTo(AppScreen.SETTINGS) }
                            HelpGuideScreen(
                                onBack = { viewModel.navigateTo(AppScreen.SETTINGS) }
                            )
                        }

                        AppScreen.SETTINGS -> {
                            val isDarkTheme by viewModel.isDarkTheme.collectAsState()
                            BackHandler { viewModel.navigateTo(AppScreen.HOME) }
                            SettingsScreen(
                                account = account,
                                isDarkTheme = isDarkTheme,
                                onToggleDarkTheme = { viewModel.setDarkTheme(it) },
                                notificationsEnabled = notificationsEnabled,
                                onToggleNotifications = { enabled ->
                                    if (
                                        enabled &&
                                        android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU &&
                                        ContextCompat.checkSelfPermission(
                                            context,
                                            Manifest.permission.POST_NOTIFICATIONS
                                        ) != PackageManager.PERMISSION_GRANTED
                                    ) {
                                        viewModel.setNotificationsEnabled(true)
                                        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                    } else {
                                        viewModel.setNotificationsEnabled(enabled)
                                    }
                                },
                                autoViewEnabled = autoViewEnabled,
                                isUpdatingAutoView = isUpdatingAutoView,
                                onToggleAutoView = { enabled ->
                                    viewModel.setAutoViewEnabled(enabled)
                                },
                                onOpenHelp = { viewModel.navigateTo(AppScreen.HELP) }
                            )
                        }
                    }
                }
            }
            }
        }
    }
    }
}

@Composable
private fun StartupScreen(
    isRetry: Boolean,
    message: String?,
    onRetry: () -> Unit
) {
    androidx.compose.material3.Surface(
        modifier = Modifier.fillMaxSize(),
        color = androidx.compose.material3.MaterialTheme.colorScheme.background
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 28.dp),
            contentAlignment = Alignment.Center
        ) {
            if (!isRetry) {
                StartupLoadingBar(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(64.dp)
                )
            } else {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = "اتصال به حساب برقرار نشد",
                        style = androidx.compose.material3.MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "برای حفظ صحت موجودی و پاداش‌ها، بدون تأیید سرور وارد برنامه نمی‌شویم.",
                        style = androidx.compose.material3.MaterialTheme.typography.bodyMedium,
                        color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center
                    )
                    if (BuildConfig.DEBUG && !message.isNullOrBlank()) {
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(
                            text = "جزئیات تشخیص:\n${message.trim().take(320)}",
                            style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                            color = androidx.compose.material3.MaterialTheme.colorScheme.error,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center
                        )
                    }
                    Spacer(modifier = Modifier.height(20.dp))
                    Button(
                        onClick = onRetry,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("تلاش دوباره")
                    }
                }
            }
        }
    }
}

@Composable
private fun StartupLoadingBar(
    modifier: Modifier = Modifier
) {
    var progress = androidx.compose.runtime.remember { androidx.compose.runtime.mutableFloatStateOf(0.06f) }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        val startedAt = android.os.SystemClock.elapsedRealtime()
        while (true) {
            val elapsedSeconds =
                (android.os.SystemClock.elapsedRealtime() - startedAt) / 1000f
            // Time-based visual progress: it advances while initialization is in flight,
            // but intentionally never claims 100% before the real server state becomes Ready.
            val eased = 1f - kotlin.math.exp(-elapsedSeconds / 3.2f)
            progress.floatValue = (0.06f + eased * 0.90f).coerceAtMost(0.96f)
            kotlinx.coroutines.delay(32L)
        }
    }

    val stripeTransition = rememberInfiniteTransition(label = "startup_loader_stripes")
    val stripeOffset by stripeTransition.animateFloat(
        initialValue = 0f,
        targetValue = 40f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "startup_loader_stripe_offset"
    )

    Canvas(
        modifier = modifier
            .clipToBounds()
    ) {
        val trackHeight = 14.dp.toPx()
        val radius = trackHeight / 2f
        val top = (size.height - trackHeight) / 2f
        val left = 2.dp.toPx()
        val right = size.width - 2.dp.toPx()
        val trackWidth = max(0f, right - left)
        val fillRight = left + trackWidth * progress.floatValue.coerceIn(0f, 1f)

        drawRoundRect(
            color = Color(0xFF07182E),
            topLeft = Offset(left, top),
            size = androidx.compose.ui.geometry.Size(trackWidth, trackHeight),
            cornerRadius = CornerRadius(radius, radius)
        )

        val fillPath = Path().apply {
            addRoundRect(
                RoundRect(
                    rect = Rect(
                        left = left,
                        top = top,
                        right = fillRight,
                        bottom = top + trackHeight
                    ),
                    cornerRadius = CornerRadius(radius, radius)
                )
            )
        }

        clipPath(fillPath) {
            drawRoundRect(
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color(0xFF27E6FF),
                        Color(0xFF4DA3FF),
                        Color(0xFF7A5CFF),
                        Color(0xFFB44CFF)
                    ),
                    start = Offset(left, top),
                    end = Offset(right, top + trackHeight)
                ),
                topLeft = Offset(left, top),
                size = androidx.compose.ui.geometry.Size(
                    max(0f, fillRight - left),
                    trackHeight
                ),
                cornerRadius = CornerRadius(radius, radius)
            )

            val stripeWidth = 8.dp.toPx()
            val stripeStep = 28.dp.toPx()
            var x = left - trackHeight * 2f - stripeStep + stripeOffset

            while (x < fillRight + trackHeight * 2f) {
                drawLine(
                    color = Color.White.copy(alpha = 0.13f),
                    start = Offset(x, top + trackHeight * 1.65f),
                    end = Offset(x + trackHeight * 1.65f, top - trackHeight * 0.65f),
                    strokeWidth = stripeWidth,
                    cap = StrokeCap.Butt
                )
                x += stripeStep
            }
        }

        val indicatorX = fillRight
        val indicatorY = top - 17.dp.toPx()

        drawCircle(
            color = Color(0xFF43C8FF).copy(alpha = 0.13f),
            radius = 15.dp.toPx(),
            center = Offset(indicatorX, indicatorY)
        )
        drawCircle(
            color = Color(0xFF43C8FF).copy(alpha = 0.22f),
            radius = 9.dp.toPx(),
            center = Offset(indicatorX, indicatorY)
        )
        drawLine(
            color = Color(0xFF49D6FF).copy(alpha = 0.75f),
            start = Offset(indicatorX, indicatorY + 7.dp.toPx()),
            end = Offset(indicatorX, top - 1.dp.toPx()),
            strokeWidth = 2.dp.toPx(),
            cap = StrokeCap.Round
        )
        drawCircle(
            color = Color(0xFF7BE7FF),
            radius = 4.5.dp.toPx(),
            center = Offset(indicatorX, indicatorY)
        )
        drawCircle(
            color = Color.White.copy(alpha = 0.85f),
            radius = 1.45.dp.toPx(),
            center = Offset(indicatorX - 1.dp.toPx(), indicatorY - 1.3.dp.toPx())
        )
    }
}

@Composable
fun SiteBinBottomBar(
    currentScreen: AppScreen,
    onScreenSelected: (AppScreen) -> Unit,
    onStartViewing: () -> Unit
) {
    NavigationBar {
        // Home
        NavigationBarItem(
            selected = currentScreen == AppScreen.HOME,
            onClick = { onScreenSelected(AppScreen.HOME) },
            icon = {
                Icon(
                    imageVector = if (currentScreen == AppScreen.HOME) Icons.Filled.Home else Icons.Outlined.Home,
                    contentDescription = "خانه"
                )
            },
            label = { Text("خانه", fontWeight = FontWeight.SemiBold) }
        )

        // Earn / Viewer
        NavigationBarItem(
            selected = currentScreen == AppScreen.VIEWER,
            onClick = onStartViewing,
            icon = {
                Icon(
                    imageVector = if (currentScreen == AppScreen.VIEWER) Icons.Filled.Visibility else Icons.Outlined.Visibility,
                    contentDescription = "بازدید"
                )
            },
            label = { Text("بازدید", fontWeight = FontWeight.SemiBold) }
        )

        // Campaigns
        NavigationBarItem(
            selected = currentScreen == AppScreen.CAMPAIGNS || currentScreen == AppScreen.CREATE_CAMPAIGN,
            onClick = { onScreenSelected(AppScreen.CAMPAIGNS) },
            icon = {
                Icon(
                    imageVector = if (currentScreen == AppScreen.CAMPAIGNS) Icons.Filled.Language else Icons.Outlined.Language,
                    contentDescription = "سفارش‌ها"
                )
            },
            label = { Text("سفارش‌ها", fontWeight = FontWeight.SemiBold) }
        )

        // Wallet
        NavigationBarItem(
            selected = currentScreen == AppScreen.WALLET,
            onClick = { onScreenSelected(AppScreen.WALLET) },
            icon = {
                Icon(
                    imageVector = if (currentScreen == AppScreen.WALLET) Icons.Filled.MonetizationOn else Icons.Outlined.MonetizationOn,
                    contentDescription = "کیف پول"
                )
            },
            label = { Text("کیف پول", fontWeight = FontWeight.SemiBold) }
        )

        // Settings / Profile
        NavigationBarItem(
            selected = currentScreen == AppScreen.SETTINGS,
            onClick = { onScreenSelected(AppScreen.SETTINGS) },
            icon = {
                Icon(
                    imageVector = if (currentScreen == AppScreen.SETTINGS) Icons.Filled.AccountCircle else Icons.Outlined.AccountCircle,
                    contentDescription = "تنظیمات"
                )
            },
            label = { Text("تنظیمات", fontWeight = FontWeight.SemiBold) }
        )
    }
}
