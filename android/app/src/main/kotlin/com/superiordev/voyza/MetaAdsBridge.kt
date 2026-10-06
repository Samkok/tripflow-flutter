package com.superiordev.voyza

import android.app.Application
import android.content.Context
import android.os.Bundle
import android.util.Log
import com.facebook.FacebookSdk
import com.facebook.LoggingBehavior
import com.facebook.appevents.AppEventsLogger
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.math.BigDecimal
import java.util.Currency

/**
 * The app's only connection to Meta's SDK (ads measurement). The Dart side
 * is lib/services/meta_ads_bridge.dart.
 *
 * Meta's SDK does NOT start with the app. The provider that would start it
 * at launch is removed in AndroidManifest.xml, so until [start] is called
 * the SDK has made no request and stored nothing on the device. Dart calls
 * [start] only once the person has agreed to ads measurement (or, outside
 * the consent regions, has been shown the notice), and [stop] the moment
 * they withdraw.
 *
 * This is deliberately not the facebook_app_events plugin: that initialises
 * the SDK at launch for everyone, including people who refuse.
 */
class MetaAdsBridge(context: Context) : MethodChannel.MethodCallHandler {

    private val application = context.applicationContext as Application

    /** Non-null while ads measurement is on. */
    private var logger: AppEventsLogger? = null

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    start(call)
                    result.success(null)
                }
                "stop" -> {
                    stop()
                    result.success(null)
                }
                "logEvent" -> {
                    logEvent(call)
                    result.success(null)
                }
                "logPurchase" -> {
                    logPurchase(call)
                    result.success(null)
                }
                // Apple's tracking permission. Android has no such question.
                "setTrackingAllowed" -> result.success(null)
                "trackingStatus", "requestTracking" -> result.success("notSupported")
                // Android has no region setting apart from the language's
                // country, which Flutter already reports.
                "deviceRegion" -> result.success(null)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.w(TAG, "${call.method} failed", e)
            result.error("meta_ads", e.message, null)
        }
    }

    private fun start(call: MethodCall) {
        // SDK 18 still defaults to a Graph API version Meta has retired.
        // Named before initialising so the SDK's first request uses it.
        call.argument<String>("graphApiVersion")?.let { FacebookSdk.setGraphApiVersion(it) }

        if (!FacebookSdk.isInitialized()) {
            @Suppress("DEPRECATION")
            FacebookSdk.sdkInitialize(application)
        }
        // Debug builds only: the SDK says in logcat (tags starting with
        // "FacebookSDK.") what it sends and what Meta answered.
        if (call.argument<Boolean>("debugLogging") == true) {
            FacebookSdk.setIsDebugEnabled(true)
            FacebookSdk.addLoggingBehavior(LoggingBehavior.APP_EVENTS)
        }

        // Before anything is sent: Limited Data Use travels with every event.
        val options = call.argument<List<String>>("dataProcessingOptions") ?: emptyList()
        FacebookSdk.setDataProcessingOptions(
            options.toTypedArray(),
            call.argument<Int>("dataProcessingCountry") ?: 0,
            call.argument<Int>("dataProcessingState") ?: 0,
        )

        FacebookSdk.setAdvertiserIDCollectionEnabled(true)
        FacebookSdk.setAutoLogAppEventsEnabled(true)
        // Reports the install (once per install) and starts counting sessions.
        AppEventsLogger.activateApp(application)
        logger = AppEventsLogger.newLogger(application)
    }

    private fun stop() {
        logger = null
        // Never started in this process: nothing of Meta's is running.
        if (!FacebookSdk.isInitialized()) return
        FacebookSdk.setAutoLogAppEventsEnabled(false)
        FacebookSdk.setAdvertiserIDCollectionEnabled(false)
    }

    private fun logEvent(call: MethodCall) {
        val logger = logger ?: return
        val name = call.argument<String>("name") ?: return
        val parameters = bundleOf(call.argument<Map<String, Any?>>("parameters"))
        val valueToSum = call.argument<Double>("valueToSum")
        if (valueToSum != null) {
            logger.logEvent(name, valueToSum, parameters)
        } else {
            logger.logEvent(name, parameters)
        }
    }

    private fun logPurchase(call: MethodCall) {
        val logger = logger ?: return
        val amount = call.argument<Double>("amount") ?: return
        val currency = try {
            Currency.getInstance(call.argument<String>("currency") ?: return)
        } catch (e: IllegalArgumentException) {
            return
        }
        logger.logPurchase(
            BigDecimal.valueOf(amount),
            currency,
            bundleOf(call.argument<Map<String, Any?>>("parameters")),
        )
    }

    private fun bundleOf(map: Map<String, Any?>?): Bundle {
        val bundle = Bundle()
        map?.forEach { (key, value) ->
            when (value) {
                is String -> bundle.putString(key, value)
                is Int -> bundle.putInt(key, value)
                is Long -> bundle.putLong(key, value)
                is Double -> bundle.putDouble(key, value)
                is Boolean -> bundle.putBoolean(key, value)
            }
        }
        return bundle
    }

    private companion object {
        const val CHANNEL = "voyza/meta_ads"
        const val TAG = "MetaAdsBridge"
    }
}
