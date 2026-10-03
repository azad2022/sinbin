package com.example.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.data.model.Campaign
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

@Composable
fun HomeScreen(
    account: UserAccount,
    campaigns: List<Campaign>,
    onStartViewing: () -> Unit,
    onNavigate: (AppScreen) -> Unit,
    modifier: Modifier = Modifier
) {
    val formatter = NumberFormat.getNumberInstance(Locale.US)

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            Spacer(modifier = Modifier.height(8.dp))
            // Top App Bar / Balance Section
            HomeHeader(account = account, onNavigate = onNavigate)
        }

        item {
            // Main Hero Card 1: Earn Coins by Viewing Sites
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
            // Main Hero Card 2: Promote Your Own Website
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
            // Account Performance Summary Grid
            AccountMetricsGrid(account = account, activeCampaignsCount = campaigns.count { it.status.name == "ACTIVE" })
        }

        item {
            // Recent Campaigns Section Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "سفارش‌های اخیر شما",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
                if (campaigns.isNotEmpty()) {
                    Text(
                        text = "مشاهده همه",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .clickable { onNavigate(AppScreen.CAMPAIGNS) }
                            .padding(4.dp)
                    )
                }
            }
        }

        if (campaigns.isEmpty()) {
            item {
                EmptyCampaignsBanner(onAddCampaign = { onNavigate(AppScreen.CREATE_CAMPAIGN) })
            }
        } else {
            items(campaigns.take(3)) { campaign ->
                CampaignMiniCard(campaign = campaign, onClick = { onNavigate(AppScreen.CAMPAIGNS) })
            }
        }

        item {
            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}

@Composable
private fun HomeHeader(account: UserAccount, onNavigate: (AppScreen) -> Unit) {
    val formatter = NumberFormat.getNumberInstance(Locale.US)

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column {
            Text(
                text = "SiteBin — سایت بین",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Black,
                color = MaterialTheme.colorScheme.onBackground
            )
            Text(
                text = "پلتفرم تبادل ترافیک و سئو سایت",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
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
                Text(
                    text = "🪙",
                    fontSize = 18.sp
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
                        shape = RoundedCornerShape(12.dp),
                        color = Color.White.copy(alpha = 0.2f)
                    ) {
                        Text(
                            text = badgeText,
                            style = MaterialTheme.typography.labelSmall,
                            color = Color.White,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                            fontWeight = FontWeight.SemiBold
                        )
                    }

                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.85f),
                        modifier = Modifier.size(28.dp)
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

@Composable
private fun EmptyCampaignsBanner(onAddCampaign: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
        )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Icon(
                imageVector = Icons.Default.Language,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(36.dp)
            )
            Text(
                text = "هنوز سفارشی برای سایتت ثبت نکرده‌ای",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = "با سکه‌های خودت اولین کمپین بازدید را در چند ثانیه بساز.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            OutlinedButton(
                onClick = onAddCampaign,
                shape = RoundedCornerShape(12.dp)
            ) {
                Icon(Icons.Default.AddCircle, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(modifier = Modifier.width(6.dp))
                Text("ثبت اولین سفارش")
            }
        }
    }
}

@Composable
private fun CampaignMiniCard(campaign: Campaign, onClick: () -> Unit) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = campaign.domain,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "${campaign.completedViews} از ${campaign.targetViews} بازدید • ${campaign.durationSeconds} ثانیه",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = SiteBinSuccess.copy(alpha = 0.15f)
            ) {
                Text(
                    text = campaign.status.labelFarsi,
                    style = MaterialTheme.typography.labelSmall,
                    color = SiteBinSuccess,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                    fontWeight = FontWeight.Bold
                )
            }
        }
    }
}
