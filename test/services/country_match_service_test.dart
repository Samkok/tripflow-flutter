import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/services/country_match_service.dart';

void main() {
  const paris = LatLng(48.8566, 2.3522);
  const parisNearby = LatLng(48.87, 2.36); // ~1.7 km from paris
  const lyon = LatLng(45.7640, 4.8357);
  const geneva = LatLng(46.2044, 6.1432);

  /// A geocoder answering from a table and counting its calls; a point
  /// missing from the table makes the lookup throw (network failure).
  ({CountryMatchService svc, List<LatLng> calls}) build(
      Map<LatLng, String?> table) {
    final calls = <LatLng>[];
    final svc = CountryMatchService(geocodeCountry: (at) async {
      calls.add(at);
      if (!table.containsKey(at)) throw StateError('no answer for $at');
      return table[at];
    });
    return (svc: svc, calls: calls);
  }

  test('same country → true, different country → false', () async {
    final t = build({paris: 'fr', lyon: 'FR', geneva: 'CH'});
    expect(await t.svc.verdict(device: paris, place: lyon, placeKey: 'lyon'),
        isTrue);
    expect(
        await t.svc.verdict(device: paris, place: geneva, placeKey: 'geneva'),
        isFalse);
  });

  test('a place on a country-tagged trip needs no place lookup', () async {
    final t = build({paris: 'FR'});
    final v = await t.svc.verdict(
        device: paris, place: geneva, placeKey: 'g', knownPlaceCountry: 'ch');
    expect(v, isFalse);
    expect(t.calls, [paris]); // only the device was geocoded
  });

  test('device country is reused within 5 km and refreshed beyond', () async {
    final t = build({paris: 'FR', parisNearby: 'FR', lyon: 'FR'});
    Future<bool?> ask(LatLng device) => t.svc.verdict(
        device: device, place: lyon, placeKey: 'lyon', knownPlaceCountry: 'FR');
    await ask(paris);
    await ask(parisNearby);
    expect(t.calls, [paris]);
    await ask(lyon);
    expect(t.calls, [paris, lyon]);
  });

  test('a place lookup is remembered per place key', () async {
    final t = build({paris: 'FR', lyon: 'FR'});
    await t.svc.verdict(device: paris, place: lyon, placeKey: 'lyon');
    await t.svc.verdict(device: paris, place: lyon, placeKey: 'lyon');
    expect(t.calls.where((c) => c == lyon).length, 1);
  });

  test('a failed lookup is unknown, not a mismatch, and is retried', () async {
    final t = build({paris: 'FR'}); // geneva missing → the geocoder throws
    expect(await t.svc.verdict(device: paris, place: geneva, placeKey: 'g'),
        isNull);
    expect(await t.svc.verdict(device: paris, place: geneva, placeKey: 'g'),
        isNull);
    expect(t.calls.where((c) => c == geneva).length, 2);
  });

  test('a geocoder that cannot name the country is unknown too', () async {
    final t = build({paris: null, lyon: 'FR'});
    expect(await t.svc.verdict(device: paris, place: lyon, placeKey: 'lyon'),
        isNull);
  });

  test('cachedVerdict answers only from memory', () async {
    final t = build({paris: 'FR'});
    expect(
        t.svc.cachedVerdict(
            device: paris, placeKey: 'x', knownPlaceCountry: 'FR'),
        isNull);
    await t.svc.verdict(
        device: paris, place: lyon, placeKey: 'x', knownPlaceCountry: 'FR');
    expect(
        t.svc.cachedVerdict(
            device: paris, placeKey: 'x', knownPlaceCountry: 'FR'),
        isTrue);
    expect(
        t.svc.cachedVerdict(
            device: paris, placeKey: 'x', knownPlaceCountry: 'CH'),
        isFalse);
    expect(t.svc.cachedVerdict(device: paris, placeKey: 'never-looked-up'),
        isNull);
  });
}
