import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
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

  /// Attaches an already-persisted [location] to [targetTrip]. Used by
  /// the trip-details "Add existing location" flow, where the user is
  /// looking at a specific (often non-active) trip and wants to move an
  /// unassigned location into it.
  ///
  /// Takes the [Trip] object directly rather than looking it up by id.
  /// userTripsProvider only returns trips OWNED by the user (`.eq('user_id'…)`)
  /// — collaborator trips aren't in it, and even owner trips may be in a
  /// transient loading state. Either case would cause `_findTripById` to
  /// return null and silently skip the date check. The caller in
  /// trip_details_screen already has [widget.trip], so this signature
  /// removes that footgun entirely.
  ///
  /// Behavior on confirmation:
  ///   - User cancels → returns false, nothing changes.
  ///   - User confirms with "Add anyway" and the date is out of range →
  ///     extends the target trip's start/end to fit, then attaches.
  ///   - In-range or trip has no range → attaches immediately.
  Future<bool> attachExistingLocationToTrip(
    BuildContext context,
    SavedLocation location,
    Trip targetTrip, {
    String? locationCountryCode,
  }) async {
    final canAdd = await SubscriptionLimitService(_ref).canCreate(context);
    if (!canAdd) return false;

    if (!context.mounted) return false;
    final countryOk = await assertLocationInTripCountry(
      context,
      targetTrip,
      locationCountryCode,
    );
    if (!countryOk) return false;

    if (!context.mounted) return false;
    final result = await confirmScheduledDate(
      context,
      targetTrip,
      location.scheduledDate,
      allowExtension: true,
    );
    if (!result.proceed) return false;

    // Attach first — userTripsProvider invalidation from the date extension
    // would otherwise put the trip in a transient loading state and could
    // race the repository write.
    await _ref
        .read(locationRepositoryProvider)
        .updateLocation(location.id, {'trip_id': targetTrip.id});

    if (result.didExtend) {
      await _persistTripDateExtension(targetTrip, result);
    }
    return true;
  }

  /// Bulk path used by AddToTripSheet. Resolves each pick's country on the
  /// fly (since SavedLocation doesn't store one), runs the strict country
  /// guard against [targetTrip]'s tagged country, then attaches every pick
  /// that survived the check via [TripNotifier.addLocationsToTrip].
  ///
  /// Also runs a bulk date-range confirmation: when one or more picks have
  /// a scheduledDate outside the trip's start/end range, the user is asked
  /// to confirm extending the trip dates to cover everything. On confirm,
  /// trip.startDate / trip.endDate are widened to min/max of the affected
  /// dates before the attach lands.
  ///
  /// Takes [targetTrip] as a [Trip] object rather than an id — same reason
  /// as [attachExistingLocationToTrip]: userTripsProvider doesn't include
  /// collaborator trips, so an id-based lookup silently skipped both the
  /// country and date checks for shared trips.
  ///
  /// Returns true when at least one location was attached, false when the
  /// paywall blocked it, the country check refused it, or the user
  /// cancelled the date-extension dialog.
  Future<bool> attachLocationsToTrip(
    BuildContext context,
    List<SavedLocation> picks,
    Trip targetTrip,
  ) async {
    if (picks.isEmpty) return false;

    final canAdd = await SubscriptionLimitService(_ref).canCreate(context);
    if (!canAdd) return false;

    final tripCode = targetTrip.countryCode;
    if (tripCode != null) {
      final codes = await Future.wait(picks.map(_resolveCountryCodeForSaved));
      final mismatchIdx = codes.indexWhere(
          (c) => c != null && c.toUpperCase() != tripCode.toUpperCase());
      if (mismatchIdx != -1) {
        if (!context.mounted) return false;
        await assertLocationInTripCountry(
            context, targetTrip, codes[mismatchIdx]);
        return false;
      }
    }

    if (!context.mounted) return false;
    final dateConfirm = await _confirmBulkDateRange(context, targetTrip, picks);
    if (!dateConfirm.proceed) return false;

    await _ref
        .read(tripProvider.notifier)
        .addLocationsToTrip(picks.map((p) => p.id).toList(), targetTrip.id);

    if (dateConfirm.didExtend) {
      await _persistTripDateExtension(targetTrip, dateConfirm);
    }

    return true;
  }

  /// Inspects every pick's scheduledDate against [trip]'s range and, when
  /// any fall outside, asks the user whether to widen the trip dates to
  /// cover them. The dialog wording mirrors [confirmScheduledDate]'s
  /// "Outside trip dates" message but speaks in plural / range terms since
  /// multiple picks can extend the trip in either direction at once.
  ///
  /// Returns:
  ///   - [TripDateConfirmResult.allowed] when there's nothing to flag
  ///     (trip has no range, no picks have dates, or all are in range).
  ///   - [TripDateConfirmResult.cancelled] when the user cancels.
  ///   - A `proceed: true` result with `extendedStart`/`extendedEnd` set
  ///     to the min/max out-of-range dates when the user confirms.
  Future<TripDateConfirmResult> _confirmBulkDateRange(
    BuildContext context,
    Trip trip,
    List<SavedLocation> picks,
  ) async {
    final start = trip.startDate;
    final end = trip.endDate;
    if (start == null && end == null) return TripDateConfirmResult.allowed;

    DateTime atMidnight(DateTime d) => DateTime(d.year, d.month, d.day);

    final tripStart = start != null ? atMidnight(start) : null;
    final tripEnd = end != null ? atMidnight(end) : null;

    DateTime? earliestOutside;
    DateTime? latestOutside;
    int outsideCount = 0;
    for (final p in picks) {
      final d = p.scheduledDate;
      if (d == null) continue;
      final day = atMidnight(d);
      final before = tripStart != null && day.isBefore(tripStart);
      final after = tripEnd != null && day.isAfter(tripEnd);
      if (!before && !after) continue;
      outsideCount++;
      if (earliestOutside == null || day.isBefore(earliestOutside)) {
        earliestOutside = day;
      }
      if (latestOutside == null || day.isAfter(latestOutside)) {
        latestOutside = day;
      }
    }

    if (outsideCount == 0) return TripDateConfirmResult.allowed;

    // Compute the proposed extended range.
    final newStart =
        (tripStart == null || earliestOutside!.isBefore(tripStart))
            ? earliestOutside
            : tripStart;
    final newEnd =
        (tripEnd == null || latestOutside!.isAfter(tripEnd))
            ? latestOutside
            : tripEnd;

    final fmt = DateFormat('MMM d, y');
    final currentRange = (tripStart != null && tripEnd != null)
        ? '${fmt.format(tripStart)} – ${fmt.format(tripEnd)}'
        : (tripStart != null
            ? 'starting ${fmt.format(tripStart)}'
            : 'ending ${fmt.format(tripEnd!)}');
    final newRange = (newStart != null && newEnd != null)
        ? '${fmt.format(newStart)} – ${fmt.format(newEnd)}'
        : (newStart != null
            ? 'starting ${fmt.format(newStart)}'
            : 'ending ${fmt.format(newEnd!)}');

    if (!context.mounted) return TripDateConfirmResult.cancelled;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.event_busy_rounded, color: Colors.orange),
            SizedBox(width: 12),
            Expanded(child: Text('Outside trip dates')),
          ],
        ),
        content: Text(
          '$outsideCount location${outsideCount == 1 ? '' : 's'} '
          '${outsideCount == 1 ? 'falls' : 'fall'} outside "${trip.name}" '
          '($currentRange).\n\n'
          'If you continue, the trip dates will update to $newRange.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add anyway'),
          ),
        ],
      ),
    );
    if (proceed != true) return TripDateConfirmResult.cancelled;

    return TripDateConfirmResult(
      proceed: true,
      // Only mark the side as extended when it actually moved.
      extendedStart: (tripStart == null || earliestOutside!.isBefore(tripStart))
          ? earliestOutside
          : null,
      extendedEnd: (tripEnd == null || latestOutside!.isAfter(tripEnd))
          ? latestOutside
          : null,
    );
  }
}
