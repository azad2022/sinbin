package com.example.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.example.R

object SiteBinNotificationManager {
    private const val CHANNEL_ID = "sitebin_coin_activity"
    private const val CHANNEL_NAME = "اعلان‌های سکه"
    private const val REFERRAL_CHANNEL_ID = "sitebin_referrals"
    private const val REFERRAL_CHANNEL_NAME = "اعلان‌های دعوت دوستان"

    fun createChannel(context: Context) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "اعلان دریافت و انتقال سکه در SiteBin"
            }
            context.getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)

            val referralChannel = NotificationChannel(
                REFERRAL_CHANNEL_ID,
                REFERRAL_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "اطلاع‌رسانی درباره ثبت زیرمجموعه‌های مستقیم"
            }
            context.getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(referralChannel)
        }
    }

    fun canPostNotifications(context: Context): Boolean {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            return false
        }
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }


    fun showReferralInvite(
        context: Context,
        eventId: String,
        title: String,
        description: String
    ) {
        createChannel(context)
        if (!canPostNotifications(context)) return

        val launchIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
                putExtra("sitebin_open_referral_settings", true)
                putExtra("sitebin_referral_event_id", eventId)
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            } ?: Intent(context, com.example.MainActivity::class.java).apply {
                putExtra("sitebin_open_referral_settings", true)
                putExtra("sitebin_referral_event_id", eventId)
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }

        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val contentIntent = PendingIntent.getActivity(
            context,
            eventId.hashCode(),
            launchIntent,
            pendingFlags
        )

        val notification = NotificationCompat.Builder(context, REFERRAL_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_coin)
            .setContentTitle(title.ifBlank { "زیرمجموعه جدید" })
            .setContentText(description)
            .setStyle(NotificationCompat.BigTextStyle().bigText(description))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()

        // The event id is stable, so a repeated FCM delivery replaces the same
        // notification rather than creating a stack of identical messages.
        val notificationId = (eventId.hashCode() and Int.MAX_VALUE).coerceAtLeast(1)
        NotificationManagerCompat.from(context).notify(notificationId, notification)
    }

    fun showCoinReceived(context: Context, amount: Long, description: String) {
        createChannel(context)
        if (!canPostNotifications(context)) return

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_coin)
            .setContentTitle("واریز سکه به حساب")
            .setContentText(amount.toString() + " سکه به حساب شما واریز شد")
            .setStyle(NotificationCompat.BigTextStyle().bigText(description))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()

        val notificationId = (System.currentTimeMillis() % Int.MAX_VALUE).toInt()
        NotificationManagerCompat.from(context).notify(notificationId, notification)
    }
}
