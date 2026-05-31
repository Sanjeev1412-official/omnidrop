package com.example.omnidrop

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import id.flutter.flutter_background_service.BackgroundService

class StartServiceActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        val serviceIntent = Intent(this, BackgroundService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        
        // Immediately finish so the user doesn't see anything
        finish()
        // Disable exit animation to make it perfectly smooth
        overridePendingTransition(0, 0)
    }
}
