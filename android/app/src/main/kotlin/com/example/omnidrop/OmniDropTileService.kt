package com.example.omnidrop

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi
import id.flutter.flutter_background_service.BackgroundService

@RequiresApi(Build.VERSION_CODES.N)
class OmniDropTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        updateTileState()
    }

    override fun onClick() {
        super.onClick()
        val currentlyRunning = isServiceRunning()
        
        val intent = Intent(this, BackgroundService::class.java)
        if (!currentlyRunning) {
            try {
                // Try direct background start (will fail on Android 12+ if completely closed)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
            } catch (e: Exception) {
                // Background start denied. Fallback to transparent Activity
                val activityIntent = Intent(this, StartServiceActivity::class.java)
                activityIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
                
                val pendingIntent = android.app.PendingIntent.getActivity(
                    this, 
                    0, 
                    activityIntent, 
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                )
                
                if (Build.VERSION.SDK_INT >= 34) {
                    startActivityAndCollapse(pendingIntent)
                } else {
                    @Suppress("DEPRECATION")
                    startActivityAndCollapse(activityIntent)
                }
            }
        } else {
            // Stop the service
            stopService(intent)
        }
        
        // Brief delay to allow service to start/stop before updating UI
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            updateTileState()
        }, 500)
    }

    @Suppress("DEPRECATION")
    private fun isServiceRunning(): Boolean {
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        for (service in manager.getRunningServices(Integer.MAX_VALUE)) {
            if (BackgroundService::class.java.name == service.service.className) {
                return true
            }
        }
        return false
    }

    private fun updateTileState() {
        val tile = qsTile
        if (tile != null) {
            val running = isServiceRunning()
            if (running) {
                tile.state = Tile.STATE_ACTIVE
                tile.label = "OmniDrop"
            } else {
                tile.state = Tile.STATE_INACTIVE
                tile.label = "OmniDrop"
            }
            tile.updateTile()
        }
    }
}
