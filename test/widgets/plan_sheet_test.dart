import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/all_days_route_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/subscription_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/widgets/plan_sheet.dart';

import '../helpers/fakes.dart';
import '../helpers/pump.dart';

// A trip far enough ahead that every day is still to come.
final _start = DateTime(DateTime.now().year + 1, 3, 9);
final _trip = sampleTrip(id: 'trip-1', start: _start, days: 3);

List<LocationModel> _places() => [
      for (var i = 0; i < 9; i++)
        LocationModel(
          id: 'l$i',
          name: 'Place $i',
          address: '',
          coordinates:
              LatLng(25.04 + (i % 5) * 0.004, 121.51 + (i % 7) * 0.004),
          addedAt: DateTime(2026),
          scheduledDate: _start,
          tripId: 'trip-1',
          stayDuration: const Duration(minutes: 60),
        ),
    ];

Future<void> _open(
  WidgetTester tester, {
  PlanScope initial = PlanScope.day,
  DateTime? selectedDate,
  bool allDays = false,
}) async {
  await useMockPrefs();
  await pumpVoyza(
    tester,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showPlanSheet(context, initial: initial),
          child: const Text('open'),
        ),
      ),
    ),
    overrides: [
      tripProvider.overrideWith(
          (ref) => FakeTripNotifier(TripState(pinnedLocations: _places()))),
      realtimeActiveTripProvider.overrideWith((ref) => Stream.value(_trip)),
      selectedDateProvider.overrideWith((ref) => selectedDate ?? _start),
      allDaysModeProvider.overrideWith((ref) => allDays),
      isProProvider.overrideWithValue(true),
      isTripOwnerProvider.overrideWith((ref, id) async => true),
    ],
    // Tall enough for either panel to be laid out at once.
    physicalSize: const Size(390, 2200) * 2,
    devicePixelRatio: 2,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on Whole trip when asked, with the Auto-plan body',
      (tester) async {
    await _open(tester, initial: PlanScope.trip);
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Whole trip'), findsOneWidget);
    expect(find.text('Arrival and departure'), findsOneWidget);
    expect(find.text('TRAVEL STYLE'), findsNothing);
  });

  testWidgets('This day shows the day planner with Optimize ready',
      (tester) async {
    await _open(tester, initial: PlanScope.trip);
    await tester.tap(find.text('This day'));
    await tester.pumpAndSettle();
    expect(find.text('TRAVEL STYLE'), findsOneWidget);
    expect(find.text('Optimize'), findsOneWidget);
    expect(find.text('Arrival and departure'), findsNothing);
    // A first optimize folds the start/end tiles behind one line.
    expect(find.text('Starts at Place 0 · Ends where the route does'),
        findsOneWidget);
    expect(find.text('ACTIVE STOPS'), findsNothing);
    await tester.tap(find.text('Start and end'));
    await tester.pumpAndSettle();
    expect(find.text('ACTIVE STOPS'), findsOneWidget);
    expect(find.text('END THE DAY AT'), findsOneWidget);
  });

  testWidgets('All days mode asks for a day first', (tester) async {
    await _open(tester, allDays: true);
    expect(find.textContaining('Pick a day on the map first'), findsOneWidget);
    expect(find.text('TRAVEL STYLE'), findsNothing);
  });

  testWidgets('a day with no places asks for places first', (tester) async {
    await _open(tester, selectedDate: _start.add(const Duration(days: 1)));
    expect(find.text('Add places to this day first.'), findsOneWidget);
  });
}
