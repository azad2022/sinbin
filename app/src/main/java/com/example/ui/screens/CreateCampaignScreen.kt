package com.example.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.RepeatMode
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.data.model.DurationOption
import com.example.data.model.UserAccount
import com.example.ui.SiteBinViewModel
import com.example.ui.theme.SiteBinBlue
import com.example.ui.theme.SiteBinBlueDark
import com.example.ui.theme.SiteBinTeal
import com.example.ui.theme.SiteBinGold
import com.example.ui.theme.SiteBinSuccess
import java.text.NumberFormat
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CreateCampaignScreen(
    viewModel: SiteBinViewModel,
    account: UserAccount,
    onBack: () -> Unit,
    onSuccess: () -> Unit,
    modifier: Modifier = Modifier
) {
    BackHandler { onBack() }

    val formatter = NumberFormat.getNumberInstance(Locale.US)
    val url by viewModel.urlInput.collectAsState()
    val keyword by viewModel.keywordInput.collectAsState()
    val urlError by viewModel.urlError.collectAsState()
    val selectedDuration by viewModel.selectedDuration.collectAsState()
    val targetViews by viewModel.targetViewsInput.collectAsState()
    val isSubmitting by viewModel.isSubmittingCampaign.collectAsState()

    val currentOption = viewModel.durationOptions.find { it.seconds == selectedDuration }
        ?: viewModel.durationOptions[2]

    val cleanKeyword = keyword.trim().ifBlank { null }
    val keywordCampaign = cleanKeyword != null
    val costPerViewPreview = currentOption.advertiserCostForKeyword(cleanKeyword)
    val totalCost = costPerViewPreview * targetViews
    val canAfford = account.availableCoins >= totalCost
    val isFormValid = url.isNotBlank() && urlError == null && canAfford && !isSubmitting

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            Spacer(modifier = Modifier.height(4.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
            ) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "بازگشت")
                }
                Text(
                    text = "ثبت سفارش بازدید جدید",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold
                )
            }
        }

        // Section 1: URL Input
        item {
            Card(
                shape = RoundedCornerShape(18.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "آدرس وب‌سایت شما (URL)",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold
                    )
                    OutlinedTextField(
                        value = url,
                        onValueChange = { viewModel.onUrlChanged(it) },
                        placeholder = { Text("https://my-website.com") },
                        isError = urlError != null,
                        singleLine = true,
                        leadingIcon = {
                            Icon(Icons.Default.Language, contentDescription = null, tint = SiteBinBlue)
                        },
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = SiteBinBlue,
                            unfocusedBorderColor = MaterialTheme.colorScheme.outline
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("campaign_url_input")
                    )

                    if (urlError != null) {
                        Text(
                            text = urlError ?: "",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error
                        )
                    } else {
                        Text(
                            text = "فقط لینک‌های معتبر با پروتکل HTTPS مجاز هستند. لینک‌های تلگرام و دانلود مسدود می‌شوند.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }

        // Section 2: Optional Keyword
        item {
            Card(
                shape = RoundedCornerShape(18.dp),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)
                ),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(
                            Icons.Default.Search,
                            contentDescription = null,
                            tint = SiteBinBlue,
                            modifier = Modifier.size(18.dp)
                        )
                        Text(
                            text = "کلمه کلیدی (اختیاری)",
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold
                        )
                    }

                    OutlinedTextField(
                        value = keyword,
                        onValueChange = viewModel::onKeywordChanged,
                        placeholder = { Text("مثلاً سولانا") },
                        isError = keyword.length > 25 || keyword.any(Char::isISOControl),
                        singleLine = true,
                        leadingIcon = {
                            Icon(Icons.Default.Search, contentDescription = null, tint = SiteBinBlue)
                        },
                        supportingText = {
                            Text("${keyword.length}/25")
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("campaign_keyword_input"),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = SiteBinBlue,
                            unfocusedBorderColor = MaterialTheme.colorScheme.outline
                        )
                    )

                    Text(
                        text = if (keywordCampaign) {
                            "این سفارش با قیمت ویژه کلمه کلیدی محاسبه می‌شود."
                        } else {
                            "اختیاری است؛ در صورت خالی بودن، سفارش به‌صورت بازدید مستقیم ثبت می‌شود."
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )

                    Text(
                        text = "این گزینه برای بازدیدهای هدفمند بر اساس عبارت انتخابی شما طراحی شده و می‌تواند به افزایش ترافیک مرتبط و دیده‌شدن سایت کمک کند.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }

        // Section 3: Duration Choice
        item {
            Card(
                shape = RoundedCornerShape(18.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(Icons.Default.Timer, contentDescription = null, tint = SiteBinBlue, modifier = Modifier.size(18.dp))
                        Text(
                            text = "مدت زمان مشاهده هر بازدید",
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold
                        )
                    }
                    Text(
                        text = "هرچه مدت زمان بیشتر باشد، زمان بیشتری برای تعامل کاربر با سایت فراهم می‌شود و هزینه هر بازدید افزایش می‌یابد.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )

                    Spacer(modifier = Modifier.height(4.dp))

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        viewModel.durationOptions.forEach { opt ->
                            val isSelected = opt.seconds == selectedDuration
                            DurationCard(
                                option = opt,
                                isSelected = isSelected,
                                displayCost = if (keywordCampaign) opt.keywordAdvertiserCost else opt.advertiserCost,
                                onClick = { viewModel.selectedDuration.value = opt.seconds },
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                }
            }
        }

        // Section 3: Target Views
        item {
            Card(
                shape = RoundedCornerShape(18.dp),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)
                ),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Text(
                        text = "تعداد بازدید مورد نظر",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold
                    )

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        listOf(100, 250, 500, 1000).forEach { count ->
                            val isSelected = targetViews == count
                            PresetViewsCard(
                                count = count,
                                isSelected = isSelected,
                                onClick = { viewModel.targetViewsInput.value = count },
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }

                    // Stepper stays directly below the presets; no artificial vertical gap.
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "تعداد سفارشی:",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium
                        )

                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            IconButton(
                                onClick = {
                                    if (targetViews > 50) {
                                        viewModel.targetViewsInput.value = targetViews - 50
                                    }
                                },
                                modifier = Modifier
                                    .size(44.dp)
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(MaterialTheme.colorScheme.surface)
                            ) {
                                Icon(Icons.Default.Remove, contentDescription = "کاهش")
                            }

                            Text(
                                text = formatter.format(targetViews),
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Black
                            )

                            IconButton(
                                onClick = {
                                    viewModel.targetViewsInput.value = targetViews + 50
                                },
                                modifier = Modifier
                                    .size(44.dp)
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(MaterialTheme.colorScheme.surface)
                            ) {
                                Icon(Icons.Default.Add, contentDescription = "افزایش")
                            }
                        }
                    }
                }
            }
        }

        // Section 4: Dynamic Cost Summary Card
        item {
            Card(
                shape = RoundedCornerShape(22.dp),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surface
                ),
                border = BorderStroke(1.dp, SiteBinBlue.copy(alpha = 0.18f)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(
                                brush = Brush.horizontalGradient(
                                    listOf(
                                        SiteBinBlue,
                                        SiteBinBlueDark.copy(alpha = 0.88f),
                                        SiteBinGold.copy(alpha = 0.78f)
                                    )
                                )
                            )
                            .padding(horizontal = 18.dp, vertical = 16.dp)
                    ) {
                        Column(
                            verticalArrangement = Arrangement.spacedBy(3.dp)
                        ) {
                            Text(
                                text = "پیش‌فاکتور سفارش",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = Color.White
                            )
                            Text(
                                text = "خلاصه‌ی نهایی قبل از کسر سکه",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color.White.copy(alpha = 0.86f)
                            )
                        }
                    }

                    Column(
                        modifier = Modifier.padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(9.dp)
                    ) {
                        SummaryRow(label = "مدت زمان هر مشاهده", value = "${currentOption.seconds} ثانیه")
                        SummaryRow(label = "تعداد بازدید درخواستی", value = "${formatter.format(targetViews)} بازدید")
                        SummaryRow(
                            label = "نوع بازدید",
                            value = if (keywordCampaign) "کلمه کلیدی" else "بازدید مستقیم"
                        )
                        SummaryRow(
                            label = "هزینه هر بازدید",
                            value = "$costPerViewPreview سکه"
                        )

                        if (keywordCampaign) {
                            SummaryRow(
                                label = "هزینه بازدید مستقیم",
                                value = "${currentOption.advertiserCost} سکه"
                            )
                            SummaryRow(
                                label = "هزینه ویژه کلمه کلیدی",
                                value = "${currentOption.keywordAdvertiserCost} سکه"
                            )
                        }

                        SummaryRow(
                            label = "موجودی فعلی شما",
                            value = "🪙 ${formatter.format(account.availableCoins)} سکه"
                        )

                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(1.dp)
                                .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.12f))
                        )

                        Surface(
                            shape = RoundedCornerShape(16.dp),
                            color = if (canAfford) {
                                SiteBinGold.copy(alpha = 0.10f)
                            } else {
                                MaterialTheme.colorScheme.error.copy(alpha = 0.08f)
                            },
                            border = BorderStroke(
                                1.dp,
                                if (canAfford) SiteBinGold.copy(alpha = 0.26f)
                                else MaterialTheme.colorScheme.error.copy(alpha = 0.24f)
                            ),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 14.dp, vertical = 13.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(
                                    verticalArrangement = Arrangement.spacedBy(2.dp)
                                ) {
                                    Text(
                                        text = "هزینه کل",
                                        style = MaterialTheme.typography.titleSmall,
                                        fontWeight = FontWeight.Bold
                                    )
                                    Text(
                                        text = "مبلغ قابل کسر از موجودی",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                Text(
                                    text = "🪙 ${formatter.format(totalCost)}",
                                    style = MaterialTheme.typography.titleLarge,
                                    fontWeight = FontWeight.Black,
                                    color = if (canAfford) SiteBinGoldDark else MaterialTheme.colorScheme.error
                                )
                            }
                        }

                        if (!canAfford) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Icon(
                                    Icons.Default.Info,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.size(16.dp)
                                )
                                Text(
                                    text = "موجودی شما کافی نیست. از بخش «بازدید کسب کن» سکه رایگان جمع‌آوری کنید.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.error
                                )
                            }
                        }
                    }
                }
            }
        }

        // Section 5: Submit CTA Button
        item {
            Button(
                onClick = { viewModel.submitCampaign(onSuccess) },
                enabled = isFormValid,
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = SiteBinBlue,
                    disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp)
                    .testTag("submit_campaign_button")
            ) {
                if (isSubmitting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(22.dp),
                        color = Color.White,
                        strokeWidth = 2.dp
                    )
                } else {
                    Text(
                        text = "ثبت و فعال‌سازی سفارش بازدید",
                        fontWeight = FontWeight.Bold,
                        fontSize = 16.sp
                    )
                }
            }
            Spacer(modifier = Modifier.height(24.dp))
        }
    }
}

@Composable
private fun DurationCard(
    option: DurationOption,
    isSelected: Boolean,
    displayCost: Long,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val transition = rememberInfiniteTransition(label = "duration_${option.seconds}s")
    val pulseScale by transition.animateFloat(
        initialValue = 1f,
        targetValue = if (isSelected) 1.035f else 1.018f,
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = if (isSelected) 900 else 1200,
                easing = FastOutSlowInEasing
            ),
            repeatMode = RepeatMode.Reverse
        ),
        label = "duration_scale_${option.seconds}s"
    )

    val animatedBorderAlpha by transition.animateFloat(
        initialValue = if (isSelected) 0.62f else 0.26f,
        targetValue = if (isSelected) 1f else 0.48f,
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = if (isSelected) 950 else 1350,
                easing = FastOutSlowInEasing
            ),
            repeatMode = RepeatMode.Reverse
        ),
        label = "duration_border_${option.seconds}s"
    )

    Surface(
        shape = RoundedCornerShape(12.dp),
        color = if (isSelected) {
            SiteBinBlue.copy(alpha = 0.2f)
        } else {
            MaterialTheme.colorScheme.surface
        },
        border = BorderStroke(
            1.5.dp,
            if (isSelected) {
                SiteBinBlue.copy(alpha = animatedBorderAlpha)
            } else {
                MaterialTheme.colorScheme.outline.copy(alpha = animatedBorderAlpha)
            }
        ),
        modifier = modifier
            .scale(pulseScale)
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
    ) {
        Column(
            modifier = Modifier.padding(vertical = 10.dp, horizontal = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                text = "${option.seconds}s",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Black,
                color = if (isSelected) SiteBinBlue else MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = "${displayCost} 🪙",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun PresetViewsCard(
    count: Int,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val transition = rememberInfiniteTransition(label = "preset_card_$count")
    val pulseScale by transition.animateFloat(
        initialValue = 1f,
        targetValue = if (isSelected) 1.025f else 1.012f,
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = if (isSelected) 950 else 1250,
                easing = FastOutSlowInEasing
            ),
            repeatMode = RepeatMode.Reverse
        ),
        label = "preset_card_scale_$count"
    )
    val borderAlpha by transition.animateFloat(
        initialValue = if (isSelected) 0.72f else 0.22f,
        targetValue = if (isSelected) 1f else 0.42f,
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = if (isSelected) 900 else 1350,
                easing = FastOutSlowInEasing
            ),
            repeatMode = RepeatMode.Reverse
        ),
        label = "preset_card_border_$count"
    )

    Surface(
        shape = RoundedCornerShape(16.dp),
        color = Color.Transparent,
        border = BorderStroke(
            1.25.dp,
            if (isSelected) {
                SiteBinBlue.copy(alpha = borderAlpha)
            } else {
                MaterialTheme.colorScheme.outline.copy(alpha = borderAlpha)
            }
        ),
        modifier = modifier
            .scale(pulseScale)
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClick = onClick)
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(
                    brush = Brush.horizontalGradient(
                        if (isSelected) {
                            listOf(
                                SiteBinBlue.copy(alpha = 0.98f),
                                SiteBinBlueDark.copy(alpha = 0.92f),
                                SiteBinTeal.copy(alpha = 0.90f)
                            )
                        } else {
                            listOf(
                                MaterialTheme.colorScheme.surface,
                                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.96f),
                                SiteBinBlue.copy(alpha = 0.08f)
                            )
                        }
                    )
                )
                .padding(vertical = 9.dp, horizontal = 4.dp)
        ) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(3.dp)
            ) {
                Text(
                    text = count.toString(),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Black,
                    color = if (isSelected) Color.White else MaterialTheme.colorScheme.onSurface
                )
                AnimatedEyeIcon(
                    tint = if (isSelected) Color.White else SiteBinBlue,
                    modifier = Modifier.size(21.dp)
                )
            }
        }
    }
}

@Composable
private fun AnimatedEyeIcon(
    tint: androidx.compose.ui.graphics.Color,
    modifier: Modifier = Modifier
) {
    val transition = rememberInfiniteTransition(label = "preset_eye")
    val scale by transition.animateFloat(
        initialValue = 0.90f,
        targetValue = 1.08f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 850, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "preset_eye_scale"
    )
    val alpha by transition.animateFloat(
        initialValue = 0.72f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 850, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "preset_eye_alpha"
    )

    Icon(
        imageVector = Icons.Default.Visibility,
        contentDescription = null,
        tint = tint.copy(alpha = alpha),
        modifier = modifier
            .size(22.dp)
            .scale(scale)
    )
}

@Composable
private fun SummaryRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}
