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
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudQueue
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.Gavel
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Storage
import com.example.data.backend.BackendManager
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
    onShowMessage: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    var notificationsEnabled by remember { mutableStateOf(true) }
    var showTermsDialog by remember { mutableStateOf(false) }
    var showPrivacyDialog by remember { mutableStateOf(false) }
    var showAboutDialog by remember { mutableStateOf(false) }
    var showSupabaseDialog by remember { mutableStateOf(false) }

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "پروفایل و تنظیمات",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold
            )
            Text(
                text = "مدیریت حساب ناشناس و پیکربندی اپلیکیشن",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
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
                                    text = "کاربر ناشناس امن",
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
                                text = "شناسه نصب: ${account.userId}",
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

                    OutlinedButton(
                        onClick = {
                            onShowMessage("قابلیت اتصال به حساب گوگل و شماره همراه در فاز بعدی فعال می‌شود.")
                        },
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.Link, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(modifier = Modifier.width(6.dp))
                        Text("اتصال به حساب دائمی (گوگل / شماره همراه)")
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
                        title = "اعلان‌های تکمیل سفارش",
                        subtitle = "اطلاع‌رسانی هنگام پایان بازدیدهای کمپین",
                        checked = notificationsEnabled,
                        onCheckedChange = { notificationsEnabled = it }
                    )
                }
            }
        }

        // Section: Backend Architecture Status
        item {
            Text(
                text = "معماری سرور و پایگاه داده",
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
                        icon = if (BackendManager.isSupabaseConfigured) Icons.Default.CloudDone else Icons.Default.Storage,
                        title = BackendManager.backendName,
                        subtitle = if (BackendManager.isSupabaseConfigured) {
                            "متصل به سرور ابری PostgreSQL • تمام تراکنش‌ها زنده ثبت می‌شوند"
                        } else {
                            "موتور سرور محلی بدون باگ فعال است • کلیک برای راهنمای اتصال به Supabase ابری"
                        },
                        onClick = { showSupabaseDialog = true }
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

    if (showSupabaseDialog) {
        AlertDialog(
            onDismissRequest = { showSupabaseDialog = false },
            title = { Text("معماری سرور ابری Supabase", fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        if (BackendManager.isSupabaseConfigured) {
                            "✅ اپلیکیشن به پروژه سرور ابری Supabase متصل است:\n${BackendManager.serverUrl}\n\nتمامی عملیات‌های ثبت سفارش، اعتبارسنجی بازدید، پاداش خوش‌آمدگویی و لجر تراکنش‌ها به صورت اتمیک روی پایگاه داده ابری ذخیره می‌گردند."
                        } else {
                            "⚡ وضعیت اتصال:\n" +
                            "هم‌اکنون موتور اعتبارسنجی سرور در وضعیت Server-Authoritative محلی فعال است و کلیه منطق‌های مالی و امنیتی را با موفقیت مدیریت می‌کند.\n\n" +
                            "برای اتصال مستقیم به سرور ابری Supabase:\n" +
                            "۱. در پنل Secrets محیط Google AI Studio مقادیر SUPABASE_URL و SUPABASE_ANON_KEY را وارد نمایید.\n" +
                            "۲. اسکریپت SQL مایگریشن آماده پروژه در مسیر supabase/migrations/20261003_sitebin_core.sql را در SQL Editor داشبورد Supabase اجرا نمایید.\n\n" +
                            "هیچ نیازی به کلید Service Role در اپ وجود ندارد و امنیت کاملاً با RLS تضمین شده است."
                        },
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { showSupabaseDialog = false }) { Text("متوجه شدم") }
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
