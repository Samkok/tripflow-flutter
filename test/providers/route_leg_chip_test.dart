import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/optimized_map_overlay_provider.dart';
import 'package:voyza/providers/trip_provider.dart';

class _FakeTripNotifier extends StateNotifier<TripState>
    implements TripNotifier {
  _FakeTripNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LocationModel _stop(String id, double lat, double lng) => LocationModel(
      id: id,
      name: 'Stop $id',
      address: '',
      coordinates: LatLng(lat, lng),
      addedAt: DateTime(2026),
    );

/// A transit leg as the router records it: walk → tram ride → walk, with
/// the ride card (`transit`) and the run geometry (`transitSteps`).
TripState _transitDay({String? lineShort, String? lineColor}) {
  final a = _stop('a', 22.2790, 114.1650);
  final b = _stop('b', 22.2770, 114.1730);
  final walk1 = [a.coordinates, const LatLng(22.2792, 114.1660)];
  final ride = [
    const LatLng(22.2792, 114.1660),
    const LatLng(22.2785, 114.1690),
    const LatLng(22.2780, 114.1710),
    const LatLng(22.2775, 114.1720),
  ];
  final walk2 = [const LatLng(22.2775, 114.1720), b.coordinates];
  final whole = [...walk1, ...ride, ...walk2];
  return TripState(
    optimizedLocationsForSelectedDate: [a, b],
    startLocationId: 'a',
    optimizedRoute: whole,
    legPolylines: [whole],
    legDetails: [
      {
        'mode': 'transit',
        'distance': 1200.0,
        'duration': const Duration(minutes: 14),
        'fromId': 'a',
        'toId': 'b',
        'transit': [
          {
            'lineShort': lineShort ?? '',
            'lineName': 'Tram',
            'lineColor': lineColor,
            'lineTextColor': null,
            'vehicleType': 'TRAM',
            'headsign': 'Shau Kei Wan',
            'stopCount': 3,
            'boardStop': 'Admiralty Station',
            'alightStop': 'Wan Chai',
            'departureTime': '2026-10-12T10:00:00Z',
            'arrivalTime': '2026-10-12T10:10:00Z',
          },
        ],
        'transitSteps': [
          {'mode': 'WALK', 'points': walk1, 'durationSeconds': 120},
          {
            'mode': 'TRANSIT',
            'points': ride,
            'durationSeconds': 600,
            if (lineColor != null) 'lineColor': lineColor,
            if (lineShort != null) 'lineShort': lineShort,
            'vehicleType': 'TRAM',
          },
          {'mode': 'WALK', 'points': walk2, 'durationSeconds': 90},
        ],
      },
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Set<Marker>> chipFor(TripState state, String tappedId) async {
    final container = ProviderContainer(overrides: [
      tripProvider.overrideWith((ref) => _FakeTripNotifier(state)),
    ]);
    addTearDown(container.dispose);
    container.read(mapUIStateProvider.notifier).setTappedPolyline(tappedId);
    return container.read(routeInfoMarkersProvider.future);
  }

  group('route leg chip', () {
    test('the whole transit leg has a chip', () async {
      final markers =
          await chipFor(_transitDay(lineColor: '#00A040'), 'leg_0');
      expect(markers.map((m) => m.markerId.value), ['route_leg_chip_leg_0']);
    });

    test('a tapped tram ride run has its own chip', () async {
      final markers = await chipFor(
          _transitDay(lineShort: '', lineColor: '#00A040'), 'leg_0_s1');
      expect(
          markers.map((m) => m.markerId.value), ['route_leg_chip_leg_0_s1']);
      final chip = markers.single;
      // Anchored on the ride itself (its middle point when the map centre
      // is unknown), never on the walk connectors.
      expect(chip.position, const LatLng(22.2780, 114.1710));
    });

    test('a ride with no line colour or number still has a chip', () async {
      final markers = await chipFor(_transitDay(), 'leg_0_s1');
      expect(markers, hasLength(1));
    });

    test('a walk connector run has a chip too', () async {
      final markers =
          await chipFor(_transitDay(lineColor: '#00A040'), 'leg_0_s0');
      expect(
          markers.map((m) => m.markerId.value), ['route_leg_chip_leg_0_s0']);
    });
  });
}
