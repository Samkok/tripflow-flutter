import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/repositories/trip_repository.dart';
import 'package:voyza/screens/create_trip_screen.dart';
import 'package:voyza/services/analytics_service.dart';
import 'package:voyza/utils/trip_dates.dart';

import '../helpers/pump.dart';

typedef _Created = ({
  String userId,
  String name,
  DateTime? start,
  DateTime? end,
  String? countryCode,
  bool datesTbd,
});

/// Records what the form asked to be created.
class _Trips extends Fake implements TripRepository {
  final created = <_Created>[];
  bool fail = false;

  @override
  Future<Trip> createTrip({
    required String userId,
    required String name,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
    String? countryCode,
    bool datesTbd = false,
  }) async {
    if (fail) throw StateError('offline');
    created.add((
      userId: userId,
      name: name,
      start: startDate,
      end: endDate,
      countryCode: countryCode,
      datesTbd: datesTbd,
    ));
    return Trip(
      id: 'new',
      userId: userId,
      name: name,
      startDate: startDate ?? tripDatesTbdAnchor,
      endDate: endDate ?? tripDatesTbdAnchor,
      countryCode: countryCode,
      datesTbd: datesTbd,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
  }
}

typedef _H = ({
  _Trips trips,
  List<({Trip trip, bool first})> created,
  ProviderContainer container,
});

Future<_H> _pump(
  WidgetTester tester, {
  String? initialCountryCode,
  PickDateRange? pickDateRange,
  List<Trip> existing = const [],
}) async {
  await useMockPrefs();
  final trips = _Trips();
  final created = <({Trip trip, bool first})>[];
  final container = await pumpVoyza(
    tester,
    CreateTripScreen(
      initialCountryCode: initialCountryCode,
      pickDateRange: pickDateRange,
      onCreated: (trip, {required wasFirstTrip}) =>
          created.add((trip: trip, first: wasFirstTrip)),
    ),
    overrides: [
      tripRepositoryProvider.overrideWithValue(trips),
      currentUserIdProvider.overrideWithValue('u1'),
      userTripsProvider.overrideWith((ref) async => existing),
    ],
    scaffold: false,
  );
  // The first-trip answer needs the trips list to have arrived.
  await container.read(userTripsProvider.future);
  await tester.pumpAndSettle();
  return (trips: trips, created: created, container: container);
}

bool _submitEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.byKey(const Key('create-trip-submit')))
        .onPressed !=
    null;

Future<void> _typeAndCreate(WidgetTester tester,
    [String name = 'Taipei']) async {
  await tester.enterText(find.byKey(const Key('create-trip-name')), name);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('create-trip-submit')));
  await tester.pumpAndSettle();
}

void main() {
  final fired = <String>[];
  setUp(() {
    fired.clear();
    AnalyticsService.debugOnFire = (name, params) => fired.add(name);
  });
  tearDown(() => AnalyticsService.debugOnFire = null);

  testWidgets('a name alone creates an undated three-day trip', (tester) async {
    final h = await _pump(tester);
    expect(find.text('No dates yet · 3 days'), findsOneWidget);
    expect(_submitEnabled(tester), isFalse, reason: 'no name yet');

    await _typeAndCreate(tester);

    final row = h.trips.created.single;
    expect(row.name, 'Taipei');
    expect(row.userId, 'u1');
    expect(row.datesTbd, isTrue);
    expect(row.start, tripDatesTbdAnchor);
    expect(row.end, shiftTripDay(tripDatesTbdAnchor, 2));
    expect(row.countryCode, isNull);
    expect(h.created.single.first, isTrue, reason: 'the first trip ever');
    expect(fired, ['trip_created']);
  });

  testWidgets('the stepper sets the number of days', (tester) async {
    final h = await _pump(tester, existing: [
      Trip(
        id: 'old',
        userId: 'u1',
        name: 'Old',
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2026, 1, 2),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    ]);
    await tester.tap(find.byKey(const Key('create-trip-days-plus')));
    await tester.tap(find.byKey(const Key('create-trip-days-plus')));
    await tester.pumpAndSettle();
    expect(find.text('No dates yet · 5 days'), findsOneWidget);

    await _typeAndCreate(tester);
    expect(h.trips.created.single.end, shiftTripDay(tripDatesTbdAnchor, 4));
    expect(h.created.single.first, isFalse, reason: 'not the first trip');
  });

  testWidgets('Pick dates makes a dated trip; No dates yet flips back',
      (tester) async {
    final range =
        DateTimeRange(start: DateTime(2027, 3, 9), end: DateTime(2027, 3, 12));
    final h = await _pump(tester, pickDateRange: (_, __) async => range);
    await tester.tap(find.text('Pick dates'));
    await tester.pumpAndSettle();
    expect(find.text('Mar 9 – Mar 12, 2027 (4 days)'), findsOneWidget);
    expect(find.byKey(const Key('create-trip-days-plus')), findsNothing);

    await tester.tap(find.text('No dates yet'));
    await tester.pumpAndSettle();
    expect(find.text('No dates yet · 3 days'), findsOneWidget);

    await tester.tap(find.text('Pick dates'));
    await tester.pumpAndSettle();
    await _typeAndCreate(tester);
    final row = h.trips.created.single;
    expect(row.datesTbd, isFalse);
    expect(row.start, range.start);
    expect(row.end, range.end);
  });

  testWidgets('the country hand-off is upper-cased', (tester) async {
    final h = await _pump(tester, initialCountryCode: 'jp');
    expect(find.text('Japan'), findsOneWidget, reason: 'named, not coded');
    await _typeAndCreate(tester);
    expect(h.trips.created.single.countryCode, 'JP');
  });

  testWidgets('an empty country hand-off means none', (tester) async {
    final h = await _pump(tester, initialCountryCode: '');
    expect(find.text('Add a country · optional'), findsOneWidget);
    await _typeAndCreate(tester);
    expect(h.trips.created.single.countryCode, isNull);
  });

  testWidgets('a failed create shows the toast and re-enables the button',
      (tester) async {
    final h = await _pump(tester);
    h.trips.fail = true;
    await _typeAndCreate(tester);
    expect(find.textContaining('Could not create trip'), findsOneWidget);
    expect(_submitEnabled(tester), isTrue);
    expect(h.created, isEmpty);
    expect(fired, isEmpty, reason: 'nothing was created');
    // Let the toast run out so no timer outlives the test.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
