package com.example

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.example.ui.AppScreen
import com.example.ui.SiteBinViewModel
import com.example.ui.ViewerState
import com.example.ui.screens.CampaignsScreen
import com.example.ui.screens.CreateCampaignScreen
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

    val currentScreen by viewModel.currentScreen.collectAsState()
    val account by viewModel.account.collectAsState()
    val campaigns by viewModel.campaigns.collectAsState()
    val transactions by viewModel.transactions.collectAsState()
    val viewerState by viewModel.viewerState.collectAsState()

    val snackbarHostState = remember { SnackbarHostState() }

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
                            HomeScreen(
                                account = account,
                                campaigns = campaigns,
                                onStartViewing = { viewModel.startViewing() },
                                onNavigate = { viewModel.navigateTo(it) }
                            )
                        }

                        AppScreen.VIEWER -> {
                            ViewerScreen(
                                viewerState = viewerState,
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
                                onNavigate = { screen -> viewModel.navigateTo(screen) }
                            )
                        }

                        AppScreen.SETTINGS -> {
                            val isDarkTheme by viewModel.isDarkTheme.collectAsState()
                            BackHandler { viewModel.navigateTo(AppScreen.HOME) }
                            SettingsScreen(
                                account = account,
                                isDarkTheme = isDarkTheme,
                                onToggleDarkTheme = { viewModel.setDarkTheme(it) },
                                onShowMessage = { viewModel.showMessage(it) }
                            )
                        }
                    }
                }
            }
        }
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
