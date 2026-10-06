import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/repositories/location_repository.dart';
import 'package:voyza/services/multi_modal_router.dart';

/// The route's headline time ("17 stops · 52.5 km · 10h 10m", and the ETA
/// derived from it) is travel PLUS the stay at every stop but the last. It
/// must mean the same thing whichever action last wrote it.
///
/// The bug this pins down: switching one leg to another travel mode summed
/// the legs alone, so a 17-stop day read 10h 10m after optimizing and 2h 18m
/// after changing a single 10-minute leg to an 18-minute one.

class _NoopLocations extends Fake implements LocationRepository {
  @override
  Future<void> updateLocation(String id, Map<String, dynamic> updates) async {}
}

const _min = Duration(minutes: 1);
final _day = DateTime(2026, 10, 10);

LocationModel _stop(String id, {int stayMin = 30, DateTime? on}) =>
    LocationModel(
      id: id,
      name: id,
      address: '',
      coordinates: const LatLng(22.28, 114.18),
      addedAt: DateTime(2026, 10, 1),
      scheduledDate: on ?? _day,
      stayDuration: _min * stayMin,
      tripId: 'trip-1',
    );

Map<String, dynamic> _leg(String from, String to, int minutes, double metres) =>
    {
      'duration': _min * minutes,
      'distance': metres,
      'mode': 'drive',
      'fromId': from,
      'toId': to,
    };

const _line = [LatLng(22.28, 114.18), LatLng(22.29, 114.16)];

LegRoute _route(int minutes, double metres, String mode) => LegRoute(
      points: _line,
      duration: _min * minutes,
      distance: metres,
      mode: mode,
    );

/// The real notifier, seeded with a route. The two streams it listens to are
/// silenced so the state a test seeds is the state it reads back.
class _Trip {
  _Trip(TripState seed) {
    SharedPreferences.setMockInitialValues({});
    addTearDown(_container.dispose);
    // ignore: invalid_use_of_protected_member
    notifier.state = seed;
  }

  final _container = ProviderContainer(overrides: [
    realtimeActiveTripProvider.overrideWith((ref) => Stream.value(null)),
    filteredLocationsForMapProvider.overrideWith((ref) => const Stream.empty()),
    locationRepositoryProvider.overrideWithValue(_NoopLocations()),
  ]);

  TripNotifier get notifier => _container.read(tripProvider.notifier);
  TripState get state => _container.read(tripProvider);
  Duration get total => state.totalTravelTime;
}

/// A day as the optimizer leaves it: hotel, then three stops.
/// Travel 10 + 12 + 20 = 42 min; stays (all but the last stop)
/// 30 + 30 + 45 = 105 min; total 2h 27m.
TripState _optimizedDay({List<LocationModel> otherDays = const []}) {
  final stops = [
    _stop('hotel'),
    _stop('market'),
    _stop('museum', stayMin: 45),
    _stop('peak'),
  ];
  return TripState(
    pinnedLocations: [...stops, ...otherDays],
    optimizedLocationsForSelectedDate: stops,
    optimizedRoute: const [..._line, ..._line, ..._line],
    legPolylines: const [_line, _line, _line],
    legDetails: [
      _leg('hotel', 'market', 10, 3600),
      _leg('market', 'museum', 12, 900),
      _leg('museum', 'peak', 20, 5200),
    ],
    totalTravelTime: _min * 147,
    totalDistance: 9700,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('changing one leg', () {
    test('moves the total by that leg alone and keeps every stay', () async {
      final trip = _Trip(_optimizedDay());

      // Drive (10 min, 3.6 km) becomes transit (18 min, 3.7 km).
      final applied =
          await trip.notifier.applyLegRoute(0, _route(18, 3700, 'transit'));

      expect(applied, isTrue);
      expect(trip.total, _min * (147 + 8),
          reason: 'travel 50 + stays 105, not the 50 minutes of legs alone');
      expect(trip.state.totalDistance, 9800);
      expect(trip.state.legDetails.first['mode'], 'transit');
    });

    test('then picking another route for it adjusts from there', () async {
      final trip = _Trip(_optimizedDay());

      await trip.notifier.applyLegRoute(0, _route(18, 3700, 'transit'));
      // The route-options picker goes through the same patch.
      await trip.notifier.applyLegRoute(0, _route(17, 3700, 'transit'));

      expect(trip.total, _min * (147 + 7));
    });

    test('uses each stop\'s own stay, not a flat default', () async {
      final trip = _Trip(_optimizedDay());

      // No change in duration: the total must come back exactly as the
      // optimizer computed it, the 45-minute museum stay included.
      await trip.notifier.applyLegRoute(2, _route(20, 5200, 'transit'));

      expect(trip.total, _min * 147);
    });

    test('rejects a leg that does not exist and leaves the total alone',
        () async {
      final trip = _Trip(_optimizedDay());

      final applied =
          await trip.notifier.applyLegRoute(7, _route(5, 400, 'walk'));

      expect(applied, isFalse);
      expect(trip.total, _min * 147);
    });
  });

  test('a point-to-point preview stays travel-only when its leg changes',
      () async {
    final pair = [_stop('market'), _stop('museum', stayMin: 45)];
    final trip = _Trip(TripState(
      pinnedLocations: pair,
      optimizedLocationsForSelectedDate: pair,
      isRoutePreview: true,
      optimizedRoute: _line,
      legPolylines: const [_line],
      legDetails: [_leg('market', 'museum', 12, 900)],
      totalTravelTime: _min * 12,
      totalDistance: 900,
    ));

    await trip.notifier.applyLegRoute(0, _route(16, 950, 'transit'));

    expect(trip.total, _min * 16,
        reason: '"how long to get there" never includes a stay');
  });

  group('changing a stay', () {
    test('counts the stops on the route, not every place in the trip',
        () async {
      // A multi-day trip: three more places on the next day.
      final nextDay = DateTime(2026, 10, 11);
      final trip = _Trip(_optimizedDay(otherDays: [
        _stop('temple', on: nextDay),
        _stop('harbour', on: nextDay),
        _stop('night-market', on: nextDay),
      ]));

      await trip.notifier.updateLocationStayDuration('market', _min * 90);

      // 30 -> 90 minutes at one stop of this day: +60, nothing from day two.
      expect(trip.total, _min * (147 + 60));
    });

    test('at the last stop does not change the total', () async {
      final trip = _Trip(_optimizedDay());

      await trip.notifier.updateLocationStayDuration('peak', _min * 120);

      expect(trip.total, _min * 147);
    });
  });
}
