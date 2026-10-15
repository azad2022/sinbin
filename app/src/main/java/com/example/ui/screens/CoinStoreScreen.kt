package com.example.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.scaleIn
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.example.R
import com.example.data.model.CoinStoreProduct
import com.example.ui.theme.SiteBinBlue
import com.example.ui.theme.SiteBinGold
import java.text.NumberFormat
import java.util.Locale

private val StoreInk = Color(0xFF10172F)
private val StoreViolet = Color(0xFF635BEE)
private val StoreVioletDeep = Color(0xFF3630A3)
private val StoreGreen = Color(0xFF0EA960)
private val StoreMuted = Color(0xFF718096)

@Composable
fun CoinStoreScreen(
    isBusy: Boolean,
    onBuyCoins: (String) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    var selectedProductId by remember { mutableStateOf("coins_50000") }
    val selectedProduct = CoinStoreProduct.find(selectedProductId) ?: CoinStoreProduct.all.last()
    val formatter = remember { NumberFormat.getNumberInstance(Locale.US) }

    Dialog(
        onDismissRequest = { if (!isBusy) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
        ) {
            val maxDialogHeight = maxHeight * 0.92f
            AnimatedVisibility(
                visible = true,
                enter = fadeIn(animationSpec = tween(180)) +
                    scaleIn(initialScale = 0.94f, animationSpec = tween(220))
            ) {
                Card(
                    modifier = modifier
                        .fillMaxWidth()
                        .heightIn(max = maxDialogHeight)
                        .testTag("coin_store_dialog"),
                    shape = RoundedCornerShape(30.dp),
                    colors = CardDefaults.cardColors(containerColor = Color(0xFFFCFCFF)),
                    elevation = CardDefaults.cardElevation(defaultElevation = 20.dp)
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = maxDialogHeight)
                            .padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(13.dp)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Column(
                                modifier = Modifier.weight(1f),
                                verticalArrangement = Arrangement.spacedBy(2.dp)
                            ) {
                                Text(
                                    text = "فروشگاه سکه",
                                    style = MaterialTheme.typography.titleLarge,
                                    fontWeight = FontWeight.Black,
                                    color = StoreInk
                                )
                                Text(
                                    text = "بسته مناسب خودت را انتخاب کن",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = StoreMuted
                                )
                            }
                            Surface(
                                shape = CircleShape,
                                color = Color(0xFFF0EEFF),
                                modifier = Modifier.size(42.dp)
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(
                                        imageVector = Icons.Default.MonetizationOn,
                                        contentDescription = null,
                                        tint = StoreViolet,
                                        modifier = Modifier.size(24.dp)
                                    )
                                }
                            }
                            IconButton(
                                onClick = onDismiss,
                                enabled = !isBusy,
                                modifier = Modifier.size(38.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Close,
                                    contentDescription = "بستن فروشگاه",
                                    tint = StoreMuted,
                                    modifier = Modifier.size(21.dp)
                                )
                            }
                        }

                        StoreHero()

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text(
                                text = "انتخاب بسته",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Black,
                                color = StoreInk
                            )
                            Text(
                                text = "۴ بسته",
                                style = MaterialTheme.typography.labelMedium,
                                color = StoreMuted
                            )
                        }

                        LazyColumn(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            items(CoinStoreProduct.all, key = { it.productId }) { product ->
                                CoinPackageOption(
                                    product = product,
                                    selected = product.productId == selectedProductId,
                                    enabled = !isBusy,
                                    numberFormatter = formatter,
                                    onSelect = { selectedProductId = product.productId }
                                )
                            }
                        }

                        Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 3.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text(
                                        text = "مبلغ قابل پرداخت",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = StoreMuted
                                    )
                                    Text(
                                        text = formatter.format(selectedProduct.priceToman) + " تومان",
                                        style = MaterialTheme.typography.titleLarge,
                                        fontWeight = FontWeight.Black,
                                        color = StoreInk
                                    )
                                }
                                Surface(
                                    shape = RoundedCornerShape(13.dp),
                                    color = Color(0xFFF0EEFF)
                                ) {
                                    Text(
                                        text = formatter.format(selectedProduct.coinAmount) + " سکه",
                                        modifier = Modifier.padding(horizontal = 11.dp, vertical = 8.dp),
                                        style = MaterialTheme.typography.labelLarge,
                                        fontWeight = FontWeight.Bold,
                                        color = StoreVioletDeep
                                    )
                                }
                            }

                            Button(
                                onClick = { onBuyCoins(selectedProduct.productId) },
                                enabled = !isBusy,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(58.dp)
                                    .testTag("coin_store_purchase_button"),
                                shape = RoundedCornerShape(17.dp),
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = StoreGreen,
                                    contentColor = Color.White,
                                    disabledContainerColor = StoreGreen.copy(alpha = 0.65f),
                                    disabledContentColor = Color.White
                                ),
                                elevation = ButtonDefaults.buttonElevation(
                                    defaultElevation = 3.dp,
                                    pressedElevation = 1.dp
                                )
                            ) {
                                if (isBusy) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(21.dp),
                                        strokeWidth = 2.4.dp,
                                        color = Color.White
                                    )
                                    Spacer(modifier = Modifier.width(10.dp))
                                    Text("در حال آماده‌سازی خرید", fontWeight = FontWeight.Bold)
                                } else {
                                    Surface(
                                        shape = RoundedCornerShape(10.dp),
                                        color = Color.White,
                                        modifier = Modifier.size(34.dp)
                                    ) {
                                        Box(contentAlignment = Alignment.Center) {
                                            androidx.compose.foundation.Image(
                                                painter = painterResource(R.drawable.ic_cafebazaar_bag),
                                                contentDescription = "نشان کافه‌بازار",
                                                modifier = Modifier
                                                    .padding(4.dp)
                                                    .size(26.dp)
                                            )
                                        }
                                    }
                                    Spacer(modifier = Modifier.width(10.dp))
                                    Text("خرید از کافه‌بازار", fontWeight = FontWeight.Black)
                                }
                            }

                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.Center,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Lock,
                                    contentDescription = null,
                                    tint = SiteBinBlue,
                                    modifier = Modifier.size(14.dp)
                                )
                                Spacer(modifier = Modifier.width(5.dp))
                                Text(
                                    text = "اعتباردهی فقط پس از تأیید امن رسید توسط سرور",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = StoreMuted
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StoreHero() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(23.dp),
        colors = CardDefaults.cardColors(containerColor = Color.Transparent)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(
                    Brush.linearGradient(
                        listOf(Color(0xFF10172F), Color(0xFF292D74), Color(0xFF164E63))
                    )
                )
                .padding(horizontal = 15.dp, vertical = 15.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(5.dp)
            ) {
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = Color.White.copy(alpha = 0.13f)
                ) {
                    Text(
                        text = "SITEBIN  •  COIN STORE",
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.4.sp
                    )
                }
                Text(
                    text = "سکه بیشتر،\\nفرصت بیشتر",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Black,
                    color = Color.White,
                    lineHeight = 28.sp
                )
                Text(
                    text = "برای سفارش‌های بازدید آماده باش.",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.82f)
                )
            }
            Box(
                modifier = Modifier.size(78.dp),
                contentAlignment = Alignment.Center
            ) {
                Surface(
                    shape = CircleShape,
                    color = SiteBinGold.copy(alpha = 0.15f),
                    modifier = Modifier.size(76.dp)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Surface(
                            shape = CircleShape,
                            color = SiteBinGold.copy(alpha = 0.13f),
                            modifier = Modifier.size(58.dp)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Text(text = "🪙", fontSize = 35.sp)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CoinPackageOption(
    product: CoinStoreProduct,
    selected: Boolean,
    enabled: Boolean,
    numberFormatter: NumberFormat,
    onSelect: () -> Unit
) {
    val background by animateColorAsState(
        targetValue = if (selected) Color(0xFFF1F0FF) else Color.White,
        animationSpec = tween(180),
        label = "coin-package-background"
    )
    val border by animateColorAsState(
        targetValue = if (selected) StoreViolet else Color(0xFFE4E7EF),
        animationSpec = tween(180),
        label = "coin-package-border"
    )
    val recommended = product.productId == "coins_50000"

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("coin_store_package_" + product.productId)
            .clip(RoundedCornerShape(17.dp))
            .clickable(enabled = enabled, onClick = onSelect),
        shape = RoundedCornerShape(17.dp),
        color = background,
        border = BorderStroke(if (selected) 1.6.dp else 1.dp, border),
        tonalElevation = if (selected) 1.dp else 0.dp
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 11.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Surface(
                shape = RoundedCornerShape(14.dp),
                color = if (recommended) Color(0xFFFFF0C2) else Color(0xFFF2F5FA),
                modifier = Modifier.size(46.dp)
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(text = if (product.coinAmount >= 20_000L) "🪙🪙" else "🪙", fontSize = 22.sp)
                }
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = numberFormatter.format(product.coinAmount) + " سکه",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Black,
                        color = StoreInk
                    )
                    if (recommended) {
                        Surface(
                            shape = RoundedCornerShape(7.dp),
                            color = Color(0xFFE4DFFF)
                        ) {
                            Text(
                                text = "به‌صرفه‌ترین",
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 3.dp),
                                style = MaterialTheme.typography.labelSmall,
                                color = StoreVioletDeep,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }
                }
                Text(
                    text = numberFormatter.format(product.priceToman) + " تومان",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (selected) StoreVioletDeep else StoreMuted,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal
                )
            }
            Surface(
                shape = CircleShape,
                color = if (selected) StoreViolet else Color.Transparent,
                border = if (selected) null else BorderStroke(1.5.dp, Color(0xFFC7CDDA)),
                modifier = Modifier.size(23.dp)
            ) {
                if (selected) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = Icons.Default.Check,
                            contentDescription = "بسته انتخاب‌شده",
                            tint = Color.White,
                            modifier = Modifier.size(15.dp)
                        )
                    }
                }
            }
        }
    }
}
