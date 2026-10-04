package com.example.ui.screens

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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.Gavel
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.data.model.UserAccount
import com.example.ui.theme.SiteBinBlue
import com.example.ui.theme.SiteBinSuccess

@Composable
fun SettingsScreen(
    account: UserAccount,
    isDarkTheme: Boolean,
    onToggleDarkTheme: (Boolean) -> Unit,
    notificationsEnabled: Boolean,
    onToggleNotifications: (Boolean) -> Unit,
    isTransferringCoins: Boolean,
    onTransferCoins: (String, Long, String?, () -> Unit) -> Unit,
    modifier: Modifier = Modifier
) {
    var showTermsDialog by remember { mutableStateOf(false) }
    var showPrivacyDialog by remember { mutableStateOf(false) }
    var showAboutDialog by remember { mutableStateOf(false) }
    var showTransferDialog by remember { mutableStateOf(false) }
    var recipientHandle by remember { mutableStateOf("") }
    var transferAmount by remember { mutableStateOf("") }
    var transferNote by remember { mutableStateOf("") }
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
                        Surface(
                            shape = CircleShape,
                            color = SiteBinBlue.copy(alpha = 0.2f),
                            modifier = Modifier.size(50.dp)
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

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(Icons.Default.Shield, contentDescription = null, tint = SiteBinSuccess, modifier = Modifier.size(18.dp))
                            Text(
                                text = "امتیاز سلامت حساب:",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Text(
                            text = "${account.trustScore.toInt()}% (عالی)",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Bold,
                            color = SiteBinSuccess
                        )
                    }

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
                            Button(
                                onClick = {
                                    clipboardManager.setText(AnnotatedString(account.userHandle))
                                },
                                modifier = Modifier.height(44.dp),
                                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp)
                            ) {
                                Icon(Icons.Default.ContentCopy, contentDescription = "کپی شناسه", modifier = Modifier.size(18.dp))
                                Spacer(modifier = Modifier.width(6.dp))
                                Text("کپی")
                            }
                        }
                        Text(
                            text = "این شناسه را برای دریافت سکه با دیگران به اشتراک بگذارید.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        androidx.compose.material3.OutlinedButton(
                            onClick = { showTransferDialog = true },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Default.Send, contentDescription = null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("انتقال سکه به کاربر دیگر")
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
                        subtitle = "اطلاع‌رسانی هنگام دریافت سکه از کاربران دیگر",
                        checked = notificationsEnabled,
                        onCheckedChange = onToggleNotifications
                    )
                }
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
                        title = "خط مشی امنیت و حریم خصوصی WebView",
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

    if (showTransferDialog) {
        AlertDialog(
            onDismissRequest = { if (!isTransferringCoins) showTransferDialog = false },
            title = { Text("انتقال سکه", fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        text = "موجودی قابل انتقال: " + account.availableCoins + " سکه",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    androidx.compose.material3.OutlinedTextField(
                        value = recipientHandle,
                        onValueChange = { recipientHandle = it.take(64) },
                        label = { Text("شناسه کاربری مقصد") },
                        placeholder = { Text("مثلاً user_1234abcd") },
                        singleLine = true,
                        enabled = !isTransferringCoins,
                        modifier = Modifier.fillMaxWidth()
                    )
                    androidx.compose.material3.OutlinedTextField(
                        value = transferAmount,
                        onValueChange = { transferAmount = it.filter(Char::isDigit).take(10) },
                        label = { Text("مقدار سکه") },
                        placeholder = { Text("مثلاً 100") },
                        singleLine = true,
                        enabled = !isTransferringCoins,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth()
                    )
                    androidx.compose.material3.OutlinedTextField(
                        value = transferNote,
                        onValueChange = { transferNote = it.take(160) },
                        label = { Text("یادداشت (اختیاری)") },
                        singleLine = true,
                        enabled = !isTransferringCoins,
                        supportingText = { Text(transferNote.length.toString() + "/160") },
                        modifier = Modifier.fillMaxWidth()
                    )
                    Text(
                        text = "فقط سکه‌های قابل استفاده منتقل می‌شوند؛ سکه‌های رزروشده برای سفارش‌ها قابل انتقال نیستند.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            },
            dismissButton = {
                TextButton(
                    enabled = !isTransferringCoins,
                    onClick = { showTransferDialog = false }
                ) { Text("انصراف") }
            },
            confirmButton = {
                Button(
                    enabled = !isTransferringCoins &&
                        recipientHandle.isNotBlank() &&
                        (transferAmount.toLongOrNull() ?: 0L) > 0L,
                    onClick = {
                        val amount = transferAmount.toLongOrNull() ?: return@Button
                        onTransferCoins(
                            recipientHandle,
                            amount,
                            transferNote,
                            {
                                recipientHandle = ""
                                transferAmount = ""
                                transferNote = ""
                                showTransferDialog = false
                            }
                        )
                    }
                ) {
                    if (isTransferringCoins) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Text("انتقال")
                    }
                }
            }
        )
    }

    if (showTermsDialog) {
        AlertDialog(
            onDismissRequest = { showTermsDialog = false },
            title = { Text("قوانین و مقررات SiteBin", fontWeight = FontWeight.Bold) },
            text = {
                Text(
                    "۱. ثبت هرگونه لینک به کانال‌های تلگرام، اپ‌استورها یا دانلود مستقیم فایل APK اکیداً ممنوع و به صورت خودکار مسدود می‌شود.\n\n" +
                    "۲. سکه‌ها صرفاً برای ثبت بازدید داخلی معتبر بوده و خرید و فروش آزاد آن منوط به ضوابط سرور است.\n\n" +
                    "۳. هرگونه دور زدن تایمر، استفاده از شبیه‌سازها یا دستکاری ترافیک منجر به کسر امتیاز اعتماد و مسدودسازی سشن می‌گردد."
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
private fun SettingsToggleRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    checked: Boolean,
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
        Switch(checked = checked, onCheckedChange = onCheckedChange)
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
