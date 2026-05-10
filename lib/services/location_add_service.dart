import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/location_model.dart';
import '../models/saved_location.dart';
import '../models/trip.dart';
import '../providers/location_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/user_trip_provider.dart';
import '../services/places_service.dart';
import '../services/subscription_limit_service.dart';
import '../utils/trip_date_validator.dart';

/// Central service for adding locations.
///
/// Every add path in the app — search, long-press, nearby picker,
/// trip-detail manual add, and the bulk "Add to Trip" flow — funnels
/// through this service so the gating checks (subscription paywall,
/// scheduled-date guard, and **strict country guard**) live in one place
/// and stay consistent.
///
/// The country guard is hard-blocking: when the active trip has a tagged
/// country and the candidate location's country is known to differ, the
/// add is refused outright with a single-button dialog. Locations whose
/// country we cannot determine (manual coord, no place_id) are allowed
/// through to avoid making those entry points unreachable.
class LocationAddService {
  final WidgetRef _ref;

  LocationAddService(this._ref);

  Trip? _findTripById(String? tripId) {
    if (tripId == null) return null;
    final trips = _ref.read(userTripsProvider).asData?.value ?? const [];
    for (final t in trips) {
      if (t.id == tripId) return t;
    }
    return null;
  }

  Future<void> _persistTripDateExtension(
    Trip trip,
    TripDateConfirmResult result,
  ) async {
    if (!result.didExtend) return;
    final newStart = result.extendedStart ?? trip.startDate;
    final newEnd = result.extendedEnd ?? trip.endDate;
    try {
      await _ref.read(tripRepositoryProvider).updateTrip(
            trip.id,
            startDate: newStart,
            endDate: newEnd,
          );
      // Refresh anything reading trip data so the extended range shows up
      // immediately on cards and detail headers.
      _ref.invalidate(userTripsProvider);
    } catch (_) {
      // The location add still proceeds even if the trip update fails — the
      // user already confirmed the intent and we don't want to block the add.
    }
  }

  /// Best-effort lookup of a location's ISO-2 country code, used by the
  /// bulk "Add to Trip" path where the saved rows don't have a country
  /// stored. Prefers a single Place Details call (cheap + exact) when we
  /// have a placeId, falling back to reverse geocoding from coordinates
  /// for legacy rows that don't.
  Future<String?> _resolveCountryCodeForSaved(SavedLocation loc) async {
    if (loc.placeId != null && loc.placeId!.isNotEmpty) {
      final details = await PlacesService.getPlaceDetails(loc.placeId!);
      if (details?.countryCode != null) return details!.countryCode;
    }
    final fallback =
        await PlacesService.getPlaceFromCoordinates(LatLng(loc.lat, loc.lng));
    return fallback?.countryCode;
  }

  /// Adds a [LocationModel] via the active trip context (map / search flow).
  /// Returns true if the location was added; false if the paywall blocked
  /// it, the user cancelled the date confirmation, or the strict country
  /// guard refused it.
  ///
  /// Pass [locationCountryCode] (e.g. `placeDetails.countryCode`) so the
  /// guard can compare against the active trip's tagged country. Omit it
  /// only when the country is genuinely unknown — passing null disables
  /// the check rather than failing closed.
  Future<bool> beforeAddingLocation(
    BuildContext context,
    LocationModel location, {
    String? locationCountryCode,
  }) async {
    final canAdd = await SubscriptionLimitService(_ref).canCreate(context);
    if (!canAdd) return false;

    final activeTrip =
        _ref.read(realtimeActiveTripProvider).asData?.value;

    if (!context.mounted) return false;
    final countryOk = await assertLocationInTripCountry(
      context,
      activeTrip,
      locationCountryCode,
    );
    if (!countryOk) return false;

    if (!context.mounted) return false;
    final result = await confirmScheduledDate(
      context,
      activeTrip,
      location.scheduledDate,
      allowExtension: true,
    );
    if (!result.proceed) return false;

    // Add the location BEFORE persisting any trip-date extension. The
    // extension invalidates userTripsProvider, which cascades through
    // localActiveTripProvider into realtimeActiveTripProvider — leaving it
    // in a loading state momentarily. tripProvider.addLocation reads the
    // active trip via that provider to assign tripId, so reordering keeps
    // the new location correctly tagged with its trip.
    await _ref.read(tripProvider.notifier).addLocation(location);

    if (activeTrip != null && result.didExtend) {
      await _persistTripDateExtension(activeTrip, result);
    }
    return true;
  }

  /// Adds a [SavedLocation] directly to the repository (trip-detail flow).
  /// Same gating rules as [addLocation]; see its doc for [locationCountryCode]
  /// semantics.
  Future<bool> addSavedLocation(
    BuildContext context,
    SavedLocation location, {
    String? locationCountryCode,
  }) async {
    final canAdd = await SubscriptionLimitService(_ref).canCreate(context);
    if (!canAdd) return false;

    final trip = _findTripById(location.tripId);

    if (!context.mounted) return false;
    final countryOk = await assertLocationInTripCountry(
      context,
      trip,
      locationCountryCode,
    );
    if (!countryOk) return false;

    if (!context.mounted) return false;
    final result = await confirmScheduledDate(
      context,
      trip,
      location.scheduledDate,
      allowExtension: true,
    );
    if (!result.proceed) return false;

    // Same ordering rule as [addLocation]: persist the location first so
    // the subsequent userTripsProvider invalidation can't strand it
    // mid-write.
    await _ref.read(locationRepositoryProvider).addLocation(location);

    if (trip != null && result.didExtend) {
      await _persistTripDateExtension(trip, result);
    }
    return true;
  }

  /// Bulk path used by AddToTripSheet. Resolves each pick's country on the
  /// fly (since SavedLocation doesn't store one), runs the strict country
  /// guard against [tripId]'s tagged country, then attaches every pick
  /// that survived the check via [TripNotifier.addLocationsToTrip].
  ///
  /// Returns true when at least one location was attached, false when
  /// nothing survived (and the dialog was shown for the first mismatch)
  /// or the paywall blocked it.
  Future<bool> attachLocationsToTrip(
    BuildContext context,
    List<SavedLocation> picks,
    String tripId,
  ) async {
    if (picks.isEmpty) return false;

    final canAdd = await SubscriptionLimitService(_ref).canCreate(context);
    if (!canAdd) return false;

    final trip = _findTripById(tripId);

    final tripCode = trip?.countryCode;
    if (tripCode != null) {
      final codes = await Future.wait(picks.map(_resolveCountryCodeForSaved));
      final mismatchIdx = codes.indexWhere(
          (c) => c != null && c.toUpperCase() != tripCode.toUpperCase());
      if (mismatchIdx != -1) {
        if (!context.mounted) return false;
        await assertLocationInTripCountry(context, trip, codes[mismatchIdx]);
        return false;
      }
    }

    await _ref
        .read(tripProvider.notifier)
        .addLocationsToTrip(picks.map((p) => p.id).toList(), tripId);
    return true;
  }
}
