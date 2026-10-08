import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/services/measurement_consent_service.dart';
import 'package:voyza/utils/ads_event_map.dart';
import 'package:voyza/utils/measurement_decision.dart';
import 'package:voyza/utils/measurement_region.dart';

typedef _Applied = ({bool analytics, bool ads});

class _Applier implements MeasurementApplier {
  final calls = <_Applied>[];
  bool fail = false;

  @override
  Future<void> apply({required bool analytics, required bool ads}) async {
    calls.add((analytics: analytics, ads: ads));
    if (fail) throw StateError('firebase not ready');
  }
}

class _Sink implements AdsMeasurementSink {
  final enabled = <bool>[];
  final tracking = <bool>[];
  final events = <AdsEvent>[];
  bool failOnLog = false;

  @override
  Future<void> setEnabled(bool on) async => enabled.add(on);

  @override
  Future<void> setTrackingAllowed(bool allowed) async => tracking.add(allowed);

  @override
  void log(AdsEvent event) {
    if (failOnLog) throw StateError('sdk exploded');
    events.add(event);
  }
}

/// One phone: its region setting, what the server says about its
/// connection, and what it has stored. [boot] is an app launch.
class _Phone {
  _Phone({this.device, this.connection, this.regionSetting});

  String? device;
  String? connection;

  /// The platform's own region setting, where it has one (an iPhone).
  String? regionSetting;
  bool regionSettingBroken = false;
  bool serverDown = false;
  int lookups = 0;
  final applier = _Applier();
  final sink = _Sink();

  Future<MeasurementConsentService> boot({bool settle = true}) async {
    final service = MeasurementConsentService(
      applier: applier,
      deviceCountry: () => device,
      lookupDeviceRegion: () async {
        if (regionSettingBroken) throw StateError('no bridge');
        return regionSetting;
      },
      lookupCountry: () async {
        lookups++;
        if (serverDown) throw StateError('offline');
        return connection;
      },
    )..addSink(sink);
    await service.applyAtStartup();
    if (settle) await service.whenRegionSettled();
    return service;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('consent region', () {
    test('nothing runs before the answer, and the answer is remembered',
        () async {
      final phone = _Phone(device: 'DE', connection: 'DE');
      final service = await phone.boot();

      var d = service.decision.value!;
      expect(d.region, MeasurementRegion.consentRequired);
      expect(d.analytics, isFalse);
      expect(d.ads, isFalse);
      expect(d.ask, MeasurementAsk.consent);
      expect(phone.applier.calls, [(analytics: false, ads: false)]);

      d = await service.recordConsent(analytics: true, ads: false);
      expect(d.analytics, isTrue);
      expect(d.ads, isFalse);
      expect(d.ask, MeasurementAsk.nothing);
      expect(phone.applier.calls.last, (analytics: true, ads: false));

      // Next launch: same answer, not asked again.
      final again = (await phone.boot()).decision.value!;
      expect(again.analytics, isTrue);
      expect(again.ads, isFalse);
      expect(again.ask, MeasurementAsk.nothing);
    });

    test('a US phone in France is asked, once the server has said France',
        () async {
      final phone = _Phone(device: 'US', connection: 'FR');
      final service = await phone.boot(settle: false);
      // Before the lookup returns we cannot tell: nothing runs, nothing asked.
      expect(service.decision.value!.region, MeasurementRegion.unknown);
      expect(service.decision.value!.ask, MeasurementAsk.nothing);
      expect(service.adsAllowed, isFalse);

      final settled = await service.whenRegionSettled();
      expect(settled.region, MeasurementRegion.consentRequired);
      expect(settled.ask, MeasurementAsk.consent);
      expect(settled.analytics, isFalse);
    });

    test('an iPhone set to France is asked, though its language says Cambodia',
        () async {
      final phone = _Phone(device: 'KH', regionSetting: 'FR', connection: 'KH');
      final service = await phone.boot();
      final d = service.decision.value!;
      expect(d.region, MeasurementRegion.consentRequired);
      expect(d.analytics, isFalse);
      expect(d.ads, isFalse);
      expect(d.ask, MeasurementAsk.consent);
      expect(phone.sink.enabled, everyElement(isFalse));
    });

    test('the Region setting is enough even before the server has answered',
        () async {
      final phone = _Phone(device: 'KH', regionSetting: 'DE')
        ..serverDown = true;
      final service = await phone.boot();
      expect(service.decision.value!.region, MeasurementRegion.consentRequired);
      expect(service.decision.value!.ask, MeasurementAsk.consent);
    });

    test('a platform that cannot say leaves the other signals to decide',
        () async {
      final phone = _Phone(device: 'KH', connection: 'KH')
        ..regionSettingBroken = true;
      final service = await phone.boot();
      expect(service.decision.value!.region, MeasurementRegion.open);
      expect(service.decision.value!.ask, MeasurementAsk.notice);
    });

    test('a refusal sticks', () async {
      final phone = _Phone(device: 'IE', connection: 'IE');
      final service = await phone.boot();
      await service.recordConsent(analytics: false, ads: false);
      final again = (await phone.boot()).decision.value!;
      expect(again.ask, MeasurementAsk.nothing);
      expect(again.analytics, isFalse);
      expect(again.ads, isFalse);
    });
  });

  group('elsewhere', () {
    test('analytics on, ads measurement only after the notice', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      final service = await phone.boot();

      var d = service.decision.value!;
      expect(d.region, MeasurementRegion.open);
      expect(d.analytics, isTrue);
      expect(d.ads, isFalse);
      expect(d.ask, MeasurementAsk.notice);
      expect(phone.sink.enabled.last, isFalse);

      d = await service.acknowledgeNotice(keepOn: true);
      expect(d.ads, isTrue);
      expect(d.ask, MeasurementAsk.nothing);
      expect(phone.sink.enabled.last, isTrue);

      final again = (await phone.boot()).decision.value!;
      expect(again.ads, isTrue);
      expect(again.ask, MeasurementAsk.nothing);
    });

    test('"Turn off" on the notice is a choice, and it sticks', () async {
      final phone = _Phone(device: 'KH', connection: 'KH');
      final service = await phone.boot();
      final d = await service.acknowledgeNotice(keepOn: false);
      expect(d.ads, isFalse);
      expect(d.analytics, isTrue);
      expect(service.choices.ads, isFalse);

      final again = (await phone.boot()).decision.value!;
      expect(again.ads, isFalse);
      expect(again.ask, MeasurementAsk.nothing);
      expect(phone.sink.enabled, everyElement(isFalse));
    });

    test('the last known country is used at once on the next launch', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      await (await phone.boot()).acknowledgeNotice(keepOn: true);

      phone.serverDown = true;
      final service = await phone.boot(settle: false);
      expect(service.decision.value!.region, MeasurementRegion.open);
      expect(service.decision.value!.analytics, isTrue);
      expect(phone.applier.calls.last.analytics, isTrue);
    });

    test('ads measurement waits for this launch\'s country check', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      await (await phone.boot()).acknowledgeNotice(keepOn: true);
      phone.sink.enabled.clear();

      final service = await phone.boot(settle: false);
      // "On by default" still rests on last launch's country.
      expect(service.adsAllowed, isFalse);
      expect(phone.sink.enabled, everyElement(isFalse));
      expect(phone.applier.calls.last, (analytics: true, ads: false));

      await service.whenRegionSettled();
      expect(service.adsAllowed, isTrue);
      expect(phone.sink.enabled.last, isTrue);
      expect(phone.applier.calls.last, (analytics: true, ads: true));
    });

    test('if the server cannot be reached, the last known country stands',
        () async {
      final phone = _Phone(device: 'US', connection: 'US');
      await (await phone.boot()).acknowledgeNotice(keepOn: true);

      phone.serverDown = true;
      final service = await phone.boot();
      expect(service.adsAllowed, isTrue);
      expect(phone.sink.enabled.last, isTrue);
    });

    test('a yes the person gave themselves needs no waiting', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      await (await phone.boot()).setAds(true);
      phone.sink.enabled.clear();

      final service = await phone.boot(settle: false);
      expect(service.adsAllowed, isTrue);
      expect(phone.sink.enabled, [true]);
    });
  });

  group('when we cannot tell', () {
    test('a failed lookup leaves everything off and asks nothing', () async {
      final phone = _Phone(device: 'US')..serverDown = true;
      final service = await phone.boot();
      final d = service.decision.value!;
      expect(d.region, MeasurementRegion.unknown);
      expect(d.analytics, isFalse);
      expect(d.ads, isFalse);
      expect(d.ask, MeasurementAsk.nothing);
      expect(phone.applier.calls, [(analytics: false, ads: false)]);
    });

    test('an answer that is not a country is no answer', () async {
      for (final junk in ['XX', 'T1', '', 'unknown']) {
        SharedPreferences.setMockInitialValues({});
        final service = await _Phone(device: 'US', connection: junk).boot();
        expect(service.decision.value!.region, MeasurementRegion.unknown,
            reason: junk);
      }
    });

    test('it is settled on a later launch', () async {
      final phone = _Phone(device: 'US')..serverDown = true;
      await phone.boot();
      phone
        ..serverDown = false
        ..connection = 'US';
      final d = (await phone.boot()).decision.value!;
      expect(d.region, MeasurementRegion.open);
      expect(d.ask, MeasurementAsk.notice);
    });
  });

  group('travelling', () {
    test('default-on abroad becomes ask-first on arrival in Europe', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      await (await phone.boot()).acknowledgeNotice(keepOn: true);

      phone.connection = 'FR';
      phone.sink.enabled.clear();
      final service = await phone.boot(settle: false);
      // The last known country says "on by default", but the ad SDK is not
      // started on that alone…
      expect(service.decision.value!.region, MeasurementRegion.open);
      expect(service.adsAllowed, isFalse);
      // …and then the server says France: off, and ask.
      final d = await service.whenRegionSettled();
      expect(d.region, MeasurementRegion.consentRequired);
      expect(d.analytics, isFalse);
      expect(d.ads, isFalse);
      expect(d.ask, MeasurementAsk.consent);
      expect(phone.applier.calls.last, (analytics: false, ads: false));
      // The ad SDK never ran in France.
      expect(phone.sink.enabled, everyElement(isFalse));
    });

    test('a yes given at home still holds in Europe', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      await (await phone.boot()).setAds(true);

      phone.connection = 'FR';
      final service = await phone.boot();
      expect(service.decision.value!.region, MeasurementRegion.consentRequired);
      expect(service.adsAllowed, isTrue, reason: 'they said yes themselves');
    });

    test('an answer given in Europe goes home with the person', () async {
      final phone = _Phone(device: 'US', connection: 'FR');
      final service = await phone.boot();
      await service.recordConsent(analytics: true, ads: false);

      phone.connection = 'US';
      final home = (await phone.boot()).decision.value!;
      expect(home.region, MeasurementRegion.open);
      expect(home.analytics, isTrue);
      expect(home.ads, isFalse, reason: 'they said no');
      expect(home.ask, MeasurementAsk.nothing);
    });
  });

  group('the old single switch', () {
    test('a no carries over to both purposes and is not asked again', () async {
      SharedPreferences.setMockInitialValues(
          {MeasurementConsentService.legacyKey: 'denied'});
      for (final country in ['DE', 'US']) {
        final d = (await _Phone(device: country, connection: country).boot())
            .decision
            .value!;
        expect(d.analytics, isFalse, reason: country);
        expect(d.ads, isFalse, reason: country);
        expect(d.ask, MeasurementAsk.nothing, reason: country);
      }
    });

    test('a yes in Europe keeps analytics on and asks about ads afresh',
        () async {
      SharedPreferences.setMockInitialValues(
          {MeasurementConsentService.legacyKey: 'granted'});
      final service = await _Phone(device: 'NL', connection: 'NL').boot();
      final d = service.decision.value!;
      expect(d.analytics, isTrue, reason: 'that consent still stands');
      expect(d.ads, isFalse, reason: 'it never covered an ad network');
      expect(d.ask, MeasurementAsk.consent);
      expect(service.choices.analytics, isTrue);
      expect(service.choices.ads, isNull);
    });

    test('a yes elsewhere keeps analytics on and gets the notice', () async {
      SharedPreferences.setMockInitialValues(
          {MeasurementConsentService.legacyKey: 'granted'});
      final d =
          (await _Phone(device: 'US', connection: 'US').boot()).decision.value!;
      expect(d.analytics, isTrue);
      expect(d.ads, isFalse);
      expect(d.ask, MeasurementAsk.notice);
    });

    test('is carried over once, not on every launch', () async {
      SharedPreferences.setMockInitialValues(
          {MeasurementConsentService.legacyKey: 'denied'});
      final phone = _Phone(device: 'US', connection: 'US');
      final service = await phone.boot();
      await service.setAnalytics(true);
      await service.setAds(true);

      final again = (await phone.boot()).decision.value!;
      expect(again.analytics, isTrue);
      expect(again.ads, isTrue);
    });
  });

  group('the Settings switches', () {
    test('withdrawing stops the ad SDK at once and stays off', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      final service = await phone.boot();
      await service.acknowledgeNotice(keepOn: true);
      expect(phone.sink.enabled.last, isTrue);

      await service.setAds(false);
      expect(service.adsAllowed, isFalse);
      expect(phone.sink.enabled.last, isFalse);
      expect(phone.applier.calls.last, (analytics: true, ads: false));

      expect((await phone.boot()).adsAllowed, isFalse);
    });

    test('each purpose moves on its own', () async {
      final phone = _Phone(device: 'DE', connection: 'DE');
      final service = await phone.boot();
      await service.setAds(true);
      expect(service.decision.value!.ads, isTrue);
      expect(service.decision.value!.analytics, isFalse);
      // The other purpose was never answered, so it is still to be asked.
      expect(service.decision.value!.ask, MeasurementAsk.consent);

      await service.setAnalytics(false);
      expect(service.decision.value!.ask, MeasurementAsk.nothing);
    });
  });

  group('events for the ad SDK', () {
    test('flow only while ads measurement is on', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      final service = await phone.boot();

      service.logAdsEvent('trip_created');
      expect(phone.sink.events, isEmpty, reason: 'before the notice');

      await service.acknowledgeNotice(keepOn: true);
      service.logAdsEvent('trip_created');
      service.logAdsEvent('signup', {'method': 'email'});
      // Purchases are RevenueCat's to report, so the app's own copy is
      // dropped even with ads measurement on.
      service.logAdsEvent('purchase',
          {'product': 'premium.yearly', 'value': 29.99, 'currency': 'USD'});
      expect(phone.sink.events.map((e) => e.name),
          ['TripCreated', 'fb_mobile_complete_registration']);

      await service.setAds(false);
      service.logAdsEvent('trip_created');
      expect(phone.sink.events, hasLength(2), reason: 'after withdrawal');
    });

    test('only the listed events get through', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      final service = await phone.boot();
      await service.acknowledgeNotice(keepOn: true);
      service.logAdsEvent('place_added', {'total_places': 9});
      service.logAdsEvent('paywall_viewed', {'source': 'place_limit'});
      expect(phone.sink.events, isEmpty);
    });

    test('an optimized route goes on as a once-only milestone, bare', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      final service = await phone.boot();

      service.logAdsEvent('route_optimized', {'stops': 5, 'minutes_saved': 12});
      expect(phone.sink.events, isEmpty, reason: 'before the notice');

      await service.acknowledgeNotice(keepOn: true);
      service.logAdsEvent('route_optimized', {'stops': 5, 'minutes_saved': 12});
      final event = phone.sink.events.single;
      expect(event.name, 'RouteOptimized');
      expect(event.parameters, isEmpty);
      // The SDK's side keeps count: see MetaAdsSink.
      expect(event.oncePerInstall, isTrue);
    });

    test('a failing SDK never reaches the caller', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      final service = await phone.boot();
      await service.acknowledgeNotice(keepOn: true);
      phone.sink.failOnLog = true;
      expect(() => service.logAdsEvent('signup', {'method': 'email'}),
          returnsNormally);
    });

    test('nothing flows before the choices have loaded', () {
      final service = MeasurementConsentService(
        applier: _Applier(),
        deviceCountry: () => 'US',
        lookupCountry: () async => 'US',
      );
      final sink = _Sink();
      service.addSink(sink);
      service.logAdsEvent('trip_created');
      expect(sink.events, isEmpty);
      expect(service.adsAllowed, isFalse);
    });

    test('the tracking answer is passed on', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      final service = await phone.boot();
      await service.reportTrackingAllowed(true);
      await service.reportTrackingAllowed(false);
      expect(phone.sink.tracking, [true, false]);
    });

    test('an SDK added later is put in the current state', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      final service = await phone.boot();
      await service.acknowledgeNotice(keepOn: true);
      final late = _Sink();
      service.addSink(late);
      await Future<void>.delayed(Duration.zero);
      expect(late.enabled, [true]);
    });
  });

  group('robustness', () {
    test('the SDKs are told only when something changed', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      final service = await phone.boot();
      final before = phone.applier.calls.length;
      await service.refreshRegion();
      await service.refreshRegion();
      expect(phone.applier.calls, hasLength(before));
    });

    test('a failing applier does not lose the decision', () async {
      final phone = _Phone(device: 'DE', connection: 'DE');
      phone.applier.fail = true;
      final service = await phone.boot();
      expect(service.decision.value!.ask, MeasurementAsk.consent);
      final d = await service.recordConsent(analytics: true, ads: true);
      expect(d.analytics, isTrue);
      expect(d.ads, isTrue);
    });

    test('the server is asked once per launch', () async {
      final phone = _Phone(device: 'US', connection: 'US');
      final service = await phone.boot();
      await service.current();
      await service.whenRegionSettled();
      expect(phone.lookups, 1);
    });
  });
}
