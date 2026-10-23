import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/all_days_route_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/unvisited_places_provider.dart';

class _FakeTripNotifier extends StateNotifier<TripState>
    implements TripNotifier {
  _FakeTripNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _d17 = DateTime(2026, 10, 17);
final _d19 = DateTime(2026, 10, 19);

LocationModel _place(String id, DateTime day,
        {bool done = false,
        bool skipped = false,
        bool hotel = false,
        DateTime? end}) =>
    LocationModel(
      id: id,
      name: 'Place $id',
      address: '',
      coordinates: const LatLng(22.3, 114.17),
      addedAt: _d17,
      scheduledDate: day,
      scheduledEndDate: end,
      isDone: done,
      isSkipped: skipped,
      isAccommodation: hotel,
    );

Trip _trip({required bool ended}) => Trip(
      id: 't',
      userId: 'u',
      name: 'Macau',
      startDate: ended ? _d17 : DateTime.now(),
      endDate: ended ? _d19 : DateTime.now().add(const Duration(days: 2)),
      createdAt: _d17,
      updatedAt: _d17,
    );

ProviderContainer _container({required bool ended}) {
  final rows = [
    _place('left', _d19),
    _place('done', _d19, done: true),
    _place('skip', _d19, skipped: true),
    _place('hotel', _d17, end: _d19, hotel: true),
  ];
  final c = ProviderContainer(overrides: [
    tripProvider.overrideWith((ref) => _FakeTripNotifier(TripState(
        pinnedLocations: rows, optimizedLocationsForSelectedDate: const []))),
    selectedDateProvider.overrideWith((ref) => _d19),
    realtimeActiveTripProvider
        .overrideWith((ref) => Stream.value(_trip(ended: ended))),
  ]);
  addTearDown(c.dispose);
  return c;
}

Future<void> _settle(ProviderContainer c) async {
  // Let the active-trip stream deliver its value.
  await c.read(realtimeActiveTripProvider.future);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('while the trip runs, every place stays on its day', () async {
    final c = _container(ended: false);
    await _settle(c);
    expect(c.read(endedTripUnvisitedProvider), isEmpty);
    // The switch means nothing while the trip runs.
    c.read(showUnvisitedOnMapProvider.notifier).state = true;
    expect(c.read(unvisitedPreviewActiveProvider), isFalse);
    expect(
      c.read(locationsForSelectedDateProvider).map((l) => l.id).toSet(),
      {'left', 'done', 'skip', 'hotel'},
    );
  });

  test('once the trip has ended, the leftover leaves its day — list and map',
      () async {
    final c = _container(ended: true);
    await _settle(c);
    expect(c.read(endedTripUnvisitedProvider).map((l) => l.id), ['left']);
    expect(
      c.read(locationsForSelectedDateProvider).map((l) => l.id).toSet(),
      {'done', 'skip', 'hotel'},
    );
    expect(
      c.read(mapLocationsForSelectedDateProvider).map((l) => l.id).toSet(),
      {'done', 'skip', 'hotel'},
    );
    expect(
      c.read(allDayStopsProvider)[_d19]!.map((l) => l.id).toSet(),
      {'done', 'hotel'},
    );
  });

  test('the switch previews the leftovers ALONE, and only on the map',
      () async {
    final c = _container(ended: true);
    await _settle(c);
    c.read(showUnvisitedOnMapProvider.notifier).state = true;
    expect(c.read(unvisitedPreviewActiveProvider), isTrue);
    expect(
      c.read(mapLocationsForSelectedDateProvider).map((l) => l.id).toList(),
      ['left'],
    );
    expect(
      c.read(allDayStopsProvider)[_d19]!.map((l) => l.id).toList(),
      ['left'],
    );
    // The day list is unchanged: the section, not the day, holds them.
    expect(
      c.read(locationsForSelectedDateProvider).map((l) => l.id).toSet(),
      {'done', 'skip', 'hotel'},
    );
  });
}
