package com.example.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.NavigateNext
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.core.security.SafeWebView
import com.example.ui.ViewerState
import com.example.ui.theme.SiteBinGold
import com.example.ui.theme.SiteBinSuccess

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ViewerScreen(
    viewerState: ViewerState,
    onContentReady: () -> Unit,
    onUrlBlocked: (String, String) -> Unit,
    onSkip: () -> Unit,
    onNextSite: () -> Unit,
    onReport: (String, String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    var showExitConfirmDialog by remember { mutableStateOf(false) }

    val handleBackPress = {
        if (viewerState is ViewerState.Viewing) {
            showExitConfirmDialog = true
        } else {
            onBack()
        }
    }

    BackHandler {
        handleBackPress()
    }

    var showReportDialog by remember { mutableStateOf(false) }
    var pageErrorMsg by remember { mutableStateOf<String?>(null) }
    var isPageLoading by remember { mutableStateOf(true) }

    val currentSession = when (viewerState) {
        is ViewerState.Loading -> viewerState.session
        is ViewerState.Viewing -> viewerState.session
        is ViewerState.Completed -> viewerState.session
        else -> null
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        // --- Top Navigation & Timer Bar ---
        Surface(
            tonalElevation = 6.dp,
            shadowElevation = 4.dp,
            color = MaterialTheme.colorScheme.surface
        ) {
            Column {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    IconButton(
                        onClick = handleBackPress,
                        modifier = Modifier.testTag("viewer_back_button")
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "بازگشت"
                        )
                    }

                    // Secure Domain Pill
                    Surface(
                        shape = RoundedCornerShape(20.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                        modifier = Modifier
                            .weight(1f)
                            .padding(horizontal = 4.dp)
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Lock,
                                contentDescription = null,
                                tint = SiteBinSuccess,
                                modifier = Modifier.size(14.dp)
                            )
                            Text(
                                text = currentSession?.domain ?: "در حال اتصال...",
                                style = MaterialTheme.typography.bodySmall,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                softWrap = false,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }

                    // Timer / Status
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        when (viewerState) {
                            is ViewerState.Viewing -> {
                                val remaining = (viewerState.totalSeconds - viewerState.elapsedSeconds).coerceAtLeast(0)
                                Surface(
                                    shape = RoundedCornerShape(12.dp),
                                    color = MaterialTheme.colorScheme.primaryContainer
                                ) {
                                    Text(
                                        text = String.format("%02d:%02d", remaining / 60, remaining % 60),
                                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                        style = MaterialTheme.typography.titleMedium,
                                        fontWeight = FontWeight.Black,
                                        color = MaterialTheme.colorScheme.primary
                                    )
                                }
                            }
                            is ViewerState.Completed -> {
                                Surface(
                                    shape = RoundedCornerShape(12.dp),
                                    color = SiteBinSuccess.copy(alpha = 0.2f)
                                ) {
                                    Text(
                                        text = "✓ تکمیل",
                                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                                        style = MaterialTheme.typography.bodySmall,
                                        fontWeight = FontWeight.Bold,
                                        color = SiteBinSuccess
                                    )
                                }
                            }
                            else -> {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(20.dp),
                                    strokeWidth = 2.dp
                                )
                            }
                        }

                        // Report Flag
                        IconButton(onClick = { showReportDialog = true }) {
                            Icon(
                                imageVector = Icons.Default.Flag,
                                contentDescription = "گزارش وب‌سایت",
                                tint = MaterialTheme.colorScheme.error
                            )
                        }
                    }
                }

                // Progress Indicator
                if (viewerState is ViewerState.Viewing) {
                    val progress = (viewerState.elapsedSeconds.toFloat() / viewerState.totalSeconds).coerceIn(0f, 1f)
                    LinearProgressIndicator(
                        progress = { progress },
                        modifier = Modifier.fillMaxWidth(),
                        color = MaterialTheme.colorScheme.primary,
                        trackColor = MaterialTheme.colorScheme.surfaceVariant
                    )
                }
            }
        }

        // --- WebView Sandbox Area ---
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
        ) {
            if (currentSession != null) {
                SafeWebView(
                    url = currentSession.targetUrl,
                    onPageStarted = {
                        isPageLoading = true
                        pageErrorMsg = null
                    },
                    onPageContentReady = {
                        isPageLoading = false
                        onContentReady()
                    },
                    onUrlBlocked = { url, reason ->
                        onUrlBlocked(url, reason)
                    },
                    onErrorOccurred = { error ->
                        isPageLoading = false
                        pageErrorMsg = error
                    }
                )
            }

            // Loading Overlay
            if (isPageLoading && viewerState !is ViewerState.Completed) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(MaterialTheme.colorScheme.background.copy(alpha = 0.85f)),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
                        Text(
                            text = "در حال بارگذاری ایمن وب‌سایت...",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onBackground
                        )
                        Text(
                            text = "تایمر پس از نمایش کامل صفحه آغاز می‌شود",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            // Error Overlay
            if (pageErrorMsg != null) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(MaterialTheme.colorScheme.background)
                        .padding(24.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.ErrorOutline,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.error,
                            modifier = Modifier.size(54.dp)
                        )
                        Text(
                            text = "امکان نمایش این وب‌سایت وجود ندارد",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold
                        )
                        Text(
                            text = pageErrorMsg ?: "",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            OutlinedButton(onClick = onSkip) {
                                Text("رد کردن سایت")
                            }
                            Button(onClick = { pageErrorMsg = null }) {
                                Text("تلاش مجدد")
                            }
                        }
                    }
                }
            }

            // Completion Confirmation: centered modal-style card for reliable visibility
            androidx.compose.animation.AnimatedVisibility(
                visible = viewerState is ViewerState.Completed,
                enter = fadeIn() + slideInVertically(initialOffsetY = { it / 8 }),
                exit = fadeOut() + slideOutVertically(targetOffsetY = { it / 8 }),
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.20f)),
            ) {
                val reward = (viewerState as? ViewerState.Completed)?.rewardEarned ?: 0L

                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 20.dp, vertical = 24.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Card(
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("viewer_completion_card"),
                        shape = RoundedCornerShape(28.dp),
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.surface
                        ),
                        elevation = CardDefaults.cardElevation(defaultElevation = 12.dp)
                    ) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 22.dp, vertical = 24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            Surface(
                                modifier = Modifier.size(68.dp),
                                shape = CircleShape,
                                color = SiteBinSuccess.copy(alpha = 0.12f)
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(
                                        imageVector = Icons.Default.CheckCircle,
                                        contentDescription = null,
                                        tint = SiteBinSuccess,
                                        modifier = Modifier.size(38.dp)
                                    )
                                }
                            }

                            Text(
                                text = "بازدید معتبر تایید شد",
                                style = MaterialTheme.typography.headlineSmall,
                                fontWeight = FontWeight.Black,
                                color = MaterialTheme.colorScheme.onSurface,
                                textAlign = TextAlign.Center,
                                maxLines = 1,
                                softWrap = false
                            )

                            Text(
                                text = "پاداش با موفقیت به کیف پول شما افزوده شد.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.fillMaxWidth()
                            )

                            Surface(
                                shape = RoundedCornerShape(16.dp),
                                color = SiteBinGold.copy(alpha = 0.13f)
                            ) {
                                Text(
                                    text = "🪙 +$reward سکه",
                                    style = MaterialTheme.typography.headlineSmall,
                                    fontWeight = FontWeight.Black,
                                    color = SiteBinGold,
                                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 8.dp),
                                    maxLines = 1,
                                    softWrap = false
                                )
                            }

                            Spacer(modifier = Modifier.height(4.dp))

                            Column(
                                modifier = Modifier.fillMaxWidth(),
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Button(
                                    onClick = onNextSite,
                                    modifier = Modifier.fillMaxWidth(),
                                    shape = RoundedCornerShape(12.dp)
                                ) {
                                    Text("مشاهده بعدی", maxLines = 1, softWrap = false)
                                    Spacer(modifier = Modifier.width(4.dp))
                                    Icon(
                                        Icons.Default.NavigateNext,
                                        contentDescription = null
                                    )
                                }

                                OutlinedButton(
                                    onClick = onBack,
                                    modifier = Modifier.fillMaxWidth(),
                                    shape = RoundedCornerShape(12.dp)
                                ) {
                                    Text("بازگشت به خانه", maxLines = 1, softWrap = false)
                                }
                            }
                        }
                    }
                }
            }
        }

        // --- Bottom Control Bar (Skip affordance) ---
        if (viewerState !is ViewerState.Completed) {
            Surface(
                tonalElevation = 3.dp,
                color = MaterialTheme.colorScheme.surface
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text(
                            text = "پاداش این مشاهده:",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            text = "🪙 ${currentSession?.rewardCoins ?: 0} سکه",
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.Bold,
                            color = SiteBinGold
                        )
                    }

                    TextButton(
                        onClick = onSkip,
                        shape = RoundedCornerShape(8.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.SkipNext,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            text = "رد کردن سایت",
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }
        }
    }

    // --- Abuse Report Dialog ---
    if (showReportDialog) {
        val reportReasons = listOf(
            "محتوای نامناسب یا غیراخلاقی",
            "سایت فیشینگ یا کلاهبرداری",
            "دانلود بدافزار یا ویروس",
            "لینک خراب یا عدم لود شدن",
            "تبلیغات گمراه‌کننده یا پاپ‌آپ آزاردهنده"
        )
        var selectedReason by remember { mutableStateOf(reportReasons[0]) }

        AlertDialog(
            onDismissRequest = { showReportDialog = false },
            title = {
                Text(text = "گزارش وب‌سایت", fontWeight = FontWeight.Bold)
            },
            text = {
                Column {
                    Text(
                        text = "علت گزارش وب‌سایت ${currentSession?.domain ?: ""} را مشخص کنید:",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    reportReasons.forEach { reason ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .padding(vertical = 4.dp)
                        ) {
                            RadioButton(
                                selected = (reason == selectedReason),
                                onClick = { selectedReason = reason }
                            )
                            Spacer(modifier = Modifier.width(6.dp))
                            Text(
                                text = reason,
                                style = MaterialTheme.typography.bodyMedium
                            )
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        onReport(selectedReason, "")
                        showReportDialog = false
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                ) {
                    Text("ثبت و مسدودسازی")
                }
            },
            dismissButton = {
                TextButton(onClick = { showReportDialog = false }) {
                    Text("انصراف")
                }
            }
        )
    }

    // --- Exit Viewer Confirmation Dialog ---
    if (showExitConfirmDialog) {
        AlertDialog(
            onDismissRequest = { showExitConfirmDialog = false },
            title = {
                Text("خروج از مشاهده وب‌سایت", fontWeight = FontWeight.Bold)
            },
            text = {
                Text(
                    "شما در حال مشاهده فعال این وب‌سایت هستید. در صورت خروج قبل از اتمام زمان الزامی، زمان طی شده محاسبه نشده و سکه‌ای دریافت نخواهید کرد. آیا خارج می‌شوید؟",
                    style = MaterialTheme.typography.bodyMedium
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        showExitConfirmDialog = false
                        onBack()
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                ) {
                    Text("خروج بدون دریافت سکه")
                }
            },
            dismissButton = {
                TextButton(onClick = { showExitConfirmDialog = false }) {
                    Text("ادامه مشاهده")
                }
            }
        )
    }
}
