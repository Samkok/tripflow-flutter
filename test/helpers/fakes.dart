// Shared stand-ins for widget and provider tests.
//
// Every fake here answers only what the tests need and records what was
// asked of it; anything else falls through to `noSuchMethod` and throws,
// which is the point: a test that reaches an unexpected call fails loudly
// instead of silently exercising production code.
//
// Older tests keep their own private fakes (they are recorders tuned to one
// widget); new tests start from these.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/subscription_provider.dart';
import 'package:voyza/providers/theme_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/repositories/trip_repository.dart';
import 'package:voyza/services/places_gateway.dart';
import 'package:voyza/services/places_service.dart';

/// A [TripNotifier] that holds whatever [TripState] the test hands it and
/// answers no method. Override the ones a test expects in a subclass.
class FakeTripNotifier extends StateNotifier<TripState>
    implements TripNotifier {
  FakeTripNotifier([TripState? state]) : super(state ?? TripState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [ThemeNotifier] pinned to one mode.
class FakeThemeNotifier extends StateNotifier<ThemeMode>
    implements ThemeNotifier {
  FakeThemeNotifier([ThemeMode mode = ThemeMode.dark]) : super(mode);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The "trip on the map" notifier without SharedPreferences. Records every
/// change in [log] as `set:<id>`, `deactivate` or `clear`.
class FakeLocalActiveTripNotifier extends StateNotifier<String?>
    implements LocalActiveTripNotifier {
  FakeLocalActiveTripNotifier([super.initial]);

  final log = <String>[];

  @override
  Future<void> setActiveTrip(String tripId) async {
    log.add('set:$tripId');
    state = tripId;
  }

  @override
  Future<void> deactivateTrip() async {
    log.add('deactivate');
    state = null;
  }

  @override
  Future<void> clear() async {
    log.add('clear');
    state = null;
  }
}

/// An in-memory [TripRepository]: [getUserTrips] returns [trips] whatever
/// the user id, [getTripById] looks one up. Subclass to record writes.
class FakeTripRepository extends Fake implements TripRepository {
  FakeTripRepository([Iterable<Trip> trips = const []]) : trips = [...trips];

  final List<Trip> trips;

  @override
  Future<List<Trip>> getUserTrips(String userId) async => List.of(trips);

  @override
  Future<Trip?> getTripById(String tripId) async {
    for (final t in trips) {
      if (t.id == tripId) return t;
    }
    return null;
  }
}

/// A dated trip with sensible defaults; pass `start: null` for an undated
/// one only when the test builds the anchor dates itself.
Trip sampleTrip({
  String id = 't1',
  String userId = 'u1',
  String name = 'Taipei',
  DateTime? start,
  int days = 3,
  String? countryCode = 'TW',
}) {
  final s = start ?? DateTime(2026, 10, 5);
  return Trip(
    id: id,
    userId: userId,
    name: name,
    startDate: s,
    endDate: DateTime(s.year, s.month, s.day + days - 1),
    countryCode: countryCode,
    createdAt: s,
    updatedAt: s,
  );
}

/// Google, answered from lists: predictions filtered by the query, details
/// by place id, one place for any pasted link, one nearby list. Records
/// what was asked in [log].
class FakePlacesGateway extends PlacesGateway {
  FakePlacesGateway({
    this.predictions = const [],
    this.detailsById = const {},
    this.nearbyPlaces = const [],
    this.linkPlace,
  });

  final List<PlacePrediction> predictions;
  final Map<String, PlaceDetails> detailsById;
  final List<NearbyPlace> nearbyPlaces;
  final PlaceDetails? linkPlace;
  final log = <String>[];

  @override
  Future<List<PlacePrediction>> searchPaginated(
    String query, {
    required int offset,
    required int limit,
    String? countryCodeOverride,
  }) async {
    log.add('search:$query');
    if (offset > 0) return const [];
    final q = query.toLowerCase();
    return predictions
        .where((p) => p.mainText.toLowerCase().contains(q))
        .toList();
  }

  @override
  Future<PlaceDetails?> details(String placeId) async {
    log.add('details:$placeId');
    return detailsById[placeId];
  }

  @override
  Future<PlaceDetails?> fromCoordinates(LatLng coordinates) async {
    log.add('coords');
    return linkPlace;
  }

  @override
  Future<PlaceDetails?> fromAddress(String address) async {
    log.add('address:$address');
    return linkPlace;
  }

  @override
  Future<List<NearbyPlace>> nearby(LatLng center,
      {required int radiusMeters}) async {
    log.add('nearby:$radiusMeters');
    return nearbyPlaces;
  }

  @override
  Future<List<NearbyPlace>> nearbyByText(String query, LatLng center,
      {required int radiusMeters}) async {
    log.add('nearbyText:$query');
    final q = query.toLowerCase();
    return nearbyPlaces.where((p) => p.name.toLowerCase().contains(q)).toList();
  }
}

/// A subscription state that never talks to RevenueCat.
class FakeSubscriptionNotifier extends StateNotifier<SubscriptionState>
    implements SubscriptionNotifier {
  FakeSubscriptionNotifier(
      [SubscriptionState state = const SubscriptionState()])
      : super(state);

  int refreshes = 0;

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<void> refresh({bool skipInit = false}) async => refreshes++;

  @override
  Future<bool> restorePurchases() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
