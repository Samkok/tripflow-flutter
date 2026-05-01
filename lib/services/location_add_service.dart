import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/location_model.dart';
import '../models/saved_location.dart';
import '../models/trip.dart';
import '../providers/location_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/user_trip_provider.dart';
import '../services/subscription_limit_service.dart';
import '../utils/trip_date_validator.dart';

/// Central service for adding locations.
/// Handles the subscription paywall check before every add so callers
/// don't need to repeat it.
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

  /// Adds a [LocationModel] via the active trip context (map / search flow).
  /// Returns true if the location was added, false if the paywall blocked it
  /// or the user cancelled an out-of-range confirmation.
  Future<bool> addLocation(BuildContext context, LocationModel location) async {
    final canAdd =
        await SubscriptionLimitService(_ref).canAddLocation(context);
    if (!canAdd) return false;

    final activeTrip =
        _ref.read(realtimeActiveTripProvider).asData?.value;
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
  /// Returns true if the location was added, false if the paywall blocked it
  /// or the user cancelled an out-of-range confirmation.
  Future<bool> addSavedLocation(
      BuildContext context, SavedLocation location) async {
    final canAdd =
        await SubscriptionLimitService(_ref).canAddLocation(context);
    if (!canAdd) return false;

    final trip = _findTripById(location.tripId);
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
}
