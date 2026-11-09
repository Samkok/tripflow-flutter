import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/subscription_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/repositories/location_repository.dart';
import 'package:voyza/services/places_gateway.dart';
import 'package:voyza/services/places_service.dart';
import 'package:voyza/widgets/add_place_sheet.dart';

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
final _trip = sampleTrip(id: 't1', name: 'Taipei', countryCode: 'TW');
const _spot = LatLng(25.033, 121.53);

PlaceDetails _details() => PlaceDetails(
      name: 'Din Tai Fung',
      address: 'Xinyi Road',
      coordinates: _spot,
      placeId: 'p-101',
      countryCode: 'TW',
      types: const ['restaurant'],
      openingHours: const [], // hours present → no backfill timer
    );

FakePlacesGateway _google() => FakePlacesGateway(
      predictions: [
        PlacePrediction(
          placeId: 'p-101',
          description: 'Din Tai Fung, Xinyi Road',
          mainText: 'Din Tai Fung',
          secondaryText: 'Xinyi Road',
          distanceMeters: 1200,
        ),
      ],
      detailsById: {'p-101': _details()},
      linkPlace: _details(),
      nearbyPlaces: const [
        NearbyPlace(
          placeId: 'p-101',
          name: 'Din Tai Fung',
          vicinity: 'Xinyi Road',
          coordinates: _spot,
          distanceMeters: 120,
          primaryType: 'restaurant',
          types: ['restaurant'],
        ),
      ],
    );

typedef _H = ({_Repo repo, _Trips trips, FakePlacesGateway google});

Future<_H> _open(
  WidgetTester tester, {
  AddPlaceSegment initial = AddPlaceSegment.search,
  LatLng? nearbyCenter,
  List<SavedLocation> rows = const [],
}) async {
  await useMockPrefs();
  final repo = _Repo();
  final trips = _Trips();
  final google = _google();
  final container = await pumpVoyza(
    tester,
    Builder(
      builder: (ctx) => Center(
        child: TextButton(
          onPressed: () => showAddPlaceSheet(ctx,
              trip: _trip,
              day: _day,
              initial: initial,
              nearbyCenter: nearbyCenter),
          child: const Text('open'),
        ),
      ),
    ),
    overrides: [
      placesGatewayProvider.overrideWithValue(google),
      locationRepositoryProvider.overrideWithValue(repo),
      savedLocationsProvider.overrideWith((ref) => Stream.value(rows)),
      isProProvider.overrideWithValue(true),
      hasWriteAccessProvider.overrideWith((ref, id) async => true),
      localActiveTripIdProvider
          .overrideWith((ref) => FakeLocalActiveTripNotifier('t1')),
      tripProvider.overrideWith((ref) => trips),
      currentUserIdProvider.overrideWithValue('u1'),
      userTripsProvider.overrideWith((ref) async => [_trip]),
      realtimeActiveTripProvider.overrideWith((ref) => Stream.value(null)),
    ],
  );
  // The app keeps the saved-locations stream alive from the first frame;
  // the sheet's duplicate rule reads it synchronously.
  await container.read(savedLocationsProvider.future);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (repo: repo, trips: trips, google: google);
}

/// The tag step after a search or link add: take the suggestion. The
/// busy spinner keeps animating under the tag sheet, so settle by steps
/// until the sheet's button is there, then confirm.
Future<void> _confirmTag(WidgetTester tester) async {
  Finder button() {
    // "Confirm: Food" with the suggested tag selected, else the plain one.
    final confirm = find.textContaining('Confirm');
    return confirm.evaluate().isNotEmpty
        ? confirm
        : find.text('Add without a tag');
  }

  for (var i = 0; i < 30 && button().evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(button(), findsOneWidget, reason: 'the tag step should be showing');
  // The sheet is still sliding in when its button first exists; a tap
  // then lands below the screen. Let the entrance finish.
  await tester.pump(const Duration(milliseconds: 600));
  await tester.tap(button());
  await tester.pumpAndSettle();
}

/// Toasts time out on their own; let them, so no timer outlives the test.
Future<void> _settleToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('search → tap → tag → the place lands on the trip and day',
      (tester) async {
    final h = await _open(tester);
    expect(find.text('Add a place'), findsOneWidget);
    expect(find.textContaining('Taipei · Oct 6'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('add-place-search')), 'din');
    await tester.pump(const Duration(milliseconds: 350)); // debounce
    await tester.pumpAndSettle();
    expect(find.text('Din Tai Fung'), findsOneWidget);

    await tester.tap(find.text('Din Tai Fung'));
    await _confirmTag(tester);

    expect(h.repo.added, hasLength(1));
    final row = h.repo.added.single;
    expect(row.tripId, 't1');
    expect(row.scheduledDate, _day);
    expect(row.placeId, 'p-101');
    expect(h.trips.routeClears, 1);
    expect(find.text('Add a place'), findsOneWidget,
        reason: 'the sheet stays open for the next place');
    expect(h.google.log, contains('details:p-101'));
    await _settleToasts(tester);
  });

  testWidgets('a place already on that day is refused before Place Details',
      (tester) async {
    final h = await _open(tester, rows: [
      SavedLocation(
        id: 'r1',
        userId: 'u1',
        name: 'Din Tai Fung',
        lat: _spot.latitude,
        lng: _spot.longitude,
        createdAt: _day,
        fingerprint: 'fp',
        placeId: 'p-101',
        scheduledDate: _day,
        tripId: 't1',
      ),
    ]);
    await tester.enterText(
        find.byKey(const ValueKey('add-place-search')), 'din');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Din Tai Fung'));
    await tester.pumpAndSettle();

    expect(h.repo.added, isEmpty);
    expect(find.textContaining('already planned'), findsOneWidget);
    expect(h.google.log.where((l) => l.startsWith('details:')), isEmpty);
    await _settleToasts(tester);
  });

  testWidgets('a pasted link decodes to a place and lands the same way',
      (tester) async {
    final h = await _open(tester, initial: AddPlaceSegment.paste);
    await tester.enterText(find.byKey(const ValueKey('add-place-link')),
        'https://www.google.com/maps/place/Din+Tai+Fung/@25.033,121.53,17z');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add this place'));
    await _confirmTag(tester);

    expect(h.repo.added, hasLength(1));
    expect(h.repo.added.single.name, 'Din Tai Fung');
    expect(h.google.log, contains('coords'));
    await _settleToasts(tester);
  });

  testWidgets('nearby: the list loads around the point, a tick adds it',
      (tester) async {
    final h = await _open(tester,
        initial: AddPlaceSegment.nearby, nearbyCenter: _spot);
    expect(h.google.log.where((l) => l.startsWith('nearby:')), hasLength(1));
    expect(find.text('Din Tai Fung'), findsOneWidget);

    await tester.tap(find.text('Din Tai Fung'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add 1 location'));
    await tester.pumpAndSettle();

    expect(h.repo.added, hasLength(1));
    expect(h.repo.added.single.tripId, 't1');
    expect(find.text('Add a place'), findsNothing,
        reason: 'a nearby batch closes the sheet, as the picker did');
    await _settleToasts(tester);
  });
}
