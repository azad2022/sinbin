package com.example.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CardGiftcard
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MonetizationOn
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.data.model.CoinStoreProduct
import com.example.ui.theme.SiteBinBlue
import com.example.ui.theme.SiteBinGoldimport java.text.NumberFormat
import java.util.Locale

@Composable
fun CoinStoreScreen(
    isBusy: Boolean,
    onBuyCoins: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.Default.ChevronLeft, contentDescription = "بازگشت به کیف پول")
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp)
            ) {
                Text("فروشگاه سکه", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Black)
                Text(
                    "اعتبار بیشتر برای سفارش‌های تو",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Surface(shape = CircleShape, color = SiteBinGold.copy(alpha = 0.13f), modifier = Modifier.size(46.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.MonetizationOn, contentDescription = null, tint = SiteBinGold, modifier = Modifier.size(27.dp))
                }
            }
        }

        StoreHeroCard()

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.weight(1f)) {
                Text("بسته‌ات را انتخاب کن", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Black)
                Text(
                    "هر بسته یک‌بار پرداخت می‌شود و قابل خرید مجدد است.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Surface(shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
                Text(
                    "۴ بسته",
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        CoinStoreProduct.all.forEach { product ->
            CoinPackageCard(
                product = product,
                isBusy = isBusy,
                isRecommended = product.productId == "coins_50000",
                onBuy = { onBuyCoins(product.productId) }
            )
        }

        Surface(
            modifier = Modifier.fillMaxWidth(),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.65f),
            shape = RoundedCornerShape(16.dp)
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 13.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Icon(Icons.Default.Lock, contentDescription = null, tint = SiteBinBlue, modifier = Modifier.size(20.dp))
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("پرداخت از طریق کافه‌بازار", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold)
                    Text(
                        "سکه فقط پس از تأیید سرور به موجودی اضافه می‌شود.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
        Spacer(modifier = Modifier.height(10.dp))
    }
}

@Composable
private fun StoreHeroCard() {
    Card(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(28.dp)),
        shape = RoundedCornerShape(28.dp),
        colors = CardDefaults.cardColors(containerColor = Color.Transparent)
    ) {
        Box(
            modifier = Modifier.fillMaxWidth()
                .background(Brush.linearGradient(listOf(Color(0xFF10172D), Color(0xFF202B5A), Color(0xFF164E63))))
                .padding(22.dp)
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Surface(shape = RoundedCornerShape(10.dp), color = Color.White.copy(alpha = 0.12f)) {
                            Text(
                                "SITEBIN • COIN STORE",
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                                style = MaterialTheme.typography.labelSmall,
                                color = Color.White.copy(alpha = 0.92f),
                                fontWeight = FontWeight.Bold,
                                letterSpacing = 0.7.sp
                            )
                        }
                        Text(
                            "سکه بیشتر،\nفرصت بیشتر",
                            style = MaterialTheme.typography.headlineMedium,
                            fontWeight = FontWeight.Black,
                            color = Color.White,
                            lineHeight = 34.sp
                        )
                        Text(
                            "موجودی‌ات را شارژ کن و برای سفارش‌های بازدید آماده باش.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = Color.White.copy(alpha = 0.78f),
                            lineHeight = 22.sp
                        )
                    }
                    Surface(shape = CircleShape, color = SiteBinGold.copy(alpha = 0.17f), modifier = Modifier.size(86.dp)) {
                        Box(contentAlignment = Alignment.Center) {
                            Surface(shape = CircleShape, color = SiteBinGold.copy(alpha = 0.18f), modifier = Modifier.size(66.dp)) {
                                Box(contentAlignment = Alignment.Center) { Text("🪙", fontSize = 40.sp) }
                            }
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    HeroPill("پرداخت یک‌باره")
                    HeroPill("تحویل پس از تأیید")
                }
            }
        }
    }
}

@Composable
private fun HeroPill(text: String) {
    Surface(shape = CircleShape, color = Color.White.copy(alpha = 0.10f), border = BorderStroke(1.dp, Color.White.copy(alpha = 0.10f))) {
        Text(text, modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp), style = MaterialTheme.typography.labelSmall, color = Color.White.copy(alpha = 0.92f))
    }
}

@Composable
private fun CoinPackageCard(
    product: CoinStoreProduct,
    isBusy: Boolean,
    isRecommended: Boolean,
    onBuy: () -> Unit
) {
    val formatter = NumberFormat.getNumberInstance(Locale.US)
    val borderColor = if (isRecommended) SiteBinGold.copy(alpha = 0.75f)
    else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.65f)

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = BorderStroke(if (isRecommended) 1.5.dp else 1.dp, borderColor),
        elevation = CardDefaults.cardElevation(defaultElevation = if (isRecommended) 3.dp else 1.dp)
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(13.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Surface(
                    shape = RoundedCornerShape(17.dp),
                    color = if (isRecommended) SiteBinGold.copy(alpha = 0.18f) else SiteBinBlue.copy(alpha = 0.09f),
                    modifier = Modifier.size(54.dp)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            Icons.Default.CardGiftcard,
                            contentDescription = null,
                            tint = if (isRecommended) SiteBinGold else SiteBinBlue,
                            modifier = Modifier.size(27.dp)
                        )
                    }
                }
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("${formatter.format(product.coinAmount)} سکه", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Black)
                    Text(
                        if (isRecommended) "به‌صرفه‌ترین بسته" else "بسته سکه • خرید یک‌باره",
                        style = MaterialTheme.typography.bodySmall,
                        color = if (isRecommended) SiteBinGold else MaterialTheme.colorScheme.onSurfaceVariant,
                        fontWeight = if (isRecommended) FontWeight.Bold else FontWeight.Normal
                    )
                }
                if (isRecommended) {
                    Surface(shape = RoundedCornerShape(10.dp), color = SiteBinGold.copy(alpha = 0.13f)) {
                        Text(
                            "ارزش بیشتر",
                            modifier = Modifier.padding(horizontal = 9.dp, vertical = 6.dp),
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Bold,
                            color = SiteBinGold
                        )
                    }
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f))
                    .padding(horizontal = 13.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("قیمت", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("${formatter.format(product.priceRial)} ریال", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Black)
            }

            Button(
                onClick = onBuy,
                enabled = !isBusy,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(15.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (isRecommended) SiteBinGold else SiteBinBlue,
                    contentColor = if (isRecommended) Color(0xFF1F2937) else Color.White
                )
            ) {
                if (isBusy) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = if (isRecommended) Color(0xFF1F2937) else Color.White
                    )
                    Spacer(modifier = Modifier.width(9.dp))
                    Text("در حال آماده‌سازی خرید")
                } else {
                    Icon(Icons.Default.MonetizationOn, contentDescription = null, modifier = Modifier.size(19.dp))
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("خرید از کافه‌بازار", fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}
