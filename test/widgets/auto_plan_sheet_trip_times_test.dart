import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/subscription_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/repositories/trip_repository.dart';
import 'package:voyza/widgets/app_toast.dart';
import 'package:voyza/widgets/auto_plan_sheet.dart';

/// The trip's places, and nothing else of the real notifier.
class FakeTripNotifier extends StateNotifier<TripState>
    implements TripNotifier {
  FakeTripNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stores the two times like the server does.
class FakeTrips extends Fake implements TripRepository {
  FakeTrips(this.stored);
  Trip stored;

  @override
  Future<Trip> updateTrip(
    String tripId, {
    String? name,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
    double? totalDistance,
    int? totalDurationMinutes,
    String? countryCode,
    bool clearCountryCode = false,
    bool clearDates = false,
    bool? autoRollUnvisited,
    bool? datesTbd,
    int? arrivalMinute,
    bool clearArrivalMinute = false,
    int? departureMinute,
    bool clearDepartureMinute = false,
  }) async {
    return stored = stored.copyWith(
      arrivalMinute:
          clearArrivalMinute ? null : arrivalMinute ?? stored.arrivalMinute,
      departureMinute: clearDepartureMinute
          ? null
          : departureMinute ?? stored.departureMinute,
    );
  }
}

// A trip far enough ahead that every day is still to come.
final _start = DateTime(DateTime.now().year + 1, 3, 9);

Trip _trip({int? arrival, int? departure}) => Trip(
      id: 'trip-1',
      userId: 'u1',
      name: 'Taipei',
      startDate: _start,
      endDate: DateTime(_start.year, _start.month, _start.day + 2),
      arrivalMinute: arrival,
      departureMinute: departure,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

List<LocationModel> _places() => [
      for (var i = 0; i < 9; i++)
        LocationModel(
          id: 'l$i',
          name: 'Place $i',
          address: '',
          coordinates:
              LatLng(25.04 + (i % 5) * 0.004, 121.51 + (i % 7) * 0.004),
          addedAt: DateTime(2026),
          stayDuration: const Duration(minutes: 60),
        ),
    ];

Future<void> _open(
  WidgetTester tester,
  Trip trip, {
  bool owner = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  // Tall enough for the whole plan to be laid out at once.
  tester.view.physicalSize = const Size(390, 2200) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  addTearDown(AppToast.dismiss);

  await tester.pumpWidget(ProviderScope(
    overrides: [
      tripProvider.overrideWith(
          (ref) => FakeTripNotifier(TripState(pinnedLocations: _places()))),
      // The trip as the app last loaded it: it does NOT change when the
      // times are edited below — the sheet has to carry the change itself.
      realtimeActiveTripProvider.overrideWith((ref) => Stream.value(trip)),
      tripRepositoryProvider.overrideWithValue(FakeTrips(trip)),
      isProProvider.overrideWithValue(true),
      isTripOwnerProvider.overrideWith((ref, id) async => owner),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showAutoPlanSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

const _tile = Key('auto-plan-trip-times');

Future<void> _acceptClock(WidgetTester tester, Key field) async {
  await tester.tap(find.byKey(field));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('with no times set, the owner is invited to add them',
      (tester) async {
    await _open(tester, _trip());
    expect(find.text('Arrival and departure'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    expect(find.textContaining('· from '), findsNothing);
    expect(find.textContaining('· until '), findsNothing);
    // Three full days, three places each.
    expect(find.textContaining('3 places'), findsNWidgets(3));
  });

  testWidgets('times already on the trip shape the plan and are shown',
      (tester) async {
    await _open(tester, _trip(arrival: 15 * 60, departure: 15 * 60));
    expect(find.text('Arrive 3:00 PM · Leave 3:00 PM'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.textContaining('· from 4:00 PM'), findsOneWidget);
    expect(find.textContaining('· until 12:00 PM'), findsOneWidget);
  });

  testWidgets('changing the times re-plans at once — both changes',
      (tester) async {
    await _open(tester, _trip());
    await tester.tap(find.byKey(_tile));
    await tester.pumpAndSettle();
    expect(find.text('Nothing moves until you run Auto-plan.'), findsOneWidget);

    // Arrival 2:00 PM: the first day now starts at 3:00 PM.
    await _acceptClock(tester, const Key('trip-times-arrival'));
    expect(find.textContaining('· from 3:00 PM'), findsOneWidget);

    // Then, in the same visit to the sheet, departure 12:00 PM: the last
    // day has no time left. (The plan was rebuilt in between; the second
    // change must still reach it.)
    await _acceptClock(tester, const Key('trip-times-departure'));
    expect(
        find.textContaining('you leave too early for visits'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Arrive 2:00 PM · Leave 12:00 PM'), findsOneWidget);
    expect(find.textContaining('· from 3:00 PM'), findsOneWidget);
    expect(
        find.textContaining('you leave too early for visits'), findsOneWidget);
  });

  testWidgets('someone else on the trip sees the times but cannot edit',
      (tester) async {
    await _open(tester, _trip(arrival: 15 * 60), owner: false);
    expect(find.text('Arrive 3:00 PM'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    await tester.tap(find.byKey(_tile));
    await tester.pumpAndSettle();
    expect(find.text('Nothing moves until you run Auto-plan.'), findsNothing);
  });

  testWidgets('someone else, nothing set: no times row at all', (tester) async {
    await _open(tester, _trip(), owner: false);
    expect(find.text('Arrival and departure'), findsNothing);
  });

  testWidgets('no time at all: says so and offers the way to change it',
      (tester) async {
    final start = _start;
    final oneDay = Trip(
      id: 'trip-1',
      userId: 'u1',
      name: 'Layover',
      startDate: start,
      endDate: start,
      arrivalMinute: 20 * 60,
      departureMinute: 22 * 60,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await _open(tester, oneDay);
    expect(find.textContaining('leave no time for visits'), findsOneWidget);
    expect(find.text('Arrive 8:00 PM · Leave 10:00 PM'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.textContaining('Apply plan'), findsNothing);
  });

  testWidgets('places that do not fit the times are explained', (tester) async {
    final start = _start;
    final oneDay = Trip(
      id: 'trip-1',
      userId: 'u1',
      name: 'Layover',
      startDate: start,
      endDate: start,
      arrivalMinute: 10 * 60,
      departureMinute: 19 * 60,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await _open(tester, oneDay);
    expect(
        find.textContaining('· from 11:00 AM · until 4:00 PM'), findsOneWidget);
    expect(
        find.text("They don't fit around your arrival and departure times. "
            'Add a day, or change the times.'),
        findsOneWidget);
  });
}
