package com.example.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.MonetizationOn
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material.icons.filled.RocketLaunch
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.data.model.Campaign
import com.example.data.model.DailyBonusResult
import com.example.data.model.WeeklyLeaderboard
import com.example.data.model.UserAccount
import com.example.ui.AppScreen
import com.example.ui.theme.SiteBinBlue
import com.example.ui.theme.SiteBinBlueDark
import com.example.ui.theme.SiteBinGold
import com.example.ui.theme.SiteBinGoldLight
import com.example.ui.theme.SiteBinSuccess
import com.example.ui.theme.SiteBinTeal
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlinx.coroutines.delay

internal const val WELCOME_BONUS_BANNER_DURATION_MS = 2L * 60L * 60L * 1000L

internal fun isWelcomeBonusBannerVisible(
    grantedAtMillis: Long,
    nowMillis: Long
): Boolean =
    grantedAtMillis > 0L &&
        nowMillis >= grantedAtMillis &&
        nowMillis - grantedAtMillis < WELCOME_BONUS_BANNER_DURATION_MS

@Composable
fun HomeScreen(
    account: UserAccount,
    campaigns: List<Campaign>,
    welcomeBonusAmount: Long? = null,
    welcomeBonusGrantedAt: Long? = null,
    showWelcomeBonus: Boolean = false,
    showWelcomeCelebration: Boolean = false,
    onWelcomeCelebrationConsumed: () -> Unit = {},
    dailyBonus: DailyBonusResult? = null,
    weeklyLeaderboard: WeeklyLeaderboard? = null,
    showDailyBonusCelebration: Boolean = false,
    onDailyBonusCelebrationConsumed: () -> Unit = {},
    onStartViewing: () -> Unit,
    onNavigate: (AppScreen) -> Unit,
    modifier: Modifier = Modifier
) {
    val formatter = NumberFormat.getNumberInstance(Locale.US)
    var celebrationVisible by remember { mutableStateOf(showWelcomeCelebration) }
    var welcomeBonusBannerVisible by remember(welcomeBonusGrantedAt) {
        mutableStateOf(showWelcomeBonus)
    }

    LaunchedEffect(welcomeBonusGrantedAt, showWelcomeBonus) {
        val grantedAt = welcomeBonusGrantedAt
        val now = System.currentTimeMillis()
        if (
            !showWelcomeBonus ||
            grantedAt == null ||
            !isWelcomeBonusBannerVisible(grantedAt, now)
        ) {
            welcomeBonusBannerVisible = false
            return@LaunchedEffect
        }

        welcomeBonusBannerVisible = true
        val remainingMillis = (
            grantedAt + WELCOME_BONUS_BANNER_DURATION_MS - System.currentTimeMillis()
        ).coerceAtLeast(0L)

        if (remainingMillis > 0L) {
            delay(remainingMillis)
        }
        welcomeBonusBannerVisible = false
    }

    Box(modifier = modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item {
                Spacer(modifier = Modifier.height(8.dp))
                HomeHeader(account = account, onNavigate = onNavigate)
            }

            if (welcomeBonusBannerVisible && welcomeBonusAmount != null) {
                item {
                    WelcomeBonusBanner(
                        amount = welcomeBonusAmount,
                        onNavigate = onNavigate
                    )
                }
            }

            if (dailyBonus != null && dailyBonus.grantDate.isNotBlank()) {
                item {
                    DailyBonusBanner(
                        bonus = dailyBonus,
                        onNavigate = onNavigate
                    )
                }
            }

            item {
                ActionHeroCard(
                    title = "بازدید کسب کن",
                    subtitle = "با مشاهده وب‌سایت‌های دیگران سکه رایگان دریافت کن و به موجودی خودت اضافه کن.",
                    buttonText = "شروع مشاهده",
                    icon = Icons.Default.Visibility,
                    badgeText = "دریافت تا ۳۸+ سکه",
                    gradientColors = listOf(SiteBinBlue, Color(0xFF1D4ED8)),
                    testTag = "start_viewing_button",
                    onClick = onStartViewing
                )
            }

            item {
                ActionHeroCard(
                    title = "سایتت را تبلیغ کن",
                    subtitle = "با سکه‌های خود برای وب‌سایتت بازدید واقعی، هدفمند و بر اساس ثانیه دلخواه دریافت کن.",
                    buttonText = "ثبت سفارش بازدید",
                    icon = Icons.Default.RocketLaunch,
                    badgeText = "افزایش رتبه الکسا و سئو",
                    gradientColors = listOf(Color(0xFF0F766E), SiteBinTeal),
                    testTag = "create_campaign_button",
                    onClick = { onNavigate(AppScreen.CREATE_CAMPAIGN) }
                )
            }

            item {
                AccountMetricsGrid(
                    account = account,
                    activeCampaignsCount = campaigns.count { it.status.name == "ACTIVE" }
                )
            }

            item {
                WeeklyLeaderboardCard(
                    leaderboard = weeklyLeaderboard,
                    currentUserHandle = account.userHandle
                )
            }

            item {
                Spacer(modifier = Modifier.height(16.dp))
            }
        }

        if (celebrationVisible && welcomeBonusAmount != null) {
            WelcomeBonusCelebration(
                amount = welcomeBonusAmount,
                title = "هدیه خوش‌آمدگویی",
                emoji = "🎁",
                onDismiss = {
                    celebrationVisible = false
                    onWelcomeCelebrationConsumed()
                }
            )
        }

        if (showDailyBonusCelebration && dailyBonus?.granted == true) {
            WelcomeBonusCelebration(
                amount = dailyBonus.amount,
                title = "هدیه روزانه",
                emoji = "☀️",
                onDismiss = onDailyBonusCelebrationConsumed
            )
        }
    }
}

@Composable
private fun DailyBonusBanner(
    bonus: DailyBonusResult,
    onNavigate: (AppScreen) -> Unit
) {
    val grantedToday = bonus.granted
    val title = when {
        grantedToday -> "${NumberFormat.getNumberInstance(Locale.US).format(bonus.amount)} سکه هدیه روزانه دریافت شد"
        bonus.reason == "WELCOME_DAY" -> "هدیه روزانه از فردا فعال می‌شود"
        else -> "هدیه روزانه امروز قبلاً دریافت شده است"
    }
    val subtitle = when {
        grantedToday -> "این پاداش به‌صورت server-side ثبت شده و در کیف پول شما قرار گرفت."
        bonus.reason == "WELCOME_DAY" -> "در روز ثبت‌نام، فقط هدیه خوش‌آمدگویی تعلق می‌گیرد."
        else -> "برای دریافت مجدد، روز سرور باید تغییر کرده باشد."
    }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("daily_bonus_banner"),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.08f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { onNavigate(AppScreen.WALLET) }
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                modifier = Modifier.size(44.dp)
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(text = if (grantedToday) "🪙" else "☀️", fontSize = 21.sp)
                }
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    softWrap = false,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                )
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Icon(
                imageVector = Icons.Default.ArrowForward,
                contentDescription = "کیف پول",
                tint = MaterialTheme.colorScheme.primary
            )
        }
    }
}

@Composable
private fun WeeklyLeaderboardCard(
    leaderboard: WeeklyLeaderboard?,
    currentUserHandle: String
) {
    val formatter = NumberFormat.getNumberInstance(Locale.US)
    val entries = leaderboard?.entries.orEmpty()

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("weekly_leaderboard"),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "🏆 برترین بازدیدکنندگان این هفته",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Black
                    )
                    Text(
                        text = "بر اساس تعداد بازدیدهای موفق ثبت‌شده در سرور",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Surface(
                    shape = CircleShape,
                    color = SiteBinGold.copy(alpha = 0.14f),
                    modifier = Modifier.size(40.dp)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Text(text = "🏆", fontSize = 20.sp)
                    }
                }
            }

            when {
                leaderboard == null -> Text(
                    text = "در حال دریافت جدول این هفته…",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp)
                )
                entries.isEmpty() -> Text(
                    text = "هنوز بازدید موفقی برای این هفته ثبت نشده است.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp)
                )
                else -> {
                    entries.forEach { entry ->
                        val isCurrentUser = entry.userHandle.equals(currentUserHandle, ignoreCase = true)
                        val medal = when (entry.rank) {
                            1 -> "🥇"
                            2 -> "🥈"
                            3 -> "🥉"
                            else -> entry.rank.toString()
                        }

                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(16.dp),
                            color = if (isCurrentUser) {
                                MaterialTheme.colorScheme.primary.copy(alpha = 0.09f)
                            } else {
                                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                            }
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Box(
                                    modifier = Modifier.width(34.dp),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Text(
                                        text = medal,
                                        style = MaterialTheme.typography.titleMedium,
                                        fontWeight = FontWeight.Bold
                                    )
                                }
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = "کاربر ${entry.userHandle}",
                                        style = MaterialTheme.typography.bodyLarge,
                                        fontWeight = if (isCurrentUser) FontWeight.Bold else FontWeight.SemiBold,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                                    )
                                    if (isCurrentUser) {
                                        Text(
                                            text = "رتبه شما",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.primary
                                        )
                                    }
                                }
                                Column(horizontalAlignment = Alignment.End) {
                                    Text(
                                        text = formatter.format(entry.completedViews),
                                        style = MaterialTheme.typography.titleMedium,
                                        fontWeight = FontWeight.Black
                                    )
                                    Text(
                                        text = "بازدید موفق",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }
                    }
                }
            }

            HorizontalDivider()

            val rank = leaderboard?.currentUserRank
            val views = leaderboard?.currentUserViews ?: 0
            val gap = leaderboard?.viewsToNextRank

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = when {
                            rank == null -> "رتبه شما هنوز ثبت نشده"
                            else -> "رتبه شما: ${formatter.format(rank)}"
                        },
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        text = when {
                            rank == null -> "با اولین بازدید موفق وارد جدول می‌شوید."
                            rank == 1 -> "شما صدر جدول هستید."
                            gap != null -> "${formatter.format(gap)} بازدید تا رتبه ${formatter.format(rank - 1)}"
                            else -> "فاصله تا رتبه بالاتر محاسبه نشد."
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Surface(
                    shape = RoundedCornerShape(14.dp),
                    color = MaterialTheme.colorScheme.primary.copy(alpha = 0.10f)
                ) {
                    Text(
                        text = "${formatter.format(views)} بازدید",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun WelcomeBonusBanner(amount: Long, onNavigate: (AppScreen) -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(
            containerColor = SiteBinGold.copy(alpha = 0.12f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { onNavigate(AppScreen.WALLET) }
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Surface(
                shape = CircleShape,
                color = SiteBinGold.copy(alpha = 0.18f),
                modifier = Modifier.size(44.dp)
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(text = "🎁", fontSize = 22.sp)
                }
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "${NumberFormat.getNumberInstance(Locale.US).format(amount)} سکه هدیه ورود فعال شد",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    softWrap = false
                )
                Text(
                    text = "هدیه خوش‌آمدگویی در کیف پول شما ثبت شده است.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Icon(
                imageVector = Icons.Default.ArrowForward,
                contentDescription = "کیف پول",
                tint = SiteBinGold
            )
        }
    }
}

@Composable
private fun WelcomeBonusCelebration(
    amount: Long,
    title: String,
    emoji: String,
    onDismiss: () -> Unit
) {
    var overlayVisible by remember { mutableStateOf(true) }
    var cardVisible by remember { mutableStateOf(true) }

    LaunchedEffect(Unit) {
        delay(820)
        cardVisible = false
        delay(620)
        overlayVisible = false
        delay(220)
        onDismiss()
    }

    AnimatedVisibility(
        visible = overlayVisible,
        enter = fadeIn(animationSpec = tween(180)),
        exit = fadeOut(animationSpec = tween(220)),
        modifier = Modifier.fillMaxSize()
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.42f))
                .clickable(onClick = onDismiss)
        ) {
            val density = LocalDensity.current
            val particleProgress by animateFloatAsState(
                targetValue = 1f,
                animationSpec = tween(
                    durationMillis = 1250,
                    easing = FastOutSlowInEasing
                ),
                label = "welcome_coin_burst"
            )
            val giftScale by animateFloatAsState(
                targetValue = 1.10f,
                animationSpec = tween(620, easing = FastOutSlowInEasing),
                label = "welcome_gift_scale"
            )
            val giftLift by animateFloatAsState(
                targetValue = -8f,
                animationSpec = tween(620, easing = FastOutSlowInEasing),
                label = "welcome_gift_lift"
            )

            val widthPx = with(density) { maxWidth.toPx() }
            val heightPx = with(density) { maxHeight.toPx() }

            val particles = listOf(
                -0.46f to -0.40f,
                -0.34f to -0.48f,
                -0.18f to -0.43f,
                0.16f to -0.44f,
                0.34f to -0.49f,
                0.46f to -0.35f,
                -0.48f to 0.36f,
                -0.32f to 0.48f,
                -0.12f to 0.42f,
                0.14f to 0.46f,
                0.34f to 0.40f,
                0.48f to 0.30f
            )

            particles.forEachIndexed { index, (targetX, targetY) ->
                Text(
                    text = "🪙",
                    fontSize = if (index % 3 == 0) 24.sp else 18.sp,
                    modifier = Modifier
                        .align(Alignment.Center)
                        .graphicsLayer {
                            translationX = widthPx * targetX * particleProgress
                            translationY = heightPx * targetY * particleProgress
                            alpha = (1f - particleProgress).coerceAtLeast(0.02f)
                            rotationZ =
                                particleProgress * if (index % 2 == 0) 150f else -150f
                            scaleX = 0.85f + (0.25f * particleProgress)
                            scaleY = 0.85f + (0.25f * particleProgress)
                        }
                )
            }

            AnimatedVisibility(
                visible = cardVisible,
                enter = fadeIn(tween(240)) + androidx.compose.animation.scaleIn(
                    initialScale = 0.82f,
                    animationSpec = tween(360, easing = FastOutSlowInEasing)
                ),
                exit = fadeOut(tween(220)) + androidx.compose.animation.scaleOut(
                    targetScale = 0.86f,
                    animationSpec = tween(220, easing = FastOutSlowInEasing)
                ),
                modifier = Modifier.align(Alignment.Center)
            ) {
                Card(
                    modifier = Modifier.fillMaxWidth(0.86f),
                    shape = RoundedCornerShape(28.dp),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surface
                    ),
                    elevation = CardDefaults.cardElevation(defaultElevation = 12.dp)
                ) {
                    Column(
                        modifier = Modifier.padding(horizontal = 24.dp, vertical = 26.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text(
                            text = emoji,
                            fontSize = 64.sp,
                            modifier = Modifier.graphicsLayer {
                                scaleX = giftScale
                                scaleY = giftScale
                                translationY = giftLift
                            }
                        )
                        Text(
                            text = title,
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.Black,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center
                        )
                        Text(
                            text = "سکه‌ها با موفقیت به کیف پول شما اضافه شدند",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center
                        )
                        Surface(
                            shape = RoundedCornerShape(16.dp),
                            color = SiteBinGold.copy(alpha = 0.13f)
                        ) {
                            Text(
                                text = "🪙 +${NumberFormat.getNumberInstance(Locale.US).format(amount)} سکه",
                                style = MaterialTheme.typography.headlineSmall,
                                fontWeight = FontWeight.Black,
                                color = SiteBinGold,
                                modifier = Modifier.padding(horizontal = 18.dp, vertical = 8.dp),
                                maxLines = 1,
                                softWrap = false
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun HomeHeader(account: UserAccount, onNavigate: (AppScreen) -> Unit) {
    val formatter = NumberFormat.getNumberInstance(Locale.US)

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "SiteBin — سایت بین",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Black,
                color = MaterialTheme.colorScheme.onBackground,
                maxLines = 1,
                softWrap = false,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
            )
            Text(
                text = "پلتفرم تبادل ترافیک و سئو سایت",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                softWrap = false,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
            )
        }

        // Coin Balance Pill
        Surface(
            shape = RoundedCornerShape(24.dp),
            color = SiteBinGold.copy(alpha = 0.15f),
            border = CardDefaults.outlinedCardBorder().copy(brush = Brush.linearGradient(listOf(SiteBinGold, SiteBinGoldLight))),
            modifier = Modifier
                .clip(RoundedCornerShape(24.dp))
                .clickable { onNavigate(AppScreen.WALLET) }
                .testTag("coin_balance_header")
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Rotating3DIcon(
                    imageVector = Icons.Default.MonetizationOn,
                    contentDescription = "موجودی سکه",
                    tint = SiteBinGold,
                    size = 24.dp
                )
                Text(
                    text = formatter.format(account.availableCoins),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = SiteBinGold
                )
            }
        }
    }
}

@Composable
private fun ActionHeroCard(
    title: String,
    subtitle: String,
    buttonText: String,
    icon: ImageVector,
    badgeText: String,
    gradientColors: List<Color>,
    testTag: String,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp)),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = Color.Transparent)
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(Brush.linearGradient(gradientColors))
                .padding(20.dp)
        ) {
            Column {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // Badge
                    Surface(
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp),
                        color = Color.White.copy(alpha = 0.2f)
                    ) {
                        Text(
                            text = badgeText,
                            style = MaterialTheme.typography.labelSmall,
                            color = Color.White,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            softWrap = false,
                            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                        )
                    }

                    val iconScale by rememberInfiniteTransition(label = "action_hero_icon")
                        .animateFloat(
                            initialValue = 0.96f,
                            targetValue = 1.04f,
                            animationSpec = infiniteRepeatable(
                                animation = tween(
                                    durationMillis = 900,
                                    easing = FastOutSlowInEasing
                                ),
                                repeatMode = RepeatMode.Reverse
                            ),
                            label = "action_hero_icon_scale"
                        )

                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.85f),
                        modifier = Modifier
                            .size(28.dp)
                            .graphicsLayer {
                                scaleX = iconScale
                                scaleY = iconScale
                            }
                    )
                }

                Spacer(modifier = Modifier.height(12.dp))

                Text(
                    text = title,
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.ExtraBold,
                    color = Color.White
                )

                Spacer(modifier = Modifier.height(6.dp))

                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodyMedium,
                    color = Color.White.copy(alpha = 0.9f),
                    lineHeight = 22.sp
                )

                Spacer(modifier = Modifier.height(18.dp))

                Button(
                    onClick = onClick,
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color.White,
                        contentColor = gradientColors.first()
                    ),
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(testTag)
                ) {
                    Text(
                        text = buttonText,
                        fontWeight = FontWeight.Bold,
                        fontSize = 15.sp
                    )
                }
            }
        }
    }
}

@Composable
private fun AccountMetricsGrid(account: UserAccount, activeCampaignsCount: Int) {
    val formatter = NumberFormat.getNumberInstance(Locale.US)

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = "وضعیت حساب کاربری",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold
        )

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            MetricCard(
                title = "بازدیدهای انجام‌شده",
                value = formatter.format(account.completedViewsCount),
                icon = Icons.Default.RemoveRedEye,
                color = SiteBinBlue,
                modifier = Modifier.weight(1f)
            )

            MetricCard(
                title = "سفارش‌های فعال",
                value = formatter.format(activeCampaignsCount),
                icon = Icons.Default.Language,
                color = SiteBinTeal,
                modifier = Modifier.weight(1f)
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            MetricCard(
                title = "سکه رزرو شده",
                value = formatter.format(account.reservedCoins),
                icon = Icons.Default.MonetizationOn,
                color = SiteBinGold,
                modifier = Modifier.weight(1f)
            )

            MetricCard(
                title = "امتیاز اعتماد",
                value = "${account.trustScore.toInt()}%",
                icon = Icons.Default.Shield,
                color = SiteBinSuccess,
                modifier = Modifier.weight(1f)
            )
        }
    }
}

@Composable
private fun MetricCard(
    title: String,
    value: String,
    icon: ImageVector,
    color: Color,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
        )
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = color,
                    modifier = Modifier.size(18.dp)
                )
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                text = value,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
        }
    }
}
