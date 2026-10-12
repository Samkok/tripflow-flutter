import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/utils/routing_place_id.dart';

LocationModel _place({String? placeId, List<String>? types}) => LocationModel(
      id: 'p',
      name: 'Somewhere',
      address: '',
      coordinates: const LatLng(35.68, 139.76),
      placeId: placeId,
      placeTypes: types,
      addedAt: DateTime(2026),
    );

void main() {
  group('routingPlaceId', () {
    test('a place without an id routes by coordinates', () {
      expect(routingPlaceId(_place()), isNull);
      expect(routingPlaceId(_place(placeId: '')), isNull);
    });

    test('a destination type keeps its id', () {
      expect(
        routingPlaceId(_place(
            placeId: 'ChIJ1', types: ['restaurant', 'point_of_interest'])),
        'ChIJ1',
      );
      expect(routingPlaceId(_place(placeId: 'ChIJ2', types: ['premise'])),
          'ChIJ2');
      expect(
          routingPlaceId(_place(placeId: 'ChIJ3', types: ['street_address'])),
          'ChIJ3');
    });

    test('a road or an area routes by coordinates', () {
      expect(
          routingPlaceId(_place(placeId: 'ChIJ4', types: ['route'])), isNull);
      expect(
          routingPlaceId(
              _place(placeId: 'ChIJ5', types: ['locality', 'political'])),
          isNull);
      expect(routingPlaceId(_place(placeId: 'ChIJ6', types: ['plus_code'])),
          isNull);
    });

    test('a destination inside an area is still a destination', () {
      // Places details list the establishment alongside its area types.
      expect(
        routingPlaceId(_place(
            placeId: 'ChIJ7',
            types: ['natural_feature', 'establishment', 'point_of_interest'])),
        'ChIJ7',
      );
    });

    test('unknown types (older saved places) keep the id', () {
      expect(routingPlaceId(_place(placeId: 'ChIJ8')), 'ChIJ8');
      expect(
          routingPlaceId(_place(placeId: 'ChIJ9', types: ['food'])), 'ChIJ9');
    });
  });
}
