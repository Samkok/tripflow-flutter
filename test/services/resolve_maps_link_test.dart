import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/services/places_gateway.dart';
import 'package:voyza/services/places_service.dart';

/// Answers the two geocoding primitives and records which one was asked;
/// the link decoding under test is the base class's.
class _Gateway extends PlacesGateway {
  final calls = <String>[];

  @override
  Future<PlaceDetails?> fromCoordinates(LatLng c) async {
    calls.add('coords:${c.latitude},${c.longitude}');
    return PlaceDetails(name: 'By coordinates', address: '', coordinates: c);
  }

  @override
  Future<PlaceDetails?> fromAddress(String address) async {
    calls.add('address:$address');
    return PlaceDetails(
        name: 'By address', address: address, coordinates: const LatLng(0, 0));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('coordinates in the link are reverse-geocoded', () async {
    final g = _Gateway();
    final place = await g.fromMapsLink(
        'https://www.google.com/maps/place/Tokyo+Tower/@35.6586,139.7454,17z');
    expect(place?.name, 'By coordinates');
    expect(g.calls, ['coords:35.6586,139.7454']);
  });

  test('without coordinates the q= query is geocoded', () async {
    final g = _Gateway();
    final place =
        await g.fromMapsLink('https://www.google.com/maps?q=Tokyo+Tower');
    expect(place?.name, 'By address');
    expect(g.calls, ['address:Tokyo Tower']);
  });

  test('a Maps link that names nothing resolves to null', () async {
    final g = _Gateway();
    expect(await g.fromMapsLink('https://www.google.com/maps'), isNull);
    expect(g.calls, isEmpty);
  });

  test('text that is not a Maps link is refused', () async {
    final g = _Gateway();
    expect(() => g.fromMapsLink('see you at the tower'),
        throwsA(isA<InvalidMapsLink>()));
  });
}
