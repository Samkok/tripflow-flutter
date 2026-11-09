import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/providers/all_days_route_provider.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/onboarding_checklist_provider.dart';
import 'package:voyza/providers/onboarding_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/utils/open_trip_on_map.dart';

import '../helpers/fakes.dart';

/// Records `clearTrip` and lets a test hand pins back later, the way the
/// locations stream does after a switch.
class _Trips extends FakeTripNotifier {
  _Trips([super.state]);
  int cleared = 0;

  @override
  void clearTrip() {
    cleared++;
    state = TripState();
  }

  void land(List<LocationModel> pins) =>
      state = state.copyWith(pinnedLocations: pins);
}

class _Checklist extends StateNotifier<ChecklistState>
    implements ChecklistNotifier {
  _Checklist() : super(const ChecklistState());
  final marks = <(ChecklistStep, bool)>[];

  @override
  Future<void> mark(ChecklistStep step, {bool silent = false}) async {
    marks.add((step, silent));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _start = DateTime(2026, 10, 5);

LocationModel _pin(String id, String tripId) => LocationModel(
      id: id,
      name: 'Stop $id',
      address: '',
      coordinates: const LatLng(25.03, 121.56),
      addedAt: _start,
      scheduledDate: _start,
      tripId: tripId,
    );

SavedLocation _row(String id, String tripId) => SavedLocation(
      id: id,
      userId: 'u1',
      name: 'Stop $id',
      lat: 25.03,
      lng: 121.56,
      createdAt: _start,
      fingerprint: 'fp-$id',
      tripId: tripId,
    );

typedef _Harness = ({
  WidgetRef ref,
  FakeLocalActiveTripNotifier mapTrip,
  _Trips trips,
  _Checklist checklist,
});

Future<_Harness> _pump(
  WidgetTester tester, {
  String? mapTripId,
  List<SavedLocation> rows = const [],
  TripState? tripState,
}) async {
  final mapTrip = FakeLocalActiveTripNotifier(mapTripId);
  final trips = _Trips(tripState);
  final checklist = _Checklist();
  late WidgetRef captured;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      localActiveTripIdProvider.overrideWith((ref) => mapTrip),
      tripProvider.overrideWith((ref) => trips),
      checklistProvider.overrideWith((ref) => checklist),
      savedLocationsProvider.overrideWith((ref) => Stream.value(rows)),
    ],
    child: MaterialApp(
      home: Consumer(builder: (context, ref, _) {
        captured = ref;
        return const SizedBox();
      }),
    ),
  ));
  // The app keeps the saved-locations stream alive from the first frame;
  // here it must be read once so its first value has landed before the
  // helpers look at it (a not-yet-known list means "wait for pins").
  await captured.read(savedLocationsProvider.future);
  await tester.pump();
  return (ref: captured, mapTrip: mapTrip, trips: trips, checklist: checklist);
}

void main() {
  group('setMapTrip', () {
    testWidgets(
        'a different trip clears the old pins, is stored and marks '
        'the checklist silently', (tester) async {
      final h = await _pump(tester, mapTripId: 'old');
      final changed = await setMapTrip(h.ref, sampleTrip(id: 'new'));
      expect(changed, isTrue);
      expect(h.trips.cleared, 1);
      expect(h.mapTrip.state, 'new');
      expect(h.mapTrip.log, ['set:new']);
      expect(h.checklist.marks, [(ChecklistStep.activateTrip, true)]);
    });

    testWidgets('the trip already on the map is left alone', (tester) async {
      final h = await _pump(tester, mapTripId: 't1');
      final changed = await setMapTrip(h.ref, sampleTrip(id: 't1'));
      expect(changed, isFalse);
      expect(h.trips.cleared, 0);
      expect(h.mapTrip.log, isEmpty);
      expect(h.checklist.marks, isEmpty);
    });
  });

  group('openTripOnMap', () {
    testWidgets('switches the trip, lands on its day and asks for the Map tab',
        (tester) async {
      final h = await _pump(tester, mapTripId: null);
      h.ref.read(allDaysModeProvider.notifier).state = true;
      await openTripOnMap(h.ref, sampleTrip(id: 't1', start: _start),
          now: DateTime(2026, 10, 6, 9));
      expect(h.mapTrip.state, 't1');
      expect(h.ref.read(allDaysModeProvider), isFalse);
      expect(h.ref.read(selectedDateProvider), DateTime(2026, 10, 6));
      expect(h.ref.read(mainTabRequestProvider), mapTabIndex);
    });
  });

  group('ensureMapTrip', () {
    testWidgets('waits for the new trip\'s pins when it has places',
        (tester) async {
      final h = await _pump(tester,
          mapTripId: 'old',
          rows: [_row('l1', 'new')],
          tripState: TripState(pinnedLocations: [_pin('o1', 'old')]));
      var done = false;
      final pending =
          ensureMapTrip(h.ref, sampleTrip(id: 'new')).then((_) => done = true);
      await tester.pump();
      expect(done, isFalse, reason: 'the new pins have not landed yet');
      h.trips.land([_pin('l1', 'new')]);
      await pending;
      expect(done, isTrue);
      expect(h.trips.cleared, 1);
    });

    testWidgets('does not wait for a trip without places', (tester) async {
      final h = await _pump(tester, mapTripId: 'old', rows: const []);
      await ensureMapTrip(h.ref, sampleTrip(id: 'empty'));
      expect(h.mapTrip.state, 'empty');
    });

    testWidgets('is a no-op for the trip already on the map', (tester) async {
      final h = await _pump(tester,
          mapTripId: 't1',
          tripState: TripState(pinnedLocations: [_pin('a', 't1')]));
      await ensureMapTrip(h.ref, sampleTrip(id: 't1'));
      expect(h.trips.cleared, 0);
    });
  });
}
