package com.superiordev.voyza

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // launchMode is singleTop, so a link that arrives while the app is
        // running comes through here. Keep getIntent() current: Meta's SDK
        // reads it when the activity resumes, to pick up the ad parameters
        // of such a link (see MetaAdsBridge).
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Ads measurement. Only listens here; Meta's SDK starts when Dart
        // says the person has allowed it (see MetaAdsBridge).
        MetaAdsBridge(this).attach(flutterEngine.dartExecutor.binaryMessenger)
        // The abuse-check device identifier (free trials, referrals): the
        // Android ID, one value per device for this app's signing key. See
        // lib/services/abuse_check_device_id.dart.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voyza/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "androidId" -> result.success(
                        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                    )
                    else -> result.notImplemented()
                }
            }
    }
}
