package com.example.notifications

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives data-only referral notifications. Monetary state remains server-authoritative;
 * this service only presents the server-authored outbox message to the user.
 */
class SiteBinFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        // The authenticated ViewModel registers the freshest FCM token with Supabase
        // on the next foreground. Never send account-bound tokens from this callback
        // because Firebase may rotate a token before the app session is initialized.
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        if (data["type"] != "REFERRAL_REGISTERED") return

        val eventId = data["event_id"]?.takeIf { it.isNotBlank() } ?: return
        val prefs = getSharedPreferences("sitebin_secure_prefs", MODE_PRIVATE)
        if (!prefs.getBoolean("referral_notifications_enabled", true)) return

        SiteBinNotificationManager.showReferralInvite(
            context = this,
            eventId = eventId,
            title = data["title"] ?: "زیرمجموعه جدید",
            description = data["body"] ?: "یک کاربر زیرمجموعه مستقیم شما شد."
        )
    }
}
