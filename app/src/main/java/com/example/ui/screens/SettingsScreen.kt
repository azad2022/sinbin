package com.example.ui.screens

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
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
    modifier: Modifier = Modifier
) {
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

        // Account Identity Card
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
                        Box(modifier = Modifier.size(66.dp)) {
                            Surface(
                                shape = CircleShape,
                                color = SiteBinBlue.copy(alpha = 0.2f),
                                modifier = Modifier
                                    .size(50.dp)
                                    .align(Alignment.Center)
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
                                        .align(Alignment.BottomStart)
                                        .offset(x = 3.dp, y = 1.dp)
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
                            text = "شناسه کاربری شما",
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
                            text = "این شناسه را برای دریافت سکه با دیگران به اشتراک بگذارید.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }

                    HorizontalDivider(
                        modifier = Modifier.padding(vertical = 2.dp),
                        color = MaterialTheme.colorScheme.outline.copy(alpha = 0.25f)
                    )
                    AccountMetricsGrid(
                        account = account,
                        activeCampaignsCount = activeCampaignsCount
                    )
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

@Composable
private fun AccountMetricsGrid(
    account: UserAccount,
    activeCampaignsCount: Int
) {
    val formatter = java.text.NumberFormat.getNumberInstance(java.util.Locale.US)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("account_status_metrics"),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
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
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    color: Color,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
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
    val numeral = when (rank) {
        1 -> "۱"
        2 -> "۲"
        else -> "۳"
    }
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
