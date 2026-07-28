import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GDPR/UK-GDPR/FADP consent gate for Firebase Analytics.
///
/// Default posture:
///   • EU/EEA/UK/CH users → analytics collection OFF until they explicitly
///     opt in (prior consent required). [shouldAskForConsent] drives a one-time
///     prompt; until then nothing is collected.
///   • Everyone else → ON by default, with an opt-out in Settings.
///
/// Applies both `setAnalyticsCollectionEnabled` (master switch) and
/// `setConsent` (Google Consent Mode v2 — gates ad-related signals) so the
/// RevenueCat→ad-platform value events also respect the choice.
class AnalyticsConsentService {
  AnalyticsConsentService._();
  static final instance = AnalyticsConsentService._();

  static const _kConsent = 'analytics_consent_v1'; // 'granted' | 'denied'

  /// EEA + UK + Switzerland (consent-required jurisdictions).
  static const _consentRequiredCountries = {
    'AT',
    'BE',
    'BG',
    'HR',
    'CY',
    'CZ',
    'DK',
    'EE',
    'FI',
    'FR',
    'DE',
    'GR',
    'HU',
    'IE',
    'IT',
    'LV',
    'LT',
    'LU',
    'MT',
    'NL',
    'PL',
    'PT',
    'RO',
    'SK',
    'SI',
    'ES',
    'SE',
    'IS',
    'LI',
    'NO',
    'GB',
    'CH',
  };

  bool get _consentRequired {
    final cc = PlatformDispatcher.instance.locale.countryCode?.toUpperCase();
    return cc != null && _consentRequiredCountries.contains(cc);
  }

  /// Effective default when the user hasn't made an explicit choice.
  bool get _defaultEnabled => !_consentRequired;

  /// Apply the stored/implied consent to Firebase. Call AFTER
  /// `Firebase.initializeApp()`. Safe pre-init (no-ops until the app exists).
  Future<void> applyAtStartup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_kConsent);
      await _apply(stored != null ? stored == 'granted' : _defaultEnabled);
    } catch (e) {
      debugPrint('AnalyticsConsentService.applyAtStartup: $e');
    }
  }

  /// True when we must show the one-time opt-in prompt: a consent-required
  /// user who hasn't chosen yet.
  Future<bool> shouldAskForConsent() async {
    try {
      if (!_consentRequired) return false;
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kConsent) == null;
    } catch (_) {
      return false;
    }
  }

  /// Record + apply an explicit choice (from the prompt or Settings toggle).
  Future<void> setConsent(bool granted) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kConsent, granted ? 'granted' : 'denied');
      await _apply(granted);
    } catch (e) {
      debugPrint('AnalyticsConsentService.setConsent: $e');
    }
  }

  /// Current effective enabled state (for the Settings toggle).
  Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_kConsent);
      return stored != null ? stored == 'granted' : _defaultEnabled;
    } catch (_) {
      return _defaultEnabled;
    }
  }

  Future<void> _apply(bool enabled) async {
    if (Firebase.apps.isEmpty) return;
    try {
      final fa = FirebaseAnalytics.instance;
      await fa.setAnalyticsCollectionEnabled(enabled);
      await fa.setConsent(
        analyticsStorageConsentGranted: enabled,
        adStorageConsentGranted: enabled,
        adUserDataConsentGranted: enabled,
        adPersonalizationSignalsConsentGranted: enabled,
      );
    } catch (e) {
      debugPrint('AnalyticsConsentService._apply: $e');
    }
  }
}
