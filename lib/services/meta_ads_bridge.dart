import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/ads_event_map.dart';
import '../utils/measurement_region.dart';
import 'measurement_consent_service.dart';
import 'revenuecat_service.dart';
import 'tracking_permission.dart';

/// The channel to the native side that owns Meta's SDK and Apple's tracking
/// prompt: `MetaAdsBridge` in `ios/Runner/AppDelegate.swift` and in
/// `android/app/src/main/kotlin/com/superiordev/voyza/MetaAdsBridge.kt`.
const MethodChannel metaAdsChannel = MethodChannel('voyza/meta_ads');

/// Meta's SDK, as the consent service sees it.
///
/// The SDK is not part of app start-up. The native bridge initialises it
/// the first time [setEnabled] is called with true: once the person has
/// agreed to ads measurement or, outside the consent regions, has been
/// shown the notice. Before that no request reaches Meta and nothing of
/// Meta's is stored on the device. For someone who never allows it, the SDK
/// never runs at all.
class MetaAdsSink implements AdsMeasurementSink {
  MetaAdsSink({
    MethodChannel channel = metaAdsChannel,
    Future<SharedPreferences> Function()? prefs,
    AdsAttributionLink? attribution,
  })  : _channel = channel,
        _prefs = prefs ?? SharedPreferences.getInstance,
        _attribution = attribution;

  /// The Graph API version the SDK talks to. SDK 18 still defaults to
  /// versions Meta has retired, so it has to be named. Meta retires each
  /// version about two years after its release: v24.0 works until
  /// 18 February 2028. Raise it when the SDK is upgraded.
  static const String graphApiVersion = 'v24.0';

  /// Meta's Limited Data Use, sent with every event, in the mode where Meta
  /// works out from the person's location whether one of the US state
  /// privacy laws it covers applies (country 0, state 0).
  static const List<String> dataProcessingOptions = ['LDU'];

  /// Where this install notes that Meta has been told of a once-only event
  /// ([AdsEvent.oncePerInstall]): this prefix, then Meta's name for it.
  static const String sentOnceKeyPrefix = 'meta_ads_sent_once_';

  final MethodChannel _channel;
  final Future<SharedPreferences> Function() _prefs;
  final AdsAttributionLink? _attribution;
  bool _logging = false;

  /// The once-only events this run has sent, or is sending right now.
  final Set<String> _sentOnce = {};

  @override
  Future<void> setEnabled(bool enabled) async {
    // Nothing is logged while the switch is being thrown.
    _logging = false;
    if (!enabled) {
      await _invoke('stop');
      await _attribution?.detach();
      return;
    }
    _logging = await _invoke('start', {
      'graphApiVersion': graphApiVersion,
      'dataProcessingOptions': dataProcessingOptions,
      'dataProcessingCountry': 0,
      'dataProcessingState': 0,
      // Debug builds: the SDK prints what it records and what Meta answers
      // (Xcode console "FBSDKAppEvents: Flushed ... - Success"; logcat tags
      // starting "FacebookSDK.").
      'debugLogging': kDebugMode,
    });
    if (_logging) await _attach();
  }

  @override
  Future<void> setTrackingAllowed(bool allowed) async {
    await _invoke('setTrackingAllowed', allowed);
    // The advertising identifier has just become readable (or not): the
    // purchase reporter must see the current answer.
    if (_logging) await _attach();
  }

  /// Gives the purchase reporter Meta's install identifier, so the trials
  /// and purchases it reports can be matched to this install's ad clicks.
  Future<void> _attach() async {
    final link = _attribution;
    if (link == null) return;
    String? id;
    try {
      id = await _channel.invokeMethod<String>('anonymousId');
    } on MissingPluginException {
      return;
    } catch (e) {
      debugPrint('MetaAdsSink.anonymousId: $e');
    }
    await link.attach(id);
  }

  @override
  void log(AdsEvent event) {
    if (!_logging) return;
    if (event.oncePerInstall) {
      unawaited(_logOnce(event));
      return;
    }
    unawaited(_send(event));
  }

  /// Sends [event] unless this install has already told Meta. The note is
  /// written before the event goes out and taken back if the native side
  /// did not take it: Meta never hears it twice, and a failed attempt is
  /// not the last. Without somewhere to write the note, nothing is sent.
  Future<void> _logOnce(AdsEvent event) async {
    // Two in quick succession: the second finds the first at work.
    if (!_sentOnce.add(event.name)) return;
    var told = false;
    try {
      final prefs = await _prefs();
      final key = '$sentOnceKeyPrefix${event.name}';
      if (prefs.getBool(key) ?? false) {
        told = true;
        return;
      }
      if (!await prefs.setBool(key, true)) return;
      // Switched off while the note was being written: nothing goes out.
      told = _logging && await _send(event);
      if (!told) await prefs.remove(key);
    } catch (e) {
      debugPrint('MetaAdsSink.logOnce ${event.name}: $e');
    } finally {
      if (!told) _sentOnce.remove(event.name);
    }
  }

  /// Hands [event] to the SDK. Whether the native side took it.
  Future<bool> _send(AdsEvent event) {
    final value = event.value;
    final currency = event.currency;
    if (event.isPurchase && value != null && currency != null) {
      return _invoke('logPurchase', {
        'amount': value,
        'currency': currency,
        'parameters': event.parameters,
      });
    }
    return _invoke('logEvent', {
      'name': event.name,
      'parameters': {
        ...event.parameters,
        if (value != null && currency != null) 'fb_currency': currency,
      },
      if (value != null) 'valueToSum': value,
    });
  }

  /// Whether the native side did it. No bridge on this platform (tests,
  /// desktop, web) means ads measurement does not exist here: not an error.
  Future<bool> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
      return true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('MetaAdsSink.$method: $e');
      return false;
    }
  }
}

/// Whoever reports purchases to the ad platform from a server — RevenueCat,
/// through `RevenueCatService.attachMetaIdentifiers` — and needs the
/// identifiers that let the platform match those purchases to an install.
/// [attach] is called whenever ads measurement is on and the identifiers
/// may have changed; [detach] when it is withdrawn, after which the reporter
/// must send nothing more about this person. Never throws.
abstract class AdsAttributionLink {
  Future<void> attach(String? anonymousId);
  Future<void> detach();
}

/// RevenueCat as the purchase reporter: its Meta integration sends trial
/// starts, conversions, purchases and renewals from RevenueCat's servers,
/// for customers carrying these identifiers and for no one else.
class RevenueCatAttributionLink implements AdsAttributionLink {
  const RevenueCatAttributionLink();

  @override
  Future<void> attach(String? anonymousId) =>
      RevenueCatService.attachMetaIdentifiers(anonymousId);

  @override
  Future<void> detach() => RevenueCatService.detachMetaIdentifiers();
}

/// Apple's App Tracking Transparency question, asked through the native
/// bridge. Android, and any platform without the bridge, answer
/// [TrackingStatus.notSupported].
class AppleTrackingPermission implements TrackingPermissionGateway {
  const AppleTrackingPermission({MethodChannel channel = metaAdsChannel})
      : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<TrackingStatus> status() => _ask('trackingStatus');

  @override
  Future<TrackingStatus> request() => _ask('requestTracking');

  Future<TrackingStatus> _ask(String method) async {
    try {
      return trackingStatusFromName(
          await _channel.invokeMethod<String>(method));
    } on MissingPluginException {
      return TrackingStatus.notSupported;
    } catch (e) {
      debugPrint('AppleTrackingPermission.$method: $e');
      return TrackingStatus.notSupported;
    }
  }
}

/// The device's own region setting, asked of the native bridge. On an
/// iPhone this is Settings → General → Language & Region → Region, which
/// the language Flutter reports does not follow. Null on Android and
/// wherever there is no bridge: there the language's country is the
/// device's answer.
Future<String?> deviceRegionFromPlatform({
  MethodChannel channel = metaAdsChannel,
}) async {
  try {
    return normalizeCountryCode(
        await channel.invokeMethod<String>('deviceRegion'));
  } on MissingPluginException {
    return null;
  } catch (e) {
    debugPrint('deviceRegionFromPlatform: $e');
    return null;
  }
}

/// The native bridge's name for a status, as a [TrackingStatus]. Anything
/// unrecognised counts as "no such permission here".
TrackingStatus trackingStatusFromName(String? name) => switch (name) {
      'notDetermined' => TrackingStatus.notDetermined,
      'restricted' => TrackingStatus.restricted,
      'denied' => TrackingStatus.denied,
      'authorized' => TrackingStatus.authorized,
      _ => TrackingStatus.notSupported,
    };
