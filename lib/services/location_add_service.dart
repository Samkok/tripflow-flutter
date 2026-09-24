import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import '../models/location_model.dart';
import '../models/saved_location.dart';
import '../models/trip.dart';
import '../providers/auth_provider.dart';
import '../providers/location_provider.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/subscription_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/user_trip_provider.dart';
import '../services/anonymous_user_service.dart';
import '../services/onboarding_service.dart';
import '../services/places_service.dart';
import '../services/subscription_limit_service.dart';
import '../utils/place_tags.dart';
import '../utils/same_day_place_guard.dart';
import '../utils/trip_date_validator.dart';
import '../utils/trip_dates.dart';
import '../widgets/accommodation_prompts.dart';
import '../widgets/app_toast.dart';
import '../widgets/place_tag_sheet.dart';
import '../utils/trip_day_labels.dart';

/// Central service for adding locations.
///
/// Every add path in the app — search, long-press, nearby picker,
/// trip-detail manual add, and the bulk "Add to Trip" flow — funnels
/// through this service so the gating checks (subscription paywall,
/// scheduled-date guard, and **strict country guard**) live in one place
/// and stay consistent.
///
/// The free-place paywall gate applies only to paths that CREATE a new
/// saved place ([beforeAddingLocation], [addSavedLocation]). The attach
/// paths ([attachLocationsToTrip]) only
/// re-tag rows that already exist and count against the allowance, so
/// they are not gated — otherwise a free user at the limit couldn't
/// organize their own places into trips.
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

  /// Goal-gradient feedback after a NEW place is persisted (create paths
  /// only — attach paths don't consume the allowance). Free users get a
  /// "N of 10 free places used" toast; the very first place ever gets a
  /// warmer nudge toward the 3-place Optimize threshold instead.
  ///
  /// Applies to ANONYMOUS users too (one-time flags keyed to the persistent
  /// device UUID) — they can add places and hit the same gate, so they get
  /// the same goal-gradient feedback pushing them toward the optimize "aha."
  ///
  /// [usedAfter] is captured by the caller BEFORE the repository write
  /// (+1), so it can't race the location stream.
  ///
  /// Callers show their own "Added {name}" toast right after we return, and
  /// [AppToast] replaces rather than stacks — so this one fires on a delay
  /// and lands as the caller's toast wraps up. Best-effort: never throws.
  void _afterSuccessfulNewPlace(BuildContext context, int usedAfter) {
    try {
      if (_ref.read(isProProvider)) return;
      final authUserId = _ref.read(currentUserIdProvider);
      const total = SubscriptionLimitService.freePlaceAllowance;
      final used = usedAfter > total ? total : usedAfter;
      unawaited(() async {
        final userId = authUserId ?? await AnonymousUserService.id;
        final service = OnboardingService.instance;
        final isFirstEver = !await service.hasCelebrated(
            userId, OnboardingMilestone.firstPlace);
        if (isFirstEver) {
          await service.markCelebrated(userId, OnboardingMilestone.firstPlace);
        }
        // The warm "unlock Optimize" nudge only fits when this is genuinely
        // their first place on the board — a sample-trip user already has 5,
        // so they get the meter copy like everyone else.
        final message = (isFirstEver && used == 1)
            ? 'First place saved! ✨ Add 2 more to unlock Optimize'
            : 'Place saved — $used of $total free places used';
        await Future.delayed(const Duration(milliseconds: 1900));
        if (context.mounted) AppToast.info(context, message);
      }());
    } catch (_) {
      // Feedback is cosmetic; never break the add flow over it.
    }
  }

  /// "Sep 14" — or "Day 3" when the row's trip has no dates yet.
  String _dayLabelFor(DateTime day, String? tripId) {
    final trip = _findTripById(tripId) ??
        _ref.read(realtimeActiveTripProvider).valueOrNull;
    return DayLabeler.forTrip(trip)(day);
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
      // (The "where are you staying on the new day?" prompt fires from the
      // add/attach/move/copy sites via _daysWithoutLocations — a day is
      // "new" when it gains its FIRST location, which also covers trips
      // whose range is purely location-derived.)
    } catch (_) {
      // The location add still proceeds even if the trip update fails — the
      // user already confirmed the intent and we don't want to block the add.
    }
  }

  /// Days in `[start..end]` (inclusive, day-keyed) that currently have NO
  /// location on the ACTIVE trip. Captured BEFORE a write; if the write
  /// lands locations on any of them, those days just materialized and the
  /// accommodation prompt should ask about them.
  List<DateTime> _daysWithoutLocations(DateTime start, DateTime? end) {
    final pinned = _ref.read(tripProvider).pinnedLocations;
    final out = <DateTime>[];
    var d = DateTime(start.year, start.month, start.day);
    final last = end == null ? d : DateTime(end.year, end.month, end.day);
    while (!d.isAfter(last)) {
      if (!pinned.any((l) => l.isActiveOnDate(d))) out.add(d);
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return out;
  }

  /// Fires the new-day accommodation prompt when [newDays] is non-empty.
  /// Self-gating beyond that (active-trip match, accommodations exist,
  /// coverage filter) lives in the prompt itself.
  Future<void> _promptAccommodationIfDaysMaterialized(
    BuildContext context,
    Trip? trip,
    List<DateTime> newDays,
  ) async {
    if (trip == null || newDays.isEmpty || !context.mounted) return;
    await maybePromptAccommodationForNewDays(
      context,
      _ref,
      trip: trip,
      newDays: newDays,
    );
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

  /// Google sometimes omits `opening_hours` from a Place Details response
  /// for a place that normally carries them (partial / transient replies),
  /// so a place can land in the trip hour-less even though Google knows its
  /// hours — and the timing warnings, the hours block and the closing-time
  /// checks all go quiet for it. When a NEW row was written without hours,
  /// re-fetch shortly after the add and persist whatever comes back.
  ///
  /// Fire-and-forget: never throws, never blocks the add flow. Two attempts
  /// (3s, then 12s), then give up — some places simply have no hours and
  /// the user can still refresh by hand from the detail sheet. Repository
  /// captured up front: the calling widget (search screen / sheet) may be
  /// disposed by the time the timer fires, and `ref` dies with it.
  void _scheduleHoursBackfill(
    String locationId,
    String? placeId, {
    required bool hasHours,
  }) {
    if (hasHours || placeId == null || placeId.isEmpty) return;
    final repo = _ref.read(locationRepositoryProvider);
    unawaited(() async {
      const delays = [Duration(seconds: 3), Duration(seconds: 12)];
      for (final delay in delays) {
        await Future<void>.delayed(delay);
        try {
          final details = await PlacesService.getPlaceDetails(placeId);
          final hours = details?.openingHours;
          if (hours == null) continue;
          await repo.updateLocation(locationId, {
            'google_opening_hours': hours,
            'hours_last_refreshed_at': DateTime.now(),
          });
          debugPrint('hours backfill: filled hours for $locationId');
          return;
        } catch (e) {
          debugPrint('hours backfill for $locationId failed: $e');
        }
      }
    }());
  }

  /// True when [location] is the same place as a stop already active on its
  /// target day in the active map context — the day it carries, else the
  /// selected day. Occupants are the map's pinned rows: the active trip's
  /// places, or the loose places on a trip-less map. Same identity rule as
  /// every reschedule path ([filterSameDayDuplicates]): place_id, else
  /// name + coordinates.
  bool _isDuplicateOnDay(LocationModel location) {
    final day =
        dayKey(location.scheduledDate ?? _ref.read(selectedDateProvider));
    final occupants = _ref
        .read(tripProvider)
        .pinnedLocations
        .where((l) =>
            l.id != location.id &&
            l.scheduledDate != null &&
            l.isActiveOnDate(day))
        .map(placeKeyOfModel);
    return filterSameDayDuplicates(
      moving: [placeKeyOfModel(location)],
      occupantsOnDay: occupants,
      samePlace: isLikelySamePlace,
    ).allowedIds.isEmpty;
  }

  /// [SavedLocation] twin of [_isDuplicateOnDay] for the trip-page add
  /// flow: occupants are the rows of the SAME trip (null trip = the user's
  /// loose places). An unscheduled add has no day to collide on.
  bool _isSavedDuplicateOnDay(SavedLocation location) {
    final start = location.scheduledDate;
    if (start == null) return false;
    final day = dayKey(start);
    final all = _ref.read(savedLocationsProvider).valueOrNull ??
        const <SavedLocation>[];
    final occupants = all
        .where((l) =>
            l.id != location.id &&
            l.tripId == location.tripId &&
            l.scheduledDate != null &&
            l.isActiveOnDate(day))
        .map(placeKeyOfSaved);
    return filterSameDayDuplicates(
      moving: [placeKeyOfSaved(location)],
      occupantsOnDay: occupants,
      samePlace: isLikelySamePlace,
    ).allowedIds.isEmpty;
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

    /// Batch callers (nearby-places multi-select) run ONE
    /// [SubscriptionLimitService.canAddPlaces] gate up front and pass true
    /// here — otherwise every place past the allowance would pop its own
    /// paywall.
    bool skipLimitCheck = false,

    /// The tag step: every new place gets a tag suggested from its Google
    /// types and confirmed (changed, or declined) by the user before the
    /// write. Callers whose own UI already did that — the nearby picker
    /// shows the chip per row — pass true.
    bool tagConfirmed = false,
  }) async {
    // Same-day duplicate gate — THE shared rule (a place may repeat across
    // a trip's days, never within one), applied here so every add path
    // inherits it. The nearby picker and the inline search had no check of
    // their own, so a place already on the day could be added twice from
    // them. Runs before the paywall: a duplicate must never show an
    // upgrade prompt.
    if (_isDuplicateOnDay(location)) {
      if (context.mounted) {
        final day =
            dayKey(location.scheduledDate ?? _ref.read(selectedDateProvider));
        AppToast.warning(
          context,
          '"${location.name}" is already planned for ${_dayLabelFor(day, location.tripId)}',
        );
      }
      return false;
    }

    if (!skipLimitCheck) {
      final canAdd = await SubscriptionLimitService(_ref).canAddPlace(context);
      if (!canAdd) return false;
    }

    final activeTrip = _ref.read(realtimeActiveTripProvider).valueOrNull;

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
      // An ended trip keeps its dates — no stretching it for a new place.
      allowExtension:
          !tripHasEnded(activeTrip?.endDate ?? activeTrip?.startDate),
    );
    if (!result.proceed) return false;

    // Captured before the write so the toast count can't race the stream.
    // Own places only — collaborators' shared-trip rows don't count.
    final usedAfter = SubscriptionLimitService.ownPlaceCount(_ref) + 1;

    // Captured before the write: the day(s) this location lands on that had
    // no locations yet — if any, a new trip day is materializing and the
    // accommodation prompt should ask about it after the add.
    final DateTime addStart =
        location.scheduledDate ?? _ref.read(selectedDateProvider);
    final newDays =
        _daysWithoutLocations(addStart, location.scheduledEndDate ?? addStart);

    // Add the location BEFORE persisting any trip-date extension. The
    // extension invalidates userTripsProvider, which cascades through
    // localActiveTripProvider into realtimeActiveTripProvider — leaving it
    // in a loading state momentarily. tripProvider.addLocation reads the
    // active trip via that provider to assign tripId, so reordering keeps
    // the new location correctly tagged with its trip.
    if (!context.mounted) return false;
    final toAdd =
        tagConfirmed ? location : await _withConfirmedTag(context, location);
    if (!context.mounted) return false;

    await _ref.read(tripProvider.notifier).addLocation(toAdd);
    _scheduleHoursBackfill(
      location.id,
      location.placeId,
      hasHours: location.googleOpeningHours != null,
    );

    if (activeTrip != null && result.didExtend) {
      await _persistTripDateExtension(activeTrip, result);
    }
    if (context.mounted) _afterSuccessfulNewPlace(context, usedAfter);
    if (context.mounted) {
      await _promptAccommodationIfDaysMaterialized(
          context, activeTrip, newDays);
    }
    return true;
  }

  /// The tag step for a map/search add: the sheet opens with the tag
  /// suggested from the place's Google types; the user confirms it, picks
  /// another, or adds without one. Dismissing the sheet adds without a tag.
  Future<LocationModel> _withConfirmedTag(
      BuildContext context, LocationModel location) async {
    if (!context.mounted) return location.copyWith(tag: null);
    final pick = await showPlaceTagSheet(
      context,
      placeName: location.name,
      suggested: suggestPlaceTag(location.placeTypes),
      current: placeTagFromKey(location.tag),
      placeTypes: location.placeTypes,
    );
    return location.copyWith(tag: pick?.tag?.key);
  }

  /// [_withConfirmedTag] for the trip-page add.
  Future<SavedLocation> _withConfirmedSavedTag(
      BuildContext context, SavedLocation location) async {
    if (!context.mounted) return location.copyWith(tag: null);
    final pick = await showPlaceTagSheet(
      context,
      placeName: location.name,
      suggested: suggestPlaceTag(location.placeTypes ?? const []),
      current: placeTagFromKey(location.tag),
      placeTypes: location.placeTypes,
    );
    return location.copyWith(tag: pick?.tag?.key);
  }

  /// Adds a [SavedLocation] directly to the repository (trip-detail flow).
  /// Same gating rules as [addLocation]; see its doc for [locationCountryCode]
  /// semantics.
  Future<bool> addSavedLocation(
    BuildContext context,
    SavedLocation location, {
    String? locationCountryCode,
    bool tagConfirmed = false,
  }) async {
    // Same-day duplicate gate (see beforeAddingLocation) — scoped to THIS
    // row's trip, since the trip page often isn't the active map trip.
    if (_isSavedDuplicateOnDay(location)) {
      if (context.mounted) {
        AppToast.warning(
          context,
          '"${location.name}" is already planned for ${_dayLabelFor(dayKey(location.scheduledDate!), location.tripId)}',
        );
      }
      return false;
    }

    final canAdd = await SubscriptionLimitService(_ref).canAddPlace(context);
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
      // An ended trip keeps its dates — no stretching it for a new place.
      allowExtension: !tripHasEnded(trip?.endDate ?? trip?.startDate),
    );
    if (!result.proceed) return false;

    // Captured before the write so the toast count can't race the stream.
    // Own places only — collaborators' shared-trip rows don't count.
    final usedAfter = SubscriptionLimitService.ownPlaceCount(_ref) + 1;

    // Captured before the write — see beforeAddingLocation. An unscheduled
    // add materializes no day, so no accommodation prompt can apply.
    final addStart = location.scheduledDate;
    final newDays = addStart == null
        ? const <DateTime>[]
        : _daysWithoutLocations(
            addStart, location.scheduledEndDate ?? addStart);

    // Same ordering rule as [addLocation]: persist the location first so
    // the subsequent userTripsProvider invalidation can't strand it
    // mid-write.
    if (!context.mounted) return false;
    final toAdd = tagConfirmed
        ? location
        : await _withConfirmedSavedTag(context, location);
    if (!context.mounted) return false;
    await _ref.read(locationRepositoryProvider).addLocation(toAdd);
    _scheduleHoursBackfill(
      location.id,
      location.placeId,
      hasHours: location.googleOpeningHours != null,
    );

    if (trip != null && result.didExtend) {
      await _persistTripDateExtension(trip, result);
    }
    if (context.mounted) _afterSuccessfulNewPlace(context, usedAfter);
    if (context.mounted) {
      await _promptAccommodationIfDaysMaterialized(context, trip, newDays);
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
  /// before: userTripsProvider doesn't include
  /// collaborator trips, so an id-based lookup silently skipped both the
  /// country and date checks for shared trips.
  ///
  /// Returns true when at least one location was attached, false when the
  /// country check refused it or the user cancelled the date-extension
  /// dialog.
  Future<bool> attachLocationsToTrip(
    BuildContext context,
    List<SavedLocation> picks,
    Trip targetTrip,
  ) async {
    if (picks.isEmpty) return false;

    // No paywall gate: attaching re-tags existing places; it doesn't
    // consume the free-place allowance.
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

    // Captured before the write: union of every pick's days that have no
    // locations yet — any of them materializing triggers the accommodation
    // prompt below.
    final newDaySet = <DateTime>{};
    for (final pick in picks) {
      // Unscheduled picks land in the bucket — they materialize no day.
      final start = pick.scheduledDate;
      if (start == null) continue;
      newDaySet
          .addAll(_daysWithoutLocations(start, pick.scheduledEndDate ?? start));
    }

    await _ref
        .read(tripProvider.notifier)
        .addLocationsToTrip(picks.map((p) => p.id).toList(), targetTrip.id);

    if (dateConfirm.didExtend) {
      await _persistTripDateExtension(targetTrip, dateConfirm);
    }

    if (context.mounted) {
      await _promptAccommodationIfDaysMaterialized(
          context, targetTrip, newDaySet.toList()..sort());
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

    // An ended trip keeps its dates: the picks go in as they are.
    if (tripHasEnded(tripEnd ?? tripStart)) {
      if (context.mounted) {
        AppToast.info(context,
            '"${trip.name}" has ended — added without changing its dates.');
      }
      return TripDateConfirmResult.allowed;
    }

    // Compute the proposed extended range.
    final newStart = (tripStart == null || earliestOutside!.isBefore(tripStart))
        ? earliestOutside
        : tripStart;
    final newEnd = (tripEnd == null || latestOutside!.isAfter(tripEnd))
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
