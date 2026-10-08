import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/ads_event_map.dart';
import 'package:voyza/utils/measurement_decision.dart';
import 'package:voyza/utils/measurement_region.dart';

void main() {
  group('measurementRegionFor', () {
    MeasurementRegion region({String? device, String? connection}) =>
        measurementRegionFor(
            deviceCountry: device, connectionCountry: connection);

    test('either signal pointing at a consent country is enough', () {
      expect(region(device: 'DE', connection: 'DE'),
          MeasurementRegion.consentRequired);
      // A traveller in Paris with a US phone is in France.
      expect(region(device: 'US', connection: 'FR'),
          MeasurementRegion.consentRequired);
      // A German phone on holiday in Thailand is still asked.
      expect(region(device: 'DE', connection: 'TH'),
          MeasurementRegion.consentRequired);
      // The device alone is enough to require consent…
      expect(region(device: 'GB'), MeasurementRegion.consentRequired);
      expect(region(connection: 'CH'), MeasurementRegion.consentRequired);
    });

    test('the device setting alone never clears anyone', () {
      // …but never enough to waive it.
      expect(region(device: 'US'), MeasurementRegion.unknown);
      expect(region(), MeasurementRegion.unknown);
      expect(region(device: 'US', connection: 'XX'), MeasurementRegion.unknown);
      expect(region(device: 'US', connection: 'T1'), MeasurementRegion.unknown);
    });

    test("an iPhone's Region setting counts, whatever the language says", () {
      // Region set to France, language still "English (Cambodia)", and a
      // Cambodian connection: the phone says France, so ask.
      expect(
        measurementRegionFor(
          deviceCountry: 'KH',
          deviceRegion: 'FR',
          connectionCountry: 'KH',
        ),
        MeasurementRegion.consentRequired,
      );
      // The other way round holds too: either device answer is enough.
      expect(
        measurementRegionFor(
          deviceCountry: 'GB',
          deviceRegion: 'US',
          connectionCountry: 'US',
        ),
        MeasurementRegion.consentRequired,
      );
      // Like the language's country, it never clears anyone by itself…
      expect(
        measurementRegionFor(deviceCountry: 'US', deviceRegion: 'US'),
        MeasurementRegion.unknown,
      );
      // …and a region that is not a country is no answer.
      expect(
        measurementRegionFor(
          deviceCountry: 'US',
          deviceRegion: '001',
          connectionCountry: 'US',
        ),
        MeasurementRegion.open,
      );
    });

    test('outside the consent countries, by connection', () {
      expect(region(device: 'US', connection: 'US'), MeasurementRegion.open);
      expect(region(connection: 'KH'), MeasurementRegion.open);
      expect(region(device: 'kh', connection: ' jp '), MeasurementRegion.open);
    });

    test('covers the EEA, the UK, Switzerland and EU territories', () {
      for (final code in [
        'IS',
        'LI',
        'NO',
        'GB',
        'CH',
        'IE',
        'RE',
        'GP',
        'AX'
      ]) {
        expect(region(connection: code), MeasurementRegion.consentRequired,
            reason: code);
      }
      // 27 member states + 3 EEA + UK + CH + 7 territories.
      expect(consentRegionCountries, hasLength(39));
      for (final code in ['US', 'KH', 'JP', 'AU', 'TR', 'RS', 'UA']) {
        expect(region(connection: code), MeasurementRegion.open, reason: code);
      }
    });

    test('normalizeCountryCode accepts only real two-letter codes', () {
      expect(normalizeCountryCode('fr'), 'FR');
      expect(normalizeCountryCode(' De '), 'DE');
      for (final bad in [null, '', 'XX', 'ZZ', 'T1', 'FRA', 'F', '12', 'F R']) {
        expect(normalizeCountryCode(bad), isNull, reason: '$bad');
      }
    });
  });

  group('decideMeasurement', () {
    MeasurementDecision decide(
      MeasurementRegion region, {
      bool? analytics,
      bool? ads,
      bool noticeShown = false,
    }) =>
        decideMeasurement(
          region: region,
          choices: MeasurementChoices(
              analytics: analytics, ads: ads, noticeShown: noticeShown),
        );

    test('consent region: nothing runs until asked, then the answer holds', () {
      final fresh = decide(MeasurementRegion.consentRequired);
      expect(fresh.analytics, isFalse);
      expect(fresh.ads, isFalse);
      expect(fresh.ask, MeasurementAsk.consent);

      final split = decide(MeasurementRegion.consentRequired,
          analytics: true, ads: false);
      expect(split.analytics, isTrue);
      expect(split.ads, isFalse);
      expect(split.ask, MeasurementAsk.nothing);

      // A notice shown elsewhere is not consent here.
      final notice =
          decide(MeasurementRegion.consentRequired, noticeShown: true);
      expect(notice.ads, isFalse);
      expect(notice.ask, MeasurementAsk.consent);
    });

    test('consent region: one purpose still unanswered means asking', () {
      final half = decide(MeasurementRegion.consentRequired, analytics: true);
      expect(half.analytics, isTrue, reason: 'the earlier yes stands');
      expect(half.ads, isFalse);
      expect(half.ask, MeasurementAsk.consent);
    });

    test('elsewhere: analytics on, ads only after the notice', () {
      final fresh = decide(MeasurementRegion.open);
      expect(fresh.analytics, isTrue);
      expect(fresh.ads, isFalse, reason: 'not before the notice');
      expect(fresh.ask, MeasurementAsk.notice);

      final told = decide(MeasurementRegion.open, noticeShown: true);
      expect(told.ads, isTrue);
      expect(told.ask, MeasurementAsk.nothing);

      final off = decide(MeasurementRegion.open, ads: false, noticeShown: true);
      expect(off.ads, isFalse);
      expect(off.analytics, isTrue);
      expect(off.ask, MeasurementAsk.nothing);
    });

    test('unknown region: nothing runs and nothing is asked', () {
      final fresh = decide(MeasurementRegion.unknown, noticeShown: true);
      expect(fresh.analytics, isFalse);
      expect(fresh.ads, isFalse);
      expect(fresh.ask, MeasurementAsk.nothing);
    });

    test('a choice the person made stands wherever they are', () {
      for (final region in MeasurementRegion.values) {
        final yes = decide(region, analytics: true, ads: true);
        expect(yes.analytics, isTrue, reason: region.name);
        expect(yes.ads, isTrue, reason: region.name);
        expect(yes.ask, MeasurementAsk.nothing, reason: region.name);

        final no = decide(region, analytics: false, ads: false);
        expect(no.analytics, isFalse, reason: region.name);
        expect(no.ads, isFalse, reason: region.name);
        expect(no.ask, MeasurementAsk.nothing, reason: region.name);
      }
    });
  });

  group('adsEventFor', () {
    test('sign-up, trip and first route are the whole list', () {
      expect(adsEventFor('signup', {'method': 'email'})!.name,
          'fb_mobile_complete_registration');
      expect(adsEventFor('signup', {'method': 'email'})!.parameters,
          {'fb_registration_method': 'email'});
      expect(adsEventFor('trip_created')!.name, 'TripCreated');
      expect(adsEventFor('trip_created')!.parameters, isEmpty);
      expect(adsEventFor('route_optimized')!.name, 'RouteOptimized');
    });

    test('trials and purchases are left to RevenueCat, not sent twice', () {
      // RevenueCat's server-side integration reports them (it alone sees a
      // trial convert days later); the app sending them as well would
      // count every purchase twice.
      expect(
          adsEventFor('trial_started', {'product': 'premium.yearly'}), isNull);
      expect(
          adsEventFor('purchase',
              {'product': 'premium.monthly', 'value': 4.99, 'currency': 'USD'}),
          isNull);
      expect(
          adsEventFor('purchase',
              {'product': 'premium.lifetime', 'value': 49, 'currency': 'USD'}),
          isNull);
    });

    test('a sink can still tell a purchase from the rest', () {
      const once = AdsEvent(adsEventPurchase, value: 49, currency: 'USD');
      expect(once.isPurchase, isTrue);
      expect(const AdsEvent(adsEventTripCreated).isPurchase, isFalse);
    });

    test('an optimized route is a milestone: told once, with no numbers', () {
      final route =
          adsEventFor('route_optimized', {'stops': 7, 'minutes_saved': 25})!;
      expect(route.name, 'RouteOptimized');
      expect(route.parameters, isEmpty);
      expect(route.value, isNull);
      expect(route.currency, isNull);
      expect(route.oncePerInstall, isTrue);
      expect(adsEventFor('route_optimized')!.oncePerInstall, isTrue);

      // Everything else is told each time it happens.
      for (final other in [
        adsEventFor('signup', {'method': 'email'})!,
        adsEventFor('trip_created')!,
      ]) {
        expect(other.oncePerInstall, isFalse, reason: other.name);
      }
    });

    test('nothing else in the app reaches an advertiser', () {
      for (final name in [
        'place_added',
        'route_card_saved',
        'auto_plan_previewed',
        'paywall_viewed',
        'onboarding_started',
        'onboarding_completed',
        'auto_plan_applied',
        'plan_card_shared',
        'referral_share',
        'route_card_shared',
        'trip_recap_shown',
        'anything_new',
      ]) {
        expect(adsEventFor(name, {'total_places': 12, 'stops': 7}), isNull,
            reason: name);
      }
    });

    test('carries nothing the app knows about a person or a trip', () {
      final event = adsEventFor('signup', {
        'method': 'email',
        'trip_name': 'Honeymoon',
        'email': 'someone@example.com',
      })!;
      expect(event.parameters.keys, ['fb_registration_method']);
      expect(
          adsEventFor('trip_created', {'trip_name': 'Honeymoon'})!.parameters,
          isEmpty);
    });

    test('a copied trip is a created trip, and says no more than that', () {
      final copied = adsEventFor('trip_created', {'source': 'copy'})!;
      expect(copied.name, adsEventTripCreated);
      expect(copied.parameters, isEmpty);
    });

    test('tolerates missing or odd parameters', () {
      expect(adsEventFor('signup')!.parameters, isEmpty);
      expect(adsEventFor('signup', {'method': 7})!.parameters, isEmpty);
      expect(adsEventFor('route_optimized', {'stops': 'many'})!.parameters,
          isEmpty);
    });
  });
}
