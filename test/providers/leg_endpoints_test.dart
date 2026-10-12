import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/optimized_map_overlay_provider.dart';

LocationModel _stop(String id, double lat) => LocationModel(
      id: id,
      name: 'Stop $id',
      address: '',
      coordinates: LatLng(lat, 100.0),
      addedAt: DateTime(2026),
    );

void main() {
  final stops = [_stop('a', 1.0), _stop('b', 2.0), _stop('c', 3.0)];
  List<List<LatLng>> polylines(int legs) => [
        for (var i = 0; i < legs; i++)
          [LatLng(i.toDouble(), 100.0), LatLng(i + 1.0, 100.0)],
      ];
  List<Map<String, dynamic>> details(int legs) => [
        for (var i = 0; i < legs; i++)
          {
            'distance': 1000.0 * (i + 1),
            'duration': Duration(minutes: 10 * (i + 1)),
            'mode': 'walk'
          },
      ];

  group('legEndpointsFor', () {
    test('a day starting at a saved place: leg i runs stop i → i+1', () {
      final ends = legEndpointsFor(
        legDetails: details(2),
        legPolylines: polylines(2),
        ordered: stops,
        startLocationId: 'a',
        legIndex: 1,
      );
      expect(ends!.from.id, 'b');
      expect(ends.to.id, 'c');
    });

    test('a day starting at the device: leg 0 ends at the first stop', () {
      final ends = legEndpointsFor(
        legDetails: details(3),
        legPolylines: polylines(3),
        ordered: stops,
        startLocationId: 'current_location',
        legIndex: 0,
      );
      expect(ends!.from.id, 'leg_anchor', reason: 'the device, not a stop');
      expect(ends.to.id, 'a');
      final last = legEndpointsFor(
        legDetails: details(3),
        legPolylines: polylines(3),
        ordered: stops,
        startLocationId: 'current_location',
        legIndex: 2,
      );
      expect(last!.from.id, 'b');
      expect(last.to.id, 'c');
    });

    test('out of range: null', () {
      expect(
        legEndpointsFor(
          legDetails: details(2),
          legPolylines: polylines(2),
          ordered: stops,
          startLocationId: 'a',
          legIndex: 2,
        ),
        isNull,
      );
      expect(
        legEndpointsFor(
          legDetails: details(2),
          legPolylines: polylines(2),
          ordered: stops,
          startLocationId: 'a',
          legIndex: -1,
        ),
        isNull,
      );
    });

    test('the loop-home leg resolves its stops by id', () {
      final ends = legEndpointsFor(
        legDetails: [
          ...details(2),
          {
            'distance': 500.0,
            'duration': const Duration(minutes: 5),
            'mode': 'walk',
            'fromId': 'c',
            'toId': 'a'
          },
        ],
        legPolylines: polylines(3),
        ordered: stops,
        startLocationId: 'a',
        legIndex: 2,
      );
      expect(ends!.from.id, 'c');
      expect(ends.to.id, 'a');
    });
  });

  group('routeLegSheetRequestFor', () {
    test('labels and mode come from the leg', () {
      final req = routeLegSheetRequestFor(
        legDetails: details(2),
        legPolylines: polylines(2),
        ordered: stops,
        startLocationId: 'a',
        legIndex: 1,
      );
      expect(req!.origin.id, 'b');
      expect(req.destination.id, 'c');
      expect(req.distanceLabel, '2.0 km');
      expect(req.durationLabel, '20 min');
      expect(req.mode, 'walk');
      expect(req.legIndex, 1);
    });
  });
}
