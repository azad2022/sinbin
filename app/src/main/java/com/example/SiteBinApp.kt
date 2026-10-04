package com.example

import android.app.Application
import com.example.notifications.SiteBinNotificationManager

class SiteBinApp : Application() {
    override fun onCreate() {
        super.onCreate()
        SiteBinNotificationManager.createChannel(this)
    }
}
