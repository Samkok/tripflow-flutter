import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/services/measurement_consent_service.dart';
import 'package:voyza/services/meta_ads_bridge.dart';
import 'package:voyza/services/tracking_permission.dart';
import 'package:voyza/utils/ads_event_map.dart';

class _Applier implements MeasurementApplier {
  @override
  Future<void> apply({required bool analytics, required bool ads}) async {}
}

/// The native side of the channel: remembers what it was asked to do.
class _Native {
  final calls = <MethodCall>[];
  String? failOn;
  Object? Function(MethodCall call)? answer;

  List<String> get methods => [for (final c in calls) c.method];

  Map<Object?, Object?> arguments(String method) =>
      calls.lastWhere((c) => c.method == method).arguments
          as Map<Object?, Object?>;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(metaAdsChannel, (call) async {
      calls.add(call);
      if (call.method == failOn) {
        throw PlatformException(code: 'meta_ads', message: 'sdk exploded');
      }
      return answer?.call(call);
    });
  }

  static void remove() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(metaAdsChannel, null);
}

/// Lets what was started run to its end: reading and writing the install's
/// notes takes a few turns of the event loop.
Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Native native;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    native = _Native()..install();
  });
  tearDown(_Native.remove);

  group("Meta's SDK", () {
    test('is not touched until ads measurement is switched on', () {
      MetaAdsSink().log(const AdsEvent(adsEventTripCreated));
      expect(native.calls, isEmpty);
    });

    test('starts with a live API version and Limited Data Use', () async {
      await MetaAdsSink().setEnabled(true);
      expect(native.methods, ['start']);
      final start = native.arguments('start');
      expect(start['graphApiVersion'], MetaAdsSink.graphApiVersion);
      expect(start['dataProcessingOptions'], ['LDU']);
      // Zero and zero: Meta works out from the person's location whether a
      // US state law applies.
      expect(start['dataProcessingCountry'], 0);
      expect(start['dataProcessingState'], 0);
    });

    test('receives the events as Meta names them', () async {
      final sink = MetaAdsSink();
      await sink.setEnabled(true);
      native.calls.clear();

      sink.log(adsEventFor('signup', {'method': 'google'})!);
      sink.log(adsEventFor('trip_created')!);
      sink.log(adsEventFor('trial_started', {'product': 'premium.yearly'})!);
      await Future<void>.delayed(Duration.zero);

      expect(native.methods, ['logEvent', 'logEvent', 'logEvent']);
      expect(native.calls[0].arguments, {
        'name': 'fb_mobile_complete_registration',
        'parameters': {'fb_registration_method': 'google'},
      });
      expect(native.calls[1].arguments,
          {'name': 'TripCreated', 'parameters': <String, Object>{}});
      expect(native.calls[2].arguments, {
        'name': 'StartTrial',
        'parameters': {'fb_content_id': 'premium.yearly'},
      });
    });

    test('a subscription carries its price and currency', () async {
      final sink = MetaAdsSink();
      await sink.setEnabled(true);
      sink.log(adsEventFor('purchase', {
        'product': 'premium.yearly',
        'value': 29.99,
        'currency': 'USD',
      })!);
      await Future<void>.delayed(Duration.zero);

      expect(native.arguments('logEvent'), {
        'name': 'Subscribe',
        'parameters': {'fb_content_id': 'premium.yearly', 'fb_currency': 'USD'},
        'valueToSum': 29.99,
      });
    });

    test('a one-off purchase is logged as a purchase', () async {
      final sink = MetaAdsSink();
      await sink.setEnabled(true);
      sink.log(adsEventFor('purchase', {
        'product': 'premium.lifetime',
        'value': 79.0,
        'currency': 'EUR',
      })!);
      await Future<void>.delayed(Duration.zero);

      expect(native.methods.last, 'logPurchase');
      expect(native.arguments('logPurchase'), {
        'amount': 79.0,
        'currency': 'EUR',
        'parameters': {'fb_content_id': 'premium.lifetime'},
      });
    });

    test('stops at once when switched off, and logs nothing after', () async {
      final sink = MetaAdsSink();
      await sink.setEnabled(true);
      await sink.setEnabled(false);
      sink.log(const AdsEvent(adsEventTripCreated));
      await Future<void>.delayed(Duration.zero);
      expect(native.methods, ['start', 'stop']);
    });

    test('logs nothing if it could not be started', () async {
      native.failOn = 'start';
      final sink = MetaAdsSink();
      await sink.setEnabled(true);
      sink.log(const AdsEvent(adsEventTripCreated));
      await Future<void>.delayed(Duration.zero);
      expect(native.methods, ['start']);
    });

    test('a failing event never reaches the caller', () async {
      final sink = MetaAdsSink();
      await sink.setEnabled(true);
      native.failOn = 'logEvent';
      expect(
          () => sink.log(const AdsEvent(adsEventTripCreated)), returnsNormally);
      await Future<void>.delayed(Duration.zero);
    });

    test('is simply absent where there is no native bridge', () async {
      _Native.remove();
      final sink = MetaAdsSink();
      await sink.setEnabled(true);
      await sink.setTrackingAllowed(true);
      sink.log(const AdsEvent(adsEventTripCreated));
      await sink.setEnabled(false);
    });

    test("hears the answer to Apple's question", () async {
      await MetaAdsSink().setTrackingAllowed(true);
      expect(native.methods, ['setTrackingAllowed']);
      expect(native.calls.single.arguments, isTrue);
    });
  });

  group('a first optimized route', () {
    final route =
        adsEventFor('route_optimized', {'stops': 7, 'minutes_saved': 12})!;

    int told() => native.methods.where((m) => m == 'logEvent').length;

    test('reaches Meta bare, and only once per install', () async {
      final sink = MetaAdsSink();
      await sink.setEnabled(true);

      sink.log(route);
      await _settle();
      expect(native.arguments('logEvent'),
          {'name': 'RouteOptimized', 'parameters': <String, Object>{}});

      // Optimizing again, today or on any later day, says nothing more.
      sink.log(route);
      sink.log(route);
      await _settle();
      expect(told(), 1);

      // Nor does the next launch.
      final nextLaunch = MetaAdsSink();
      await nextLaunch.setEnabled(true);
      nextLaunch.log(route);
      await _settle();
      expect(told(), 1);
    });

    test('two in the same instant are still one', () async {
      final sink = MetaAdsSink();
      await sink.setEnabled(true);
      sink.log(route);
      sink.log(route);
      await _settle();
      expect(told(), 1);
    });

    test('one that could not be handed over is not the last', () async {
      final sink = MetaAdsSink();
      await sink.setEnabled(true);
      native.failOn = 'logEvent';
      sink.log(route);
      await _settle();
      expect(told(), 1, reason: 'tried, and the SDK refused');

      native.failOn = null;
      sink.log(route);
      await _settle();
      expect(told(), 2);

      sink.log(route);
      await _settle();
      expect(told(), 2, reason: 'handed over: never again');
    });

    test('one optimized while ads measurement is off does not use it up',
        () async {
      final sink = MetaAdsSink();
      sink.log(route);
      await _settle();
      expect(native.calls, isEmpty);

      await sink.setEnabled(true);
      sink.log(route);
      await _settle();
      expect(told(), 1);
    });

    test('switched off in the same instant: nothing goes out', () async {
      final sink = MetaAdsSink();
      await sink.setEnabled(true);
      sink.log(route);
      await sink.setEnabled(false);
      await _settle();
      expect(told(), 0);

      // And it was not used up.
      await sink.setEnabled(true);
      sink.log(route);
      await _settle();
      expect(told(), 1);
    });

    test('nothing is sent when the note cannot be kept', () async {
      final sink = MetaAdsSink(prefs: () async => throw StateError('no disk'));
      await sink.setEnabled(true);
      expect(() => sink.log(route), returnsNormally);
      await _settle();
      expect(told(), 0);
    });

    test('does not hold back the events that are told every time', () async {
      final sink = MetaAdsSink();
      await sink.setEnabled(true);
      sink.log(route);
      sink.log(const AdsEvent(adsEventTripCreated));
      sink.log(const AdsEvent(adsEventTripCreated));
      await _settle();
      expect(told(), 3);
    });
  });

  group('behind the consent service', () {
    Future<MeasurementConsentService> boot(String country) async {
      final service = MeasurementConsentService(
        applier: _Applier(),
        deviceCountry: () => country,
        lookupCountry: () async => country,
      )..addSink(MetaAdsSink());
      await service.applyAtStartup();
      await service.whenRegionSettled();
      return service;
    }

    test('never starts for someone in Europe who says no', () async {
      final service = await boot('DE');
      await service.recordConsent(analytics: true, ads: false);
      service.logAdsEvent('trip_created');
      await (await boot('DE')).current();
      await Future<void>.delayed(Duration.zero);
      expect(native.methods, isNot(contains('start')));
      expect(native.methods, isNot(contains('logEvent')));
    });

    test('starts in Europe only with the yes', () async {
      final service = await boot('FR');
      expect(native.methods, isNot(contains('start')));
      await service.recordConsent(analytics: false, ads: true);
      expect(native.methods.last, 'start');

      // The yes holds on the next launch.
      native.calls.clear();
      await boot('FR');
      expect(native.methods, contains('start'));
    });

    test('elsewhere, starts only after the notice', () async {
      final service = await boot('US');
      expect(native.methods, isNot(contains('start')));
      await service.acknowledgeNotice(keepOn: true);
      expect(native.methods.last, 'start');
      service.logAdsEvent('trip_created');
      await Future<void>.delayed(Duration.zero);
      expect(native.methods.last, 'logEvent');
    });

    test('passes a first optimized route on once, however often', () async {
      final service = await boot('US');
      await service.acknowledgeNotice(keepOn: true);
      native.calls.clear();

      service.logAdsEvent('route_optimized', {'stops': 4, 'minutes_saved': 9});
      await _settle();
      service.logAdsEvent('route_optimized', {'stops': 6, 'minutes_saved': 0});
      await _settle();

      expect(native.methods, ['logEvent']);
      expect(native.arguments('logEvent'),
          {'name': 'RouteOptimized', 'parameters': <String, Object>{}});
    });

    test('"Turn off" on the notice means it never starts', () async {
      final service = await boot('US');
      await service.acknowledgeNotice(keepOn: false);
      await boot('US');
      expect(native.methods, isNot(contains('start')));
    });
  });

  group("the device's region setting", () {
    test('is read from the native side', () async {
      native.answer = (_) => 'FR';
      expect(await deviceRegionFromPlatform(), 'FR');
      expect(native.methods, ['deviceRegion']);
    });

    test('is tidied, and junk is no answer', () async {
      native.answer = (_) => ' fr ';
      expect(await deviceRegionFromPlatform(), 'FR');
      // "001" is the world, "419" Latin America: regions, not countries.
      native.answer = (_) => '001';
      expect(await deviceRegionFromPlatform(), isNull);
    });

    test('is absent on Android, without a bridge, or when the bridge fails',
        () async {
      native.answer = (_) => null;
      expect(await deviceRegionFromPlatform(), isNull);
      native.failOn = 'deviceRegion';
      expect(await deviceRegionFromPlatform(), isNull);
      _Native.remove();
      expect(await deviceRegionFromPlatform(), isNull);
    });
  });

  group("Apple's tracking permission", () {
    test('reads each answer the system can give', () async {
      const names = {
        'notDetermined': TrackingStatus.notDetermined,
        'restricted': TrackingStatus.restricted,
        'denied': TrackingStatus.denied,
        'authorized': TrackingStatus.authorized,
        'notSupported': TrackingStatus.notSupported,
        'something new': TrackingStatus.notSupported,
      };
      for (final entry in names.entries) {
        native.answer = (_) => entry.key;
        expect(await const AppleTrackingPermission().status(), entry.value,
            reason: entry.key);
      }
    });

    test('asks through the bridge and returns the answer', () async {
      native.answer = (call) =>
          call.method == 'requestTracking' ? 'authorized' : 'notDetermined';
      const permission = AppleTrackingPermission();
      expect(await permission.status(), TrackingStatus.notDetermined);
      expect(await permission.request(), TrackingStatus.authorized);
      expect(native.methods, ['trackingStatus', 'requestTracking']);
    });

    test('there is nothing to ask where there is no bridge', () async {
      _Native.remove();
      const permission = AppleTrackingPermission();
      expect(await permission.status(), TrackingStatus.notSupported);
      expect(await permission.request(), TrackingStatus.notSupported);
    });

    test('a failing bridge counts as nothing to ask', () async {
      native.failOn = 'trackingStatus';
      expect(await const AppleTrackingPermission().status(),
          TrackingStatus.notSupported);
    });
  });
}
