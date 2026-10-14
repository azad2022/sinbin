package com.example.ui.screens

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.Gavel
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.MonetizationOn
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Security
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Icon
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.data.model.UserAccount
import com.example.data.model.WeeklyLeaderboard
import com.example.data.model.ReferralStatus
import com.example.ui.theme.SiteBinBlue
import com.example.ui.theme.SiteBinGold
import com.example.ui.theme.SiteBinGoldLight
import com.example.ui.theme.SiteBinTeal
import com.example.ui.theme.SiteBinSuccess

internal fun leaderboardMedalLabel(rank: Int?): String? = when (rank) {
    1 -> "مدال نفر اول لیدربورد"
    2 -> "مدال نفر دوم لیدربورد"
    3 -> "مدال نفر سوم لیدربورد"
    else -> null
}

internal fun leaderboardMedalNumeral(rank: Int): String = when (rank) {
    1 -> "1"
    2 -> "2"
    3 -> "3"
    else -> rank.toString()
}

@Composable
fun SettingsScreen(
    account: UserAccount,
    activeCampaignsCount: Int,
    weeklyLeaderboard: WeeklyLeaderboard?,
    isDarkTheme: Boolean,
    onToggleDarkTheme: (Boolean) -> Unit,
    notificationsEnabled: Boolean,
    onToggleNotifications: (Boolean) -> Unit,
    autoViewEnabled: Boolean,
    isUpdatingAutoView: Boolean,
    onToggleAutoView: (Boolean) -> Unit,
    onOpenHelp: () -> Unit,
    referralStatus: ReferralStatus? = null,
    isRefreshingReferralStatus: Boolean = false,
    referralStatusLoadFailed: Boolean = false,
    isRegisteringReferral: Boolean = false,
    onRegisterReferral: (String) -> Unit = {},
    onRefreshReferralStatus: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    var referralCode by remember { mutableStateOf("") }
    var showTermsDialog by remember { mutableStateOf(false) }
    var showPrivacyDialog by remember { mutableStateOf(false) }
    var showAboutDialog by remember { mutableStateOf(false) }
    val clipboardManager = LocalClipboardManager.current

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "تنظیمات",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold
            )
        }

        // Account identity details
        item {
            Card(
                shape = RoundedCornerShape(20.dp),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                ),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Box(modifier = Modifier.size(width = 66.dp, height = 84.dp)) {
                            Surface(
                                shape = CircleShape,
                                color = SiteBinBlue.copy(alpha = 0.2f),
                                modifier = Modifier
                                    .size(50.dp)
                                    .align(Alignment.TopCenter)
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(
                                        Icons.Default.AccountCircle,
                                        contentDescription = null,
                                        tint = SiteBinBlue,
                                        modifier = Modifier.size(32.dp)
                                    )
                                }
                            }

                            val medalRank = weeklyLeaderboard?.currentUserRank
                                ?.takeIf { leaderboardMedalLabel(it) != null }
                            if (medalRank != null) {
                                RankMedalBadge(
                                    rank = medalRank,
                                    label = leaderboardMedalLabel(medalRank).orEmpty(),
                                    modifier = Modifier
                                        .align(Alignment.TopCenter)
                                        .offset(y = 44.dp)
                                )
                            }
                        }

                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Text(
                                    text = "حساب فعال",
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.Bold
                                )
                                Surface(
                                    shape = RoundedCornerShape(8.dp),
                                    color = SiteBinSuccess.copy(alpha = 0.2f)
                                ) {
                                    Text(
                                        text = "فعال",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = SiteBinSuccess,
                                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                        fontWeight = FontWeight.Bold
                                    )
                                }
                            }
                            Text(
                                text = "حساب شما فعال است و اطلاعات سکه‌ها و سفارش‌ها با وضعیت سرور همگام می‌شوند.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }

                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.2f))
                    )

                    if (account.userHandle.isNotBlank()) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(1.dp)
                                .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.2f))
                        )
                        Text(
                            text = "شناسه کاربری و کد دعوت شما",
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.Bold
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Surface(
                                shape = RoundedCornerShape(12.dp),
                                color = MaterialTheme.colorScheme.background,
                                modifier = Modifier.weight(1f)
                            ) {
                                Text(
                                    text = account.userHandle,
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1
                                )
                            }
                            IconButton(
                                onClick = {
                                    clipboardManager.setText(AnnotatedString(account.userHandle))
                                },
                                modifier = Modifier.size(44.dp)
                            ) {
                                Icon(
                                    Icons.Default.ContentCopy,
                                    contentDescription = "کپی شناسه",
                                    modifier = Modifier.size(20.dp)
                                )
                            }
                        }
                        Text(
                            text = "این شناسه هم برای دریافت سکه و هم برای دعوت دوستان استفاده می‌شود.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }

                }
            }
        }

        // Account status dashboard — presentation only; values remain server-provided.
        item {
            AccountMetricsGrid(
                account = account,
                activeCampaignsCount = activeCampaignsCount,
                referralStatus = referralStatus,
                isDarkTheme = isDarkTheme
            )
        }

        // Referral registration and progress remain independent from account metrics.
        item {
            Card(
                shape = RoundedCornerShape(20.dp),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                ),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(
                            text = "دعوت دوستان و پاداش‌ها",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold
                        )
                        Text(
                            text = "شناسه‌تان را با دوستان به اشتراک بگذارید. آن‌ها می‌توانند از بازدیدهای معتبر سکه بگیرند و با تکمیل دو هدف دعوت، هر دو پاداش دریافت کنید.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )

                        if (shouldShowReferralCodeEntry(referralStatus)) {
                            when {
                                isRefreshingReferralStatus && referralStatus == null -> {
                                    Row(
                                        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                                    ) {
                                        CircularProgressIndicator(
                                            modifier = Modifier.size(18.dp),
                                            strokeWidth = 2.dp
                                        )
                                        Text(
                                            "در حال دریافت آمار دعوت…",
                                            style = MaterialTheme.typography.bodySmall
                                        )
                                    }
                                }
                                referralStatusLoadFailed && referralStatus == null -> {
                                    Text(
                                        text = "دریافت آمار دعوت ناموفق بود؛ اما می‌توانید کد دعوت را وارد کنید.",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.error
                                    )
                                    TextButton(
                                        onClick = onRefreshReferralStatus,
                                        enabled = !isRefreshingReferralStatus
                                    ) { Text("تلاش مجدد برای آمار") }
                                }
                                referralStatus == null -> {
                                    Text(
                                        text = "آمار دعوت هنوز دریافت نشده است. برای ثبت دعوت، شناسه دوستتان را در همین کادر وارد کنید.",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                else -> {
                                    Text(
                                        text = "شما هنوز دعوت‌کننده‌ای ثبت نکرده‌اید. پس از ثبت موفق، امکان تغییر آن وجود ندارد.",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }

                            OutlinedTextField(
                                value = referralCode,
                                onValueChange = { referralCode = it },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .testTag("referral_code_input"),
                                label = { Text("کد دعوت دوستت را وارد کن") },
                                placeholder = { Text("شناسه کاربری دوستتان") },
                                singleLine = true,
                                enabled = !isRegisteringReferral
                            )
                            Button(
                                onClick = { onRegisterReferral(referralCode) },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .testTag("referral_code_submit"),
                                enabled = referralCode.isNotBlank() &&
                                    !isRegisteringReferral
                            ) {
                                if (isRegisteringReferral) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(16.dp),
                                        strokeWidth = 2.dp
                                    )
                                    Spacer(modifier = Modifier.width(8.dp))
                                }
                                Text(
                                    if (isRegisteringReferral) "در حال ثبت…" else "ثبت کد دعوت"
                                )
                            }
                        } else {
                            val status = requireNotNull(referralStatus)
                            val membership = requireNotNull(status.myReferral)
                            Text(
                                text = "دعوت‌کننده شما: " + membership.inviterHandle,
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.SemiBold
                            )
                            Text(
                                text = "رابطه دعوت ثبت و قفل شده است؛ بازدیدهای پیش از ثبت دعوت محاسبه نمی‌شوند.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            ReferralProgressRow(
                                title = "بازدید معتبر تکمیل‌شده",
                                count = membership.completedViewsCount,
                                target = 100
                            )
                            ReferralProgressRow(
                                title = "وب‌سایت متفاوت",
                                count = membership.uniqueWebsitesCount,
                                target = 500
                            )
                            Text(
                                text = "پاداش ۱۰۰ بازدید: " +
                                    if (membership.tier100Paid) "پرداخت شد" else "در انتظار تکمیل شرط",
                                style = MaterialTheme.typography.bodySmall,
                                color = if (membership.tier100Paid) SiteBinSuccess
                                else MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Text(
                                text = "پاداش ۵۰۰ وب‌سایت متفاوت: " +
                                    if (membership.tier500Paid) "پرداخت شد" else "در انتظار تکمیل شرط",
                                style = MaterialTheme.typography.bodySmall,
                                color = if (membership.tier500Paid) SiteBinSuccess
                                else MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }


                    }
                }
            }
        }

        // Section: Preferences
        item {
            Text(
                text = "تنظیمات عمومی",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold
            )
        }

        item {
            Card(
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column {
                    SettingsToggleRow(
                        icon = Icons.Default.DarkMode,
                        title = "حالت شب (Dark Theme)",
                        subtitle = if (isDarkTheme) "تم تیره فعال است" else "تم روشن (روز) فعال است",
                        checked = isDarkTheme,
                        onCheckedChange = onToggleDarkTheme
                    )

                    SettingsToggleRow(
                        icon = Icons.Default.Notifications,
                        title = "اعلان‌های واریز سکه",
                        subtitle = "اطلاع‌رسانی هنگام دریافت سکه",
                        checked = notificationsEnabled,
                        onCheckedChange = onToggleNotifications
                    )

                    SettingsToggleRow(
                        icon = Icons.Default.Autorenew,
                        title = "بازدید خودکار",
                        subtitle = "با کسر صد سکه برای یک هفته",
                        checked = autoViewEnabled,
                        enabled = !isUpdatingAutoView,
                        onCheckedChange = onToggleAutoView
                    )
                }
            }
        }

        // Section: Help
        item {
            Text(
                text = "راهنما",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold
            )
        }

        item {
            Card(
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)),
                modifier = Modifier.fillMaxWidth()
            ) {
                SettingsClickableRow(
                    icon = Icons.Default.MenuBook,
                    title = "راهنمای نرم‌افزار",
                    subtitle = "راهنمای کامل سکه‌ها، بازدید، سفارش، کلمه کلیدی و امکانات برنامه",
                    onClick = onOpenHelp
                )
            }
        }

        // Section: Legal & About
        item {
            Text(
                text = "قوانین و امنیت پلتفرم",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold
            )
        }

        item {
            Card(
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column {
                    SettingsClickableRow(
                        icon = Icons.Default.Gavel,
                        title = "قوانین استفاده از SiteBin",
                        onClick = { showTermsDialog = true }
                    )

                    SettingsClickableRow(
                        icon = Icons.Default.Security,
                        title = "امنیت و حریم خصوصی",
                        onClick = { showPrivacyDialog = true }
                    )

                    SettingsClickableRow(
                        icon = Icons.Default.Info,
                        title = "درباره SiteBin (سایت بین)",
                        onClick = { showAboutDialog = true }
                    )
                }
            }
        }

        item {
            Spacer(modifier = Modifier.height(24.dp))
        }
    }

    if (showTermsDialog) {
        AlertDialog(
            onDismissRequest = { showTermsDialog = false },
            title = { Text("قوانین و مقررات SiteBin", fontWeight = FontWeight.Bold) },
            text = {
                Text(
                    "۱. ثبت هرگونه لینک به کانال‌های تلگرام، اپ‌استورها یا دانلود مستقیم فایل APK اکیداً ممنوع و به صورت خودکار مسدود می‌شود.\n\n" +
                    "۲. سکه‌ها صرفاً برای ثبت بازدید داخلی معتبر بوده و خرید و فروش آزاد آن منوط به ضوابط سرور است.\n\n" +
                    "۳. هرگونه دور زدن تایمر، استفاده از شبیه‌سازها یا دستکاری ترافیک منجر به کسر امتیاز اعتماد و مسدودسازی سشن می‌گردد.\n\n" +
                    "۴. ثبت هرگونه لینک +۱۸ ممنوع است.\n\n" +
                    "۵. ثبت هرگونه لینک با محتوای سیاسی یا خلاف شرع ممنوع است.\n\n" +
                    "۶. ثبت آگهی‌های دیوار و شیپور ممنوع است."
                )
            },
            confirmButton = {
                TextButton(onClick = { showTermsDialog = false }) { Text("متوجه شدم") }
            }
        )
    }

    if (showPrivacyDialog) {
        AlertDialog(
            onDismissRequest = { showPrivacyDialog = false },
            title = { Text("حریم خصوصی و امنیت وب‌ویو", fontWeight = FontWeight.Bold) },
            text = {
                Text(
                    "محیط وب‌ویوی SiteBin در یک سندباکس کاملاً ایزوله اجرا می‌شود:\n\n" +
                    "• هیچ وب‌سایتی به اطلاعات دستگاه، دوربین، میکروفون یا فایل‌های محلی شما دسترسی ندارد.\n" +
                    "• ریدایرکت‌های مشکوک به تلگرام یا استورهای خارجی بلافاصله مسدود می‌شوند.\n" +
                    "• هیچگونه دانلود فایلی در پس‌زمینه انجام نخواهد شد."
                )
            },
            confirmButton = {
                TextButton(onClick = { showPrivacyDialog = false }) { Text("تایید") }
            }
        )
    }

    if (showAboutDialog) {
        AlertDialog(
            onDismissRequest = { showAboutDialog = false },
            title = { Text("درباره SiteBin", fontWeight = FontWeight.Bold) },
            text = {
                Text(
                    "SiteBin — سایت بین\n" +
                    "نسخه: 1.0.0\n\n" +
                    "پلتفرم تبادل ترافیک و ارتقای وب‌سایت با معماری مدرن اندروید، Jetpack Compose و امنیت سرور-محور."
                )
            },
            confirmButton = {
                TextButton(onClick = { showAboutDialog = false }) { Text("بستن") }
            }
        )
    }


}

private data class AccountStatusPalette(
    val hero: Color,
    val card: Color,
    val border: Color,
    val text: Color,
    val muted: Color,
    val blueAccent: Color,
    val mint: Color,
    val ringTrack: Color,
    val gold: Color,
    val rewardIconBackground: Color,
    val directInvitesIconBackground: Color
)

private fun accountStatusPalette(isDarkTheme: Boolean): AccountStatusPalette =
    if (isDarkTheme) {
        AccountStatusPalette(
            hero = Color(0xFF203158),
            card = Color(0xFF171D30),
            border = Color(0xFF2A3450),
            text = Color(0xFFF7F8FC),
            muted = Color(0xFF9EA8BF),
            blueAccent = Color(0xFF7CA4FF),
            mint = Color(0xFF2BD3A2),
            ringTrack = Color(0xFF344361),
            gold = Color(0xFFFFC341),
            rewardIconBackground = Color(0xFF12352F),
            directInvitesIconBackground = Color(0xFF0D1428)
        )
    } else {
        AccountStatusPalette(
            hero = Color(0xFFFFFFFF),
            card = Color(0xFFFFFFFF),
            border = Color(0xFFE2E8F0),
            text = Color(0xFF172033),
            muted = Color(0xFF64748B),
            blueAccent = Color(0xFF315FCB),
            mint = Color(0xFF0F9D78),
            ringTrack = Color(0xFFDCE4EF),
            gold = Color(0xFFF5BE3D),
            rewardIconBackground = Color(0xFFE8F8F1),
            directInvitesIconBackground = Color(0xFFEEF4FF)
        )
    }

@Composable
private fun AccountMetricsGrid(
    account: UserAccount,
    activeCampaignsCount: Int,
    referralStatus: ReferralStatus?,
    isDarkTheme: Boolean
) {
    val palette = accountStatusPalette(isDarkTheme)
    val formatter = java.text.NumberFormat.getNumberInstance(java.util.Locale.US)
    val directInviteCount = referralStatus?.directInviteCount?.let(formatter::format) ?: "—"
    val tier100Count = referralStatus?.directTier100CompletedCount?.let(formatter::format) ?: "—"
    val tier500Count = referralStatus?.directTier500CompletedCount?.let(formatter::format) ?: "—"
    val referralCoins = referralStatus?.referralCoinsEarned?.let(formatter::format) ?: "—"
    val trustScore = account.trustScore.toInt().coerceIn(0, 100)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("account_status_metrics"),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Text(
            text = "وضعیت حساب کاربری",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold
        )

        AccountStatusHeroCard(
            reservedCoins = formatter.format(account.reservedCoins),
            trustScore = trustScore,
            palette = palette
        )

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            AccountStatusMetricCard(
                title = "بازدید انجام‌شده",
                value = formatter.format(account.completedViewsCount),
                palette = palette,
                modifier = Modifier.weight(1f)
            )
            AccountStatusMetricCard(
                title = "سفارش فعال",
                value = formatter.format(activeCampaignsCount),
                palette = palette,
                modifier = Modifier.weight(1f)
            )
        }

        AccountStatusRewardsCard(
            tier100Count = tier100Count,
            tier500Count = tier500Count,
            referralCoins = referralCoins,
            palette = palette
        )

        AccountStatusDirectInvitesCard(
            directInviteCount = directInviteCount,
            palette = palette
        )
    }
}

@Composable
private fun AccountStatusHeroCard(
    reservedCoins: String,
    trustScore: Int,
    palette: AccountStatusPalette
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("account_status_balance_card"),
        shape = RoundedCornerShape(28.dp),
        colors = CardDefaults.cardColors(containerColor = palette.hero),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp, vertical = 20.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Surface(
                        shape = CircleShape,
                        color = palette.gold,
                        modifier = Modifier.size(34.dp)
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(
                                imageVector = Icons.Default.MonetizationOn,
                                contentDescription = null,
                                tint = palette.text,
                                modifier = Modifier.size(22.dp)
                            )
                        }
                    }
                    Text(
                        text = "سکه رزرو شده",
                        style = MaterialTheme.typography.bodyMedium,
                        color = palette.muted
                    )
                }
                Text(
                    text = reservedCoins,
                    style = MaterialTheme.typography.headlineLarge.copy(fontSize = 40.sp),
                    fontWeight = FontWeight.Bold,
                    color = palette.text,
                    maxLines = 1,
                    softWrap = false,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                )
            }

            AccountStatusTrustRing(
                score = trustScore,
                palette = palette,
                modifier = Modifier.padding(start = 8.dp)
            )
        }
    }
}

@Composable
private fun AccountStatusTrustRing(
    score: Int,
    palette: AccountStatusPalette,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier.size(86.dp),
        contentAlignment = Alignment.Center
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val ringWidth = 7.dp.toPx()
            drawArc(
                color = palette.ringTrack,
                startAngle = -90f,
                sweepAngle = 360f,
                useCenter = false,
                style = Stroke(width = ringWidth)
            )
            if (score > 0) {
                drawArc(
                    color = palette.mint,
                    startAngle = -90f,
                    sweepAngle = 360f * (score / 100f),
                    useCenter = false,
                    style = Stroke(width = ringWidth, cap = StrokeCap.Round)
                )
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = "$score%",
                style = MaterialTheme.typography.titleLarge.copy(fontSize = 21.sp),
                fontWeight = FontWeight.Bold,
                color = palette.text
            )
            Text(
                text = "امتیاز اعتماد",
                style = MaterialTheme.typography.labelSmall.copy(fontSize = 9.sp),
                color = palette.muted,
                maxLines = 1,
                softWrap = false
            )
        }
    }
}

@Composable
private fun AccountStatusMetricCard(
    title: String,
    value: String,
    palette: AccountStatusPalette,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier.height(118.dp),
        shape = RoundedCornerShape(22.dp),
        border = BorderStroke(1.dp, palette.border),
        colors = CardDefaults.cardColors(containerColor = palette.card),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 14.dp, vertical = 13.dp),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                color = palette.muted,
                maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
            )
            Box(
                modifier = Modifier
                    .width(28.dp)
                    .height(4.dp)
                    .clip(RoundedCornerShape(50))
                    .background(palette.blueAccent)
            )
            Text(
                text = value,
                style = MaterialTheme.typography.headlineMedium.copy(fontSize = 34.sp),
                fontWeight = FontWeight.Bold,
                color = palette.text,
                maxLines = 1,
                softWrap = false,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
private fun AccountStatusRewardsCard(
    tier100Count: String,
    tier500Count: String,
    referralCoins: String,
    palette: AccountStatusPalette
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("account_status_rewards"),
        shape = RoundedCornerShape(24.dp),
        border = BorderStroke(1.dp, palette.border),
        colors = CardDefaults.cardColors(containerColor = palette.card),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Surface(
                    shape = RoundedCornerShape(14.dp),
                    color = palette.rewardIconBackground,
                    modifier = Modifier.size(46.dp)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = Icons.Default.MonetizationOn,
                            contentDescription = null,
                            tint = palette.mint,
                            modifier = Modifier.size(26.dp)
                        )
                    }
                }
                Text(
                    text = "پاداش‌ها",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = palette.text
                )
            }

            Spacer(modifier = Modifier.height(4.dp))
            AccountStatusRewardRow(title = "پاداش ۱۰۰ بازدید", value = tier100Count, palette = palette)
            HorizontalDivider(color = palette.border)
            AccountStatusRewardRow(title = "پاداش ۵۰۰ سایت متفاوت", value = tier500Count, palette = palette)
            HorizontalDivider(color = palette.border)
            AccountStatusRewardRow(title = "کل پاداش دعوت", value = referralCoins, palette = palette)
        }
    }
}

@Composable
private fun AccountStatusRewardRow(
    title: String,
    value: String,
    palette: AccountStatusPalette
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = title,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyMedium,
            color = palette.muted,
            maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
        )
        Text(
            text = value,
            style = MaterialTheme.typography.titleLarge.copy(fontSize = 22.sp),
            fontWeight = FontWeight.Bold,
            color = palette.text,
            maxLines = 1,
            softWrap = false
        )
    }
}

@Composable
private fun AccountStatusDirectInvitesCard(
    directInviteCount: String,
    palette: AccountStatusPalette
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("account_status_direct_invites"),
        shape = RoundedCornerShape(24.dp),
        border = BorderStroke(1.dp, palette.border),
        colors = CardDefaults.cardColors(containerColor = palette.card),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                palette = palette,
                modifier = Modifier.weight(1f)
            ) {
                Surface(
                    shape = CircleShape,
                    color = palette.directInvitesIconBackground,
                    modifier = Modifier.size(50.dp)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = Icons.Default.AccountCircle,
                            contentDescription = null,
                            tint = palette.blueAccent,
                            modifier = Modifier.size(28.dp)
                        )
                    }
                }
                Text(
                    text = "تعداد دعوت مستقیم",
                    style = MaterialTheme.typography.bodyLarge,
                    color = palette.muted,
                    maxLines = 2,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                )
            }
            Text(
                text = directInviteCount,
                style = MaterialTheme.typography.headlineMedium.copy(fontSize = 34.sp),
                fontWeight = FontWeight.Bold,
                color = palette.text,
                maxLines = 1,
                softWrap = false,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
private fun RankMedalBadge(
    rank: Int,
    label: String,
    modifier: Modifier = Modifier
) {
    val swingAngle by rememberInfiniteTransition(label = "account_medal_swing")
        .animateFloat(
            initialValue = -9f,
            targetValue = 9f,
            animationSpec = infiniteRepeatable(
                animation = tween(
                    durationMillis = 1_050,
                    easing = FastOutSlowInEasing
                ),
                repeatMode = RepeatMode.Reverse
            ),
            label = "account_medal_angle"
        )

    val medalColor = when (rank) {
        1 -> Color(0xFFFFC83D)
        2 -> Color(0xFFC8D0DA)
        else -> Color(0xFFCB8B5B)
    }
    val rimColor = when (rank) {
        1 -> Color(0xFFFFE9A8)
        2 -> Color(0xFFF4F6F9)
        else -> Color(0xFFEAC6A4)
    }
    val ribbonColor = when (rank) {
        1 -> Color(0xFFC62828)
        2 -> Color(0xFF34536D)
        else -> Color(0xFF6D3D2F)
    }
    val numeral = leaderboardMedalNumeral(rank)
    val numeralColor = when (rank) {
        1 -> Color(0xFF5D3A00)
        2 -> Color(0xFF293541)
        else -> Color(0xFF4D291C)
    }

    Box(
        modifier = modifier
            .size(width = 32.dp, height = 40.dp)
            .graphicsLayer {
                rotationZ = swingAngle
                transformOrigin = TransformOrigin(0.5f, 0.02f)
            }
            .semantics { contentDescription = label }
            .testTag("leaderboard_medal_rank_$rank")
    ) {
        Box(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .offset(x = (-4).dp, y = 1.dp)
                .rotate(-14f)
                .size(width = 9.dp, height = 21.dp)
                .background(ribbonColor, RoundedCornerShape(bottomStart = 3.dp, bottomEnd = 3.dp))
        )
        Box(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .offset(x = 4.dp, y = 1.dp)
                .rotate(14f)
                .size(width = 9.dp, height = 21.dp)
                .background(ribbonColor.copy(alpha = 0.82f), RoundedCornerShape(bottomStart = 3.dp, bottomEnd = 3.dp))
        )
        Surface(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .size(28.dp),
            shape = CircleShape,
            color = medalColor,
            contentColor = numeralColor,
            border = BorderStroke(1.5.dp, rimColor),
            shadowElevation = 4.dp
        ) {
            Box(contentAlignment = Alignment.Center) {
                Text(
                    text = numeral,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Black,
                    color = numeralColor
                )
            }
        }
    }
}

internal fun shouldShowReferralCodeEntry(status: ReferralStatus?): Boolean =
    status?.myReferral == null

@Composable
private fun ReferralProgressRow(
    title: String,
    count: Int,
    target: Int
) {
    val safeCount = count.coerceAtLeast(0)
    val progress = (safeCount.toFloat() / target.toFloat()).coerceIn(0f, 1f)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(title, style = MaterialTheme.typography.bodySmall)
            Text(
                safeCount.coerceAtMost(target).toString() + " / " + target,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold
            )
        }
        LinearProgressIndicator(
            progress = progress,
            modifier = Modifier.fillMaxWidth()
        )
    }
}

@Composable
private fun SettingsToggleRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    checked: Boolean,
    enabled: Boolean = true,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Icon(imageVector = icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Column {
                Text(text = title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                Text(text = subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange, enabled = enabled)
    }
}

@Composable
private fun SettingsClickableRow(
    icon: ImageVector,
    title: String,
    subtitle: String? = null,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.weight(1f)
        ) {
            Icon(imageVector = icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Column {
                Text(text = title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                if (subtitle != null) {
                    Spacer(modifier = Modifier.height(2.dp))
                    Text(text = subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        Icon(Icons.Default.ChevronLeft, contentDescription = null, tint = MaterialTheme.colorScheme.outline)
    }
}
