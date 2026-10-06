package com.example.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.scaleIn
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CardGiftcard
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Savings
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.example.data.model.CoinTransaction
import com.example.data.model.TransactionType
import com.example.data.model.UserAccount
import com.example.ui.theme.SiteBinBlue
import com.example.ui.theme.SiteBinGold
import com.example.ui.theme.SiteBinGoldLight
import com.example.ui.theme.SiteBinSuccess
import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType

@Composable
fun WalletScreen(
    account: UserAccount,
    transactions: List<CoinTransaction>,
    isTransferringCoins: Boolean = false,
    onTransferCoins: (String, Long, () -> Unit) -> Unit = { _, _, _ -> },
    modifier: Modifier = Modifier
) {
    val formatter = NumberFormat.getNumberInstance(Locale.US)
    var showTransferDialog by remember { mutableStateOf(false) }
    var recipientHandle by remember { mutableStateOf("") }
    var transferAmount by remember { mutableStateOf("") }

    val parsedAmount = transferAmount.toLongOrNull() ?: 0L
    val canTransfer = !isTransferringCoins &&
        recipientHandle.trim().isNotBlank() &&
        parsedAmount in 1..account.availableCoins

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // Main Coin Balance Card
        item {
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
                        .background(
                            Brush.linearGradient(
                                listOf(Color(0xFF1E1B4B), Color(0xFF0F172A))
                            )
                        )
                        .padding(22.dp)
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "موجودی قابل استفاده",
                                style = MaterialTheme.typography.bodyMedium,
                                color = Color.White.copy(alpha = 0.8f)
                            )
                            Surface(
                                shape = RoundedCornerShape(12.dp),
                                color = SiteBinGold.copy(alpha = 0.2f)
                            ) {
                                Text(
                                    text = "حساب فعال",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = SiteBinGoldLight,
                                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        }

                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Text(text = "🪙", fontSize = 34.sp)
                            Text(
                                text = formatter.format(account.availableCoins),
                                style = MaterialTheme.typography.displaySmall,
                                fontWeight = FontWeight.Black,
                                color = SiteBinGoldLight
                            )
                            Text(
                                text = "سکه",
                                style = MaterialTheme.typography.titleMedium,
                                color = Color.White.copy(alpha = 0.8f),
                                modifier = Modifier.align(Alignment.Bottom).padding(bottom = 6.dp)
                            )
                        }

                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(1.dp)
                                .background(Color.White.copy(alpha = 0.15f))
                        )

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Column {
                                Text(
                                    text = "رزرو شده سفارش‌ها",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = Color.White.copy(alpha = 0.6f)
                                )
                                Spacer(modifier = Modifier.height(2.dp))
                                Text(
                                    text = "${formatter.format(account.reservedCoins)} سکه",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.Bold,
                                    color = Color.White
                                )
                            }

                            Column(horizontalAlignment = Alignment.End) {
                                Text(
                                    text = "مجموع کسب شده",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = Color.White.copy(alpha = 0.6f)
                                )
                                Spacer(modifier = Modifier.height(2.dp))
                                Text(
                                    text = "${formatter.format(account.lifetimeEarned)} سکه",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.Bold,
                                    color = SiteBinSuccess
                                )
                            }
                        }
                    }
                }
            }
        }

        item {
            TransferCoinsCard(
                onClick = { showTransferDialog = true }
            )
        }

        // Ledger History Header
        item {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "ریز تراکنش‌های حسابرسی شده",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold
            )
        }

        if (transactions.isEmpty()) {
            item {
                Text(
                    text = "هنوز تراکنشی در حساب شما ثبت نشده است.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        } else {
            items(transactions, key = { it.id }) { tx ->
                TransactionRow(tx = tx)
            }
        }

        item {
            Spacer(modifier = Modifier.height(24.dp))
        }
    }

    if (showTransferDialog) {
        Dialog(
            onDismissRequest = { if (!isTransferringCoins) showTransferDialog = false }
        ) {
            AnimatedVisibility(
                visible = true,
                enter = fadeIn() + scaleIn(initialScale = 0.90f)
            ) {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(28.dp),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surface
                    ),
                    elevation = CardDefaults.cardElevation(defaultElevation = 16.dp)
                ) {
                    Column(
                        modifier = Modifier.padding(22.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            Surface(
                                shape = CircleShape,
                                color = SiteBinGold.copy(alpha = 0.14f),
                                modifier = Modifier.size(48.dp)
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Text("🪙", fontSize = 24.sp)
                                }
                            }
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    "انتقال سکه",
                                    style = MaterialTheme.typography.titleLarge,
                                    fontWeight = FontWeight.Black
                                )
                                Text(
                                    "انتقال سریع و امن به شناسه کاربری مقصد",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        Surface(
                            shape = RoundedCornerShape(14.dp),
                            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.07f)
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 14.dp, vertical = 12.dp),
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Text(
                                    "موجودی قابل انتقال",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                                Text(
                                    "${formatter.format(account.availableCoins)} سکه",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        }

                        OutlinedTextField(
                            value = recipientHandle,
                            onValueChange = { recipientHandle = it.take(64) },
                            label = { Text("شناسه کاربری مقصد") },
                            placeholder = { Text("مثلاً user_1234abcd") },
                            singleLine = true,
                            enabled = !isTransferringCoins,
                            modifier = Modifier.fillMaxWidth()
                        )

                        OutlinedTextField(
                            value = transferAmount,
                            onValueChange = {
                                transferAmount = it.filter(Char::isDigit).take(10)
                            },
                            label = { Text("مقدار سکه") },
                            placeholder = { Text("مثلاً 100") },
                            singleLine = true,
                            enabled = !isTransferringCoins,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            modifier = Modifier.fillMaxWidth()
                        )

                        Text(
                            text = "سکه‌های رزروشده برای سفارش‌ها قابل انتقال نیستند.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            OutlinedButton(
                                enabled = !isTransferringCoins,
                                onClick = { showTransferDialog = false },
                                modifier = Modifier.weight(1f)
                            ) {
                                Text("انصراف")
                            }
                            Button(
                                enabled = canTransfer,
                                onClick = {
                                    val amount = transferAmount.toLongOrNull() ?: return@Button
                                    onTransferCoins(
                                        recipientHandle.trim(),
                                        amount
                                    ) {
                                        recipientHandle = ""
                                        transferAmount = ""
                                        showTransferDialog = false
                                    }
                                },
                                modifier = Modifier.weight(1f),
                                shape = RoundedCornerShape(14.dp)
                            ) {
                                if (isTransferringCoins) {
                                    androidx.compose.material3.CircularProgressIndicator(
                                        modifier = Modifier.size(18.dp),
                                        strokeWidth = 2.dp
                                    )
                                } else {
                                    Icon(Icons.Default.Savings, contentDescription = null, modifier = Modifier.size(18.dp))
                                    Spacer(modifier = Modifier.width(6.dp))
                                    Text("انتقال")
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
private fun TransferCoinsCard(
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp)),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        ),
        border = BorderStroke(1.dp, SiteBinGold.copy(alpha = 0.18f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onClick)
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Surface(
                shape = CircleShape,
                color = SiteBinGold.copy(alpha = 0.12f),
                modifier = Modifier.size(44.dp)
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Default.Send,
                        contentDescription = null,
                        tint = SiteBinGold,
                        modifier = Modifier.size(20.dp)
                    )
                }
            }

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp)
            ) {
                Text(
                    text = "ارسال سکه",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    text = "انتقال سریع به یک کاربر دیگر",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Icon(
                imageVector = Icons.Default.ChevronLeft,
                contentDescription = "ورود به انتقال سکه",
                tint = SiteBinGold,
                modifier = Modifier.size(22.dp)
            )
        }
    }
}

@Composable
private fun TransactionRow(tx: CoinTransaction) {
    val formatter = NumberFormat.getNumberInstance(Locale.US)
    val timeFormat = SimpleDateFormat("yyyy/MM/dd - HH:mm", Locale.getDefault())

    val (icon, iconColor) = when (tx.type) {
        TransactionType.WELCOME_REWARD -> Icons.Default.CardGiftcard to SiteBinGold
        TransactionType.VIEW_REWARD -> Icons.Default.RemoveRedEye to SiteBinSuccess
        TransactionType.CAMPAIGN_RESERVATION -> Icons.Default.Lock to MaterialTheme.colorScheme.error
        TransactionType.CAMPAIGN_SPEND -> Icons.Default.Savings to MaterialTheme.colorScheme.error
        TransactionType.CAMPAIGN_REFUND -> Icons.Default.Replay to SiteBinBlue
        TransactionType.REFERRAL_REWARD -> Icons.Default.CardGiftcard to SiteBinGold
        TransactionType.PLATFORM_GRANT -> Icons.Default.Savings to SiteBinGold
        TransactionType.DAILY_BONUS -> Icons.Default.CardGiftcard to SiteBinGold
        TransactionType.AUTO_VIEW_SUBSCRIPTION -> Icons.Default.Autorenew to MaterialTheme.colorScheme.error
        TransactionType.COIN_TRANSFER_SENT -> Icons.Default.Savings to MaterialTheme.colorScheme.error
        TransactionType.COIN_TRANSFER_RECEIVED -> Icons.Default.CardGiftcard to SiteBinGold
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.weight(1f)
            ) {
                Surface(
                    shape = CircleShape,
                    color = iconColor.copy(alpha = 0.15f),
                    modifier = Modifier.size(40.dp)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = icon,
                            contentDescription = null,
                            tint = iconColor,
                            modifier = Modifier.size(20.dp)
                        )
                    }
                }

                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = tx.type.labelFarsi,
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        text = tx.description,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = timeFormat.format(Date(tx.timestamp)),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline
                    )
                }
            }

            Text(
                text = (if (tx.amount > 0) "+ " else "") + formatter.format(tx.amount) + " 🪙",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Black,
                color = if (tx.amount > 0) SiteBinSuccess else MaterialTheme.colorScheme.error
            )
        }
    }
}
