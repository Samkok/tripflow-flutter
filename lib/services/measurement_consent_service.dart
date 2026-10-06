import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/ads_event_map.dart';
import '../utils/measurement_decision.dart';
import '../utils/measurement_region.dart';
import 'revenuecat_service.dart';
import 'supabase_service.dart';

/// Turns the two choices into what the SDKs are allowed to do.
abstract class MeasurementApplier {
  Future<void> apply({required bool analytics, required bool ads});
}

/// Firebase / Google: the analytics master switch follows "Usage
/// analytics"; the Consent Mode ad signals follow "Ads measurement", and so
/// does Apple Search Ads attribution (read through RevenueCat on iOS).
class FirebaseMeasurementApplier implements MeasurementApplier {
  const FirebaseMeasurementApplier();

  @override
  Future<void> apply({required bool analytics, required bool ads}) async {
    if (ads) unawaited(RevenueCatService.enableAppleSearchAdsAttribution());
    // `Firebase.apps` never throws; `FirebaseAnalytics.instance` does before
    // the default app exists.
    if (Firebase.apps.isEmpty) return;
    final fa = FirebaseAnalytics.instance;
    await fa.setAnalyticsCollectionEnabled(analytics);
    await fa.setConsent(
      analyticsStorageConsentGranted: analytics,
      adStorageConsentGranted: ads,
      adUserDataConsentGranted: ads,
      adPersonalizationSignalsConsentGranted: ads,
    );
    // Performance monitoring is declared off in the native config and
    // follows the same choice as analytics.
    try {
      await FirebasePerformance.instance
          .setPerformanceCollectionEnabled(analytics);
    } catch (e) {
      debugPrint('FirebaseMeasurementApplier: performance: $e');
    }
    // The app instance id exists only while analytics is allowed, and the
    // first decision of a launch is often "unknown region" until the
    // country check answers — so hand it to RevenueCat each time analytics
    // comes on (idempotent), not just once at start-up.
    if (analytics) unawaited(RevenueCatService().linkFirebaseAppInstanceId());
  }
}

/// An advertising platform's SDK, as far as this app is concerned. Meta's is
/// `MetaAdsSink` (meta_ads_bridge.dart).
abstract class AdsMeasurementSink {
  /// Start or stop the SDK. Off means off: no automatic events, no
  /// advertising ID. An SDK that has never been enabled must not have run
  /// at all.
  Future<void> setEnabled(bool enabled);

  /// What the person answered to the system's tracking question (iOS).
  Future<void> setTrackingAllowed(bool allowed);

  /// Called only while ads measurement is on, and every time the event
  /// happens: one marked [AdsEvent.oncePerInstall] is the sink's to pass on
  /// the first time only, since only the sink knows whether it got through.
  void log(AdsEvent event);
}

/// Asks our own server which country this connection comes from. Returns
/// null when it cannot say.
typedef CountryLookup = Future<String?> Function();

/// The database function behind [CountryLookup]: it reads the country the
/// network edge reports for the request and returns it. No address is
/// stored anywhere (migration 20261002090000_request_country.sql).
Future<String?> requestCountryFromServer() async {
  await SupabaseService.waitForInitialization();
  final result = await SupabaseService.instance.client
      .rpc<dynamic>('request_country')
      .timeout(const Duration(seconds: 4));
  return normalizeCountryCode(result is String ? result : null);
}

/// Asks the platform which country the device itself is set to. Returns
/// null when the platform has nothing better than the language's country.
///
/// On an iPhone the Region setting is not the country in the language tag
/// Flutter reports: set the Region to France and the language stays
/// "English (Cambodia)". Only native code sees the region.
typedef DeviceRegionLookup = Future<String?> Function();

/// The person's two measurement choices — "Usage analytics" and "Ads
/// measurement" — what follows from them, and what to ask.
///
/// Replaces [AnalyticsConsentService] in builds where
/// `MeasurementConfig.adsMeasurement` is on. The rules themselves live in
/// [decideMeasurement]; this class remembers the choices, finds out where
/// the person is, and tells the SDKs.
class MeasurementConsentService {
  MeasurementConsentService({
    Future<SharedPreferences> Function()? prefs,
    MeasurementApplier applier = const FirebaseMeasurementApplier(),
    CountryLookup lookupCountry = requestCountryFromServer,
    String? Function()? deviceCountry,
    this.lookupDeviceRegion,
  })  : _prefs = prefs ?? SharedPreferences.getInstance,
        _applier = applier,
        _lookupCountry = lookupCountry,
        _deviceCountry = deviceCountry ??
            (() => PlatformDispatcher.instance.locale.countryCode);

  static final MeasurementConsentService instance = MeasurementConsentService();

  static const String keyAnalytics = 'measurement_v2_analytics';
  static const String keyAds = 'measurement_v2_ads';
  static const String keyNoticeShown = 'measurement_v2_notice_shown';
  static const String keyCountry = 'measurement_v2_country';
  static const String keyMigrated = 'measurement_v2_migrated';

  /// The single choice this replaces ([AnalyticsConsentService]).
  static const String legacyKey = 'analytics_consent_v1';

  static const String _granted = 'granted';
  static const String _denied = 'denied';

  final Future<SharedPreferences> Function() _prefs;
  final MeasurementApplier _applier;
  final CountryLookup _lookupCountry;
  final String? Function() _deviceCountry;
  final List<AdsMeasurementSink> _sinks = [];

  /// Where to ask for the platform's own region setting. Start-up sets it
  /// before [applyAtStartup] (`deviceRegionFromPlatform` in
  /// meta_ads_bridge.dart); without it the language's country is all the
  /// device says.
  DeviceRegionLookup? lookupDeviceRegion;

  MeasurementChoices? _choices;
  String? _connectionCountry;
  String? _deviceRegion;
  Future<void>? _regionRefresh;

  /// This run has asked the server where the connection comes from, or has
  /// tried and failed. Until then the country in hand is last run's.
  bool _regionChecked = false;

  /// What the SDKs were last told. Null before the first decision.
  ({bool analytics, bool ads})? _applied;

  /// The decision in force. Null until [applyAtStartup] has run.
  final ValueNotifier<MeasurementDecision?> decision = ValueNotifier(null);

  /// Whether ads measurement is running right now. It can lag
  /// `decision.ads` by a moment at launch: see [_reapply].
  bool get adsAllowed => _applied?.ads ?? false;

  /// What the person has said so far.
  MeasurementChoices get choices => _choices ?? const MeasurementChoices();

  /// Reads the stored choices, carries the old single choice over once,
  /// decides from the last known country and applies the result. The
  /// country is then refreshed in the background; if that changes the
  /// decision, it is applied again. Ads measurement that is merely on by
  /// default waits for that refresh (see [_reapply]).
  Future<MeasurementDecision> applyAtStartup() async {
    final result = await _load();
    _regionRefresh = refreshRegion().then((_) {});
    return result;
  }

  /// The decision in force, loading it if nothing has run yet.
  Future<MeasurementDecision> current() async =>
      decision.value ?? await _load();

  /// Waits for the country check started by [applyAtStartup], up to
  /// [timeout]. The prompts call this so they ask the right thing on a
  /// first launch.
  Future<MeasurementDecision> whenRegionSettled({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final refresh = _regionRefresh;
    if (refresh != null) {
      try {
        await refresh.timeout(timeout);
      } on TimeoutException {
        // Still unknown: nothing runs and nothing is asked this time.
      }
    }
    return current();
  }

  /// Asks the server for the connection's country and re-decides. A failed
  /// lookup leaves the last known country in place.
  Future<MeasurementDecision> refreshRegion() async {
    await current();
    try {
      final country = normalizeCountryCode(await _lookupCountry());
      if (country != null && country != _connectionCountry) {
        _connectionCountry = country;
        await (await _prefs()).setString(keyCountry, country);
      }
    } catch (e) {
      debugPrint('MeasurementConsentService.refreshRegion: $e');
    }
    _regionChecked = true;
    return _reapply();
  }

  /// The answer to the opt-in prompt: one yes or no per purpose.
  Future<MeasurementDecision> recordConsent({
    required bool analytics,
    required bool ads,
  }) =>
      _update((c) => c.copyWith(analytics: analytics, ads: ads), {
        keyAnalytics: analytics,
        keyAds: ads,
      });

  /// The notice was shown. [keepOn] false is the "Turn off" button: a
  /// choice, and it sticks.
  Future<MeasurementDecision> acknowledgeNotice({required bool keepOn}) =>
      _update(
        (c) => MeasurementChoices(
          analytics: c.analytics,
          ads: keepOn ? c.ads : false,
          noticeShown: true,
        ),
        {if (!keepOn) keyAds: false},
        noticeShown: true,
      );

  /// The Settings switches. Either way round is an explicit choice.
  Future<MeasurementDecision> setAnalytics(bool on) =>
      _update((c) => c.copyWith(analytics: on), {keyAnalytics: on});

  Future<MeasurementDecision> setAds(bool on) =>
      _update((c) => c.copyWith(ads: on), {keyAds: on});

  /// Registers an advertising SDK and puts it in the current state.
  void addSink(AdsMeasurementSink sink) {
    _sinks.add(sink);
    final applied = _applied;
    if (applied != null) unawaited(_guard(() => sink.setEnabled(applied.ads)));
  }

  /// One of the app's analytics events, on its way to the advertising
  /// SDKs. Dropped unless ads measurement is on and the event is one the
  /// privacy policy lists (see [adsEventFor]). Never throws.
  void logAdsEvent(String name, [Map<String, Object>? params]) {
    try {
      if (!adsAllowed || _sinks.isEmpty) return;
      final event = adsEventFor(name, params);
      if (event == null) return;
      for (final sink in _sinks) {
        sink.log(event);
      }
    } catch (e) {
      debugPrint('MeasurementConsentService.logAdsEvent $name: $e');
    }
  }

  /// Passes the system tracking answer on to the advertising SDKs.
  Future<void> reportTrackingAllowed(bool allowed) async {
    for (final sink in _sinks) {
      await _guard(() => sink.setTrackingAllowed(allowed));
    }
  }

  // ── internals ─────────────────────────────────────────────────────────

  Future<MeasurementDecision> _load() async {
    try {
      final prefs = await _prefs();
      await _migrateLegacy(prefs);
      _choices = MeasurementChoices(
        analytics: _readChoice(prefs, keyAnalytics),
        ads: _readChoice(prefs, keyAds),
        noticeShown: prefs.getBool(keyNoticeShown) ?? false,
      );
      _connectionCountry = normalizeCountryCode(prefs.getString(keyCountry));
    } catch (e) {
      // Nothing readable: no choice on record, region unknown — so nothing
      // runs and nothing is asked.
      debugPrint('MeasurementConsentService: could not read choices: $e');
      _choices ??= const MeasurementChoices();
    }
    _deviceRegion = await _readDeviceRegion();
    return _reapply();
  }

  /// The platform's region setting, asked once per run: the system restarts
  /// apps when it changes.
  Future<String?> _readDeviceRegion() async {
    final lookup = lookupDeviceRegion;
    if (lookup == null) return null;
    try {
      return normalizeCountryCode(
          await lookup().timeout(const Duration(seconds: 2)));
    } catch (e) {
      debugPrint('MeasurementConsentService: device region unavailable: $e');
      return null;
    }
  }

  /// The old single switch covered analytics and the Google ad signals
  /// together. A no carries over to both purposes. A yes carries over to
  /// analytics only: ads measurement now involves a company that yes never
  /// heard of, so it has to be asked afresh.
  Future<void> _migrateLegacy(SharedPreferences prefs) async {
    if (prefs.getBool(keyMigrated) ?? false) return;
    final legacy = prefs.getString(legacyKey);
    if (legacy == _denied) {
      await prefs.setString(keyAnalytics, _denied);
      await prefs.setString(keyAds, _denied);
    } else if (legacy == _granted) {
      await prefs.setString(keyAnalytics, _granted);
    }
    await prefs.setBool(keyMigrated, true);
  }

  static bool? _readChoice(SharedPreferences prefs, String key) {
    final stored = prefs.getString(key);
    if (stored == _granted) return true;
    if (stored == _denied) return false;
    return null;
  }

  Future<MeasurementDecision> _update(
    MeasurementChoices Function(MeasurementChoices) change,
    Map<String, bool> stored, {
    bool noticeShown = false,
  }) async {
    await current();
    _choices = change(_choices ?? const MeasurementChoices());
    try {
      final prefs = await _prefs();
      for (final entry in stored.entries) {
        await prefs.setString(entry.key, entry.value ? _granted : _denied);
      }
      if (noticeShown) await prefs.setBool(keyNoticeShown, true);
    } catch (e) {
      // Applied for this run even if it could not be written down.
      debugPrint('MeasurementConsentService: could not store choice: $e');
    }
    return _reapply();
  }

  Future<MeasurementDecision> _reapply() async {
    final next = decideMeasurement(
      choices: _choices ?? const MeasurementChoices(),
      region: measurementRegionFor(
        deviceCountry: _deviceCountry(),
        deviceRegion: _deviceRegion,
        connectionCountry: _connectionCountry,
      ),
    );
    // Ads measurement starts only on firm ground: the person said yes
    // themselves, or this run has checked where the connection comes from.
    // "On by default" resting on last run's country is not enough, because
    // they may have travelled into a consent region since, and an SDK that
    // has contacted the ad platform cannot take that back. The wait is one
    // server round trip at launch; if the server cannot be reached, the
    // last known country stands.
    final ads = next.ads && (_choices?.ads == true || _regionChecked);
    final applied = _applied;
    if (applied == null ||
        applied.analytics != next.analytics ||
        applied.ads != ads) {
      _applied = (analytics: next.analytics, ads: ads);
      await _guard(() => _applier.apply(analytics: next.analytics, ads: ads));
      if (applied?.ads != ads) {
        for (final sink in _sinks) {
          await _guard(() => sink.setEnabled(ads));
        }
      }
    }
    decision.value = next;
    return next;
  }

  static Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('MeasurementConsentService: $e');
    }
  }
}
