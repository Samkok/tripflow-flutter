import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/subscription_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/repositories/location_repository.dart';
import 'package:voyza/services/location_add_service.dart';
import 'package:voyza/services/places_service.dart';

import '../helpers/fakes.dart';
import '../helpers/pump.dart';

class _Repo extends Fake implements LocationRepository {
  final added = <SavedLocation>[];
  @override
  Future<void> addLocation(SavedLocation location) async => added.add(location);
}

class _Trips extends FakeTripNotifier {
  int routeClears = 0;
  @override
  void clearRouteForEdit() => routeClears++;
}

final _day = DateTime(2026, 10, 6);
final _trip = sampleTrip(id: 't1', countryCode: 'TW');

PlaceDetails _place({String id = 'p-101', String? country = 'TW'}) =>
    PlaceDetails(
      name: 'Din Tai Fung',
      address: 'Xinyi Road',
      coordinates: const LatLng(25.033, 121.53),
      placeId: id,
      countryCode: country,
      types: const ['restaurant'],
      // Hours present → no background hours backfill timer in the test.
      openingHours: const [],
    );

SavedLocation _row(String placeId, {DateTime? day, String tripId = 't1'}) =>
    SavedLocation(
      id: 'row-$placeId',
      userId: 'u1',
      name: 'Din Tai Fung',
      lat: 25.033,
      lng: 121.53,
      createdAt: _day,
      fingerprint: 'fp',
      placeId: placeId,
      scheduledDate: day,
      tripId: tripId,
    );

typedef _H = ({
  BuildContext context,
  WidgetRef ref,
  _Repo repo,
  _Trips trips,
});

Future<_H> _pump(
  WidgetTester tester, {
  String? mapTripId = 't1',
  List<SavedLocation> rows = const [],
  bool canWrite = true,
  Trip? trip,
}) async {
  await useMockPrefs();
  final repo = _Repo();
  final trips = _Trips();
  late BuildContext ctx;
  late WidgetRef r;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      locationRepositoryProvider.overrideWithValue(repo),
      savedLocationsProvider.overrideWith((ref) => Stream.value(rows)),
      isProProvider.overrideWithValue(true),
      hasWriteAccessProvider.overrideWith((ref, id) async => canWrite),
      localActiveTripIdProvider
          .overrideWith((ref) => FakeLocalActiveTripNotifier(mapTripId)),
      tripProvider.overrideWith((ref) => trips),
      currentUserIdProvider.overrideWithValue('u1'),
      userTripsProvider.overrideWith((ref) async => [trip ?? _trip]),
      realtimeActiveTripProvider.overrideWith((ref) => Stream.value(null)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(builder: (context, ref, _) {
          ctx = context;
          r = ref;
          return const SizedBox();
        }),
      ),
    ),
  ));
  await r.read(savedLocationsProvider.future);
  await tester.pump();
  return (context: ctx, ref: r, repo: repo, trips: trips);
}

/// The first place on an empty board earns a delayed nudge toward Optimize;
/// let it land before the test ends.
Future<void> _letTheNudgeLand(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 2));

void main() {
  testWidgets('writes the row to the trip and day and clears the map route',
      (tester) async {
    final h = await _pump(tester);
    final ok = await LocationAddService(h.ref).addPlace(
      h.context,
      _place(),
      trip: _trip,
      day: _day,
      tag: 'food',
      tagConfirmed: true,
    );
    await tester.pump();
    expect(ok, isTrue);
    expect(h.repo.added, hasLength(1));
    final row = h.repo.added.single;
    expect(row.tripId, 't1');
    expect(row.scheduledDate, _day);
    expect(row.tag, 'food');
    expect(row.placeId, 'p-101');
    expect(row.stayDuration, 1800);
    expect(row.name, 'Din Tai Fung');
    expect(h.trips.routeClears, 1, reason: 't1 is the trip on the map');
    await _letTheNudgeLand(tester);
    expect(find.textContaining('First place saved'), findsOneWidget,
        reason: 'the first place points at Optimize, Pro or not');
  });

  testWidgets(
      'a trip that is not on the map gets its row, the map keeps '
      'its route', (tester) async {
    final h = await _pump(tester, mapTripId: 'other');
    final ok = await LocationAddService(h.ref).addPlace(
      h.context,
      _place(),
      trip: _trip,
      day: _day,
      tagConfirmed: true,
    );
    expect(ok, isTrue);
    expect(h.repo.added, hasLength(1));
    expect(h.trips.routeClears, 0);
    await _letTheNudgeLand(tester);
  });

  testWidgets('the same place on the same day is refused', (tester) async {
    final h = await _pump(tester, rows: [_row('p-101', day: _day)]);
    final ok = await LocationAddService(h.ref).addPlace(
      h.context,
      _place(),
      trip: _trip,
      day: _day,
      tagConfirmed: true,
    );
    await tester.pump();
    expect(ok, isFalse);
    expect(h.repo.added, isEmpty);
    expect(find.textContaining('already planned'), findsOneWidget);
  });

  testWidgets('the same place on another day is fine', (tester) async {
    final h =
        await _pump(tester, rows: [_row('p-101', day: DateTime(2026, 10, 5))]);
    final ok = await LocationAddService(h.ref).addPlace(
      h.context,
      _place(),
      trip: _trip,
      day: _day,
      tagConfirmed: true,
    );
    expect(ok, isTrue);
    expect(h.repo.added, hasLength(1));
    await _letTheNudgeLand(tester);
    expect(find.textContaining('First place saved'), findsNothing,
        reason: 'the board already had a place');
  });

  testWidgets('no day means the Unscheduled bucket', (tester) async {
    final h = await _pump(tester);
    final ok = await LocationAddService(h.ref).addPlace(
      h.context,
      _place(),
      trip: _trip,
      day: null,
      tagConfirmed: true,
    );
    expect(ok, isTrue);
    expect(h.repo.added.single.scheduledDate, isNull);
    await _letTheNudgeLand(tester);
  });

  testWidgets('a read-only member cannot add', (tester) async {
    final h = await _pump(tester, canWrite: false);
    final ok = await LocationAddService(h.ref).addPlace(
      h.context,
      _place(),
      trip: _trip,
      day: _day,
      tagConfirmed: true,
    );
    await tester.pump();
    expect(ok, isFalse);
    expect(h.repo.added, isEmpty);
    expect(find.textContaining('permission'), findsOneWidget);
  });

  testWidgets('a loose place on a trip-less map has no trip id',
      (tester) async {
    final h = await _pump(tester, mapTripId: null);
    final ok = await LocationAddService(h.ref).addPlace(
      h.context,
      _place(country: 'JP'),
      trip: null,
      day: _day,
      tagConfirmed: true,
    );
    expect(ok, isTrue);
    expect(h.repo.added.single.tripId, isNull);
    expect(h.trips.routeClears, 1, reason: 'the map shows the loose places');
    await _letTheNudgeLand(tester);
  });

  test('savedLocationFromPlace copies what Google knows', () {
    final row = savedLocationFromPlace(
      PlaceDetails(
        name: 'Taipei 101',
        address: 'Xinyi',
        coordinates: const LatLng(25.0339, 121.5645),
        placeId: 'p1',
        types: const ['tourist_attraction'],
        photoReferences: const ['ref-a', 'ref-b'],
        floor: '89F',
      ),
      id: 'id-1',
      tripId: 't1',
      day: _day,
      tag: 'sight',
      now: _day,
    );
    expect(row.id, 'id-1');
    expect(row.originalName, 'Taipei 101');
    expect(row.photoReferences, ['ref-a', 'ref-b']);
    expect(row.placeTypes, ['tourist_attraction']);
    expect(row.floor, '89F');
    expect(row.hoursLastRefreshedAt, isNull, reason: 'no hours came back');
    expect(row.createdAt, _day);
  });
}
