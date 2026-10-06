import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/repositories/trip_repository.dart';
import 'package:voyza/utils/trip_dates.dart';
import 'package:voyza/utils/trip_times.dart';
import 'package:voyza/widgets/app_toast.dart';
import 'package:voyza/widgets/trip_times_sheet.dart';

typedef _Call = ({
  int? arrival,
  bool clearArrival,
  int? departure,
  bool clearDeparture,
});

/// Stands in for the server: stores the two times the way the real
/// repository does, and can be told to fail or to drop them.
class FakeTrips extends Fake implements TripRepository {
  FakeTrips(this.stored);

  Trip stored;
  final calls = <_Call>[];
  bool fail = false;

  /// A server that does not know the two columns yet: the update goes
  /// through without them.
  bool dropTimes = false;

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
    calls.add((
      arrival: arrivalMinute,
      clearArrival: clearArrivalMinute,
      departure: departureMinute,
      clearDeparture: clearDepartureMinute,
    ));
    if (fail) throw StateError('offline');
    if (dropTimes) return stored;
    stored = stored.copyWith(
      arrivalMinute:
          clearArrivalMinute ? null : arrivalMinute ?? stored.arrivalMinute,
      departureMinute: clearDepartureMinute
          ? null
          : departureMinute ?? stored.departureMinute,
    );
    return stored;
  }
}

Trip _trip({
  int? arrival,
  int? departure,
  DateTime? start,
  DateTime? end,
  bool datesTbd = false,
}) =>
    Trip(
      id: 'trip-1',
      userId: 'u1',
      name: 'Taipei',
      startDate: start ?? DateTime(2026, 10, 12),
      endDate: end ?? DateTime(2026, 10, 16),
      datesTbd: datesTbd,
      arrivalMinute: arrival,
      departureMinute: departure,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

const _arrivalField = Key('trip-times-arrival');
const _departureField = Key('trip-times-departure');

class Opened {
  Opened(this.trips, this.changes);
  final FakeTrips trips;
  final List<Trip> changes;
}

Future<Opened> open(
  WidgetTester tester,
  Trip trip, {
  Size size = const Size(390, 844),
  double textScale = 1,
  TripTimeField? openClockFor,
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  addTearDown(AppToast.dismiss);

  final trips = FakeTrips(trip);
  final changes = <Trip>[];
  await tester.pumpWidget(ProviderScope(
    overrides: [tripRepositoryProvider.overrideWithValue(trips)],
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showTripTimesSheet(
                context,
                trip: trip,
                onChanged: changes.add,
                openClockFor: openClockFor,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return Opened(trips, changes);
}

/// Opens the clock from [field] and accepts the time it opened on.
Future<void> acceptSuggestedTime(WidgetTester tester, Key field) async {
  await tester.tap(find.byKey(field));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

/// Lets a toast run its course so no timer outlives the test.
Future<void> letToastGo(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a trip with no times: both fields invite to set one',
      (tester) async {
    await open(tester, _trip());
    expect(find.text('Arrival and departure'), findsOneWidget);
    expect(find.text('Arrival'), findsOneWidget);
    expect(find.text('Departure'), findsOneWidget);
    // Each field names the day it belongs to.
    expect(find.text('Day 1 · Mon, Oct 12'), findsOneWidget);
    expect(find.text('Day 5 · Fri, Oct 16'), findsOneWidget);
    expect(find.text('Set time'), findsNWidgets(2));
    expect(find.text('Not set: Auto-plan treats this as a full day.'),
        findsNWidgets(2));
    expect(find.text('Remove'), findsNothing);
    expect(find.text('Nothing moves until you run Auto-plan.'), findsOneWidget);
  });

  testWidgets('setting the arrival saves it and says what it does',
      (tester) async {
    final o = await open(tester, _trip());
    await acceptSuggestedTime(tester, _arrivalField);

    expect(o.trips.calls, [
      (
        arrival: 14 * 60,
        clearArrival: false,
        departure: null,
        clearDeparture: false
      ),
    ]);
    expect(find.text('2:00 PM'), findsOneWidget);
    expect(
        find.text(
            'Auto-plan starts this day at 3:00 PM, 1 hour after you arrive.'),
        findsOneWidget);
    expect(find.text('Set time'), findsOneWidget, reason: 'departure');
    expect(find.text('Remove'), findsOneWidget);
    // The screen behind hears about it.
    expect(o.changes.single.arrivalMinute, 14 * 60);
    expect(o.changes.single.departureMinute, isNull);
  });

  testWidgets('setting the departure saves it and says what it does',
      (tester) async {
    final o = await open(tester, _trip(arrival: 15 * 60));
    await acceptSuggestedTime(tester, _departureField);

    expect(o.trips.calls.single.departure, 12 * 60);
    expect(o.trips.calls.single.arrival, isNull,
        reason: 'the other time is left alone');
    expect(find.text('12:00 PM'), findsOneWidget);
    expect(find.text('3:00 PM'), findsOneWidget);
    expect(
        find.text(
            'Auto-plan ends this day at 9:00 AM, 3 hours before you leave.'),
        findsNothing,
        reason: '09:00 is when a day starts: nothing is left of it');
    expect(
        find.text(
            'Too early to plan visits that day. Auto-plan keeps it free.'),
        findsOneWidget);
    expect(o.changes.single.departureMinute, 12 * 60);
    expect(o.changes.single.arrivalMinute, 15 * 60);
  });

  testWidgets('the clock opens on the time already set', (tester) async {
    final o = await open(tester, _trip(arrival: 9 * 60 + 30));
    await acceptSuggestedTime(tester, _arrivalField);
    expect(o.trips.calls.single.arrival, 9 * 60 + 30);
  });

  testWidgets('cancelling the clock changes nothing', (tester) async {
    final o = await open(tester, _trip());
    await tester.tap(find.byKey(_arrivalField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(o.trips.calls, isEmpty);
    expect(o.changes, isEmpty);
    expect(find.text('Set time'), findsNWidgets(2));
  });

  testWidgets('Remove takes a time off again', (tester) async {
    final o = await open(tester, _trip(arrival: 15 * 60, departure: 14 * 60));
    expect(find.text('Remove'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('trip-times-arrival-remove')));
    await tester.pumpAndSettle();

    expect(o.trips.calls, [
      (
        arrival: null,
        clearArrival: true,
        departure: null,
        clearDeparture: false
      ),
    ]);
    expect(find.text('3:00 PM'), findsNothing);
    expect(find.text('2:00 PM'), findsOneWidget, reason: 'departure stays');
    expect(find.text('Set time'), findsOneWidget);
    expect(o.changes.single.arrivalMinute, isNull);
    expect(o.changes.single.departureMinute, 14 * 60);
  });

  testWidgets('a failed save puts the old value back and says so',
      (tester) async {
    final o = await open(tester, _trip(arrival: 9 * 60));
    o.trips.fail = true;
    await tester.tap(find.byKey(const Key('trip-times-arrival-remove')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text("Couldn't save the time. Try again."), findsOneWidget);
    expect(find.text('9:00 AM'), findsOneWidget, reason: 'still set');
    expect(o.changes, isEmpty);
    await letToastGo(tester);
  });

  testWidgets('a server that drops the time is not mistaken for a save',
      (tester) async {
    final o = await open(tester, _trip());
    o.trips.dropTimes = true;
    await tester.tap(find.byKey(_arrivalField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text("Couldn't save the time. Try again."), findsOneWidget);
    expect(find.text('Set time'), findsNWidgets(2));
    expect(o.changes, isEmpty);
    await letToastGo(tester);
  });

  testWidgets('a one-day trip: leaving before arriving is refused',
      (tester) async {
    final day = DateTime(2026, 10, 12);
    final o = await open(tester, _trip(arrival: 15 * 60, start: day, end: day));
    expect(find.text('Day 1 · Mon, Oct 12'), findsNWidgets(2));
    // The clock opens on noon, before the 3 PM arrival.
    await tester.tap(find.byKey(_departureField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(o.trips.calls, isEmpty);
    expect(
        find.text('This trip is one day long: the departure has to be after '
            'the arrival.'),
        findsOneWidget);
    expect(find.text('Set time'), findsOneWidget);
    await letToastGo(tester);
  });

  testWidgets('a one-day trip with no time in between says so', (tester) async {
    final day = DateTime(2026, 10, 12);
    await open(tester,
        _trip(arrival: 14 * 60, departure: 17 * 60, start: day, end: day));
    expect(
        find.text('These two times leave no room for a visit in between, so '
            'Auto-plan has nothing to plan.'),
        findsOneWidget);
  });

  testWidgets('a trip with no dates yet names its days by number',
      (tester) async {
    final anchor = tripDatesTbdAnchor;
    await open(
        tester,
        _trip(
          start: anchor,
          end: shiftTripDay(anchor, 2),
          datesTbd: true,
          arrival: 15 * 60,
        ));
    expect(find.text('Day 1'), findsOneWidget);
    expect(find.text('Day 3'), findsOneWidget);
    expect(find.textContaining('2100'), findsNothing);
    expect(find.textContaining('Jan'), findsNothing);
  });

  testWidgets('follows the 24-hour clock when the phone uses it',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        tripRepositoryProvider
            .overrideWithValue(FakeTrips(_trip(arrival: 15 * 60))),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
        home: Scaffold(
          body: TripTimesSheet(trip: _trip(arrival: 15 * 60)),
        ),
      ),
    ));
    expect(find.text('15:00'), findsOneWidget);
    expect(
        find.text(
            'Auto-plan starts this day at 16:00, 1 hour after you arrive.'),
        findsOneWidget);
  });

  testWidgets('fits a small phone at a large text size', (tester) async {
    await open(
      tester,
      _trip(arrival: 15 * 60, departure: 14 * 60),
      size: const Size(320, 568),
      textScale: 1.5,
    );
    // A layout overflow would have failed the test by now.
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Remove'), findsNWidgets(2));
  });

  testWidgets('opened for one time, the clock is up straight away',
      (tester) async {
    final o = await open(tester, _trip(arrival: 15 * 60),
        openClockFor: TripTimeField.departure);
    // The clock is already on top of the sheet: accept what it opened on.
    expect(find.text('OK'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(o.trips.calls.single.departure, 12 * 60);
    expect(o.trips.calls.single.arrival, isNull);
    // …and the sheet is there underneath, showing what was saved.
    expect(find.text('12:00 PM'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('cancelling that clock leaves the sheet, nothing saved',
      (tester) async {
    final o = await open(tester, _trip(), openClockFor: TripTimeField.arrival);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(o.trips.calls, isEmpty);
    expect(find.text('Set time'), findsNWidgets(2));
  });

  testWidgets('Done closes the sheet', (tester) async {
    await open(tester, _trip());
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Arrival and departure'), findsNothing);
  });
}
