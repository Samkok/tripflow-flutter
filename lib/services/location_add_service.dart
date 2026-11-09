import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../models/location_model.dart';
import '../models/saved_location.dart';
import '../models/trip.dart';
import '../providers/auth_provider.dart';
import '../providers/local_active_trip_provider.dart';
import '../providers/location_provider.dart';
import '../providers/subscription_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/trip_provider.dart';
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
import '../utils/move_to_trip_rules.dart';
import 'analytics_service.dart';

/// Central service for adding locations.
///
/// Every add door in the app — the add-place sheet's search, nearby and
/// pasted-link segments, and the bulk "Add to Trip" flow — funnels through
/// this service so the gating checks (subscription paywall, scheduled-date
/// guard, and **strict country guard**) live in one place and stay
/// consistent.
///
/// The free-place paywall gate applies only to the path that CREATES a new
/// saved place ([addPlace]). The attach paths ([attachLocationsToTrip]) only
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

  /// [_daysWithoutLocations] for one trip's rows (null = the user's loose
  /// places), read from the saved rows rather than the map's pins so it is
  /// right for a trip that is not the one on the map.
  List<DateTime> _daysWithoutLocationsIn(
      String? tripId, DateTime start, DateTime? end) {
    final rows = (_ref.read(savedLocationsProvider).valueOrNull ??
            const <SavedLocation>[])
        .where((r) => r.tripId == tripId)
        .toList();
    final out = <DateTime>[];
    var d = DateTime(start.year, start.month, start.day);
    final last = end == null ? d : DateTime(end.year, end.month, end.day);
    while (!d.isAfter(last)) {
      if (!rows.any((l) => l.isActiveOnDate(d))) out.add(d);
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

  /// ISO-2 country of a planned place — Place Details when it has a place
  /// id, reverse geocoding otherwise; null when neither answers.
  Future<String?> resolveCountryCodeForModel(LocationModel loc) async {
    final placeId = loc.placeId;
    if (placeId != null && placeId.isNotEmpty) {
      final details = await PlacesService.getPlaceDetails(placeId);
      if (details?.countryCode != null) return details!.countryCode;
    }
    final fallback =
        await PlacesService.getPlaceFromCoordinates(loc.coordinates);
    return fallback?.countryCode;
  }

  /// The country that forbids moving [picks] out of [source] into [target],
  /// or null when the move may proceed. The trips' tags answer first; only
  /// an untagged source costs one lookup per place. See
  /// [moveCountryMismatch] for the rule.
  Future<String?> countryMismatchForMove(
    List<LocationModel> picks,
    Trip target, {
    Trip? source,
  }) async {
    final targetCode = target.countryCode;
    final sourceCode = source?.countryCode;
    if (moveCountrySettledByTags(
        targetCode: targetCode, sourceCode: sourceCode)) {
      return moveCountryMismatch(
        targetCode: targetCode,
        sourceCode: sourceCode,
        locationCodes: const [],
      );
    }
    final codes = await Future.wait(picks.map(resolveCountryCodeForModel));
    return moveCountryMismatch(
      targetCode: targetCode,
      sourceCode: null,
      locationCodes: codes,
    );
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

  /// Same-day duplicate rule for a row about to be written: occupants are
  /// the rows of the SAME trip (null trip = the user's loose places). An
  /// unscheduled add has no day to collide on.
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

  /// THE add path: one place, from any door (search, nearby picker, pasted
  /// link), into [trip] on [day]. Null [trip] = a loose place on a trip-less
  /// map; null [day] = the trip's Unscheduled bucket (no day to collide on,
  /// no day to confirm).
  ///
  /// Runs, once each and in this order: the write-access check for that
  /// trip, the same-day duplicate guard, the free-place paywall (unless the
  /// caller's batch gate ran, [skipLimitCheck]), the strict country guard,
  /// the outside-trip-dates confirmation, the tag step (unless the caller's
  /// UI already confirmed one, [tagConfirmed]), the write, and the
  /// follow-ups (hours backfill, trip-date extension, goal toast,
  /// accommodation prompt). The map's route is cleared at once only when
  /// the place landed on the trip the map shows.
  ///
  /// Returns true when a row was written.
  Future<bool> addPlace(
    BuildContext context,
    PlaceDetails details, {
    required Trip? trip,
    required DateTime? day,
    String? tag,
    bool tagConfirmed = false,
    bool skipLimitCheck = false,
    int stayDurationSeconds = 1800,
  }) async {
    if (trip != null) {
      var allowed = true;
      try {
        allowed = await _ref.read(hasWriteAccessProvider(trip.id).future);
      } catch (_) {
        // Unknown (offline): let the write go; the server's rules decide.
      }
      if (!allowed) {
        if (context.mounted) {
          AppToast.warning(context,
              'You don\'t have permission to add locations to this trip.');
        }
        return false;
      }
    }

    final row = savedLocationFromPlace(
      details,
      id: const Uuid().v4(),
      tripId: trip?.id,
      day: day,
      tag: tagConfirmed ? tag : null,
      stayDurationSeconds: stayDurationSeconds,
    );

    // Same-day duplicate gate first: a duplicate must never show an upgrade
    // prompt.
    if (_isSavedDuplicateOnDay(row)) {
      final label = DayLabeler.forTrip(trip)(dayKey(day!));
      if (!context.mounted) return false;
      AppToast.warning(context, '"${row.name}" is already planned for $label');
      return false;
    }

    if (!context.mounted) return false;
    if (!skipLimitCheck) {
      final canAdd = await SubscriptionLimitService(_ref).canAddPlace(context);
      if (!canAdd) return false;
    }

    if (!context.mounted) return false;
    final countryOk =
        await assertLocationInTripCountry(context, trip, details.countryCode);
    if (!countryOk) return false;

    if (!context.mounted) return false;
    final result = await confirmScheduledDate(
      context,
      trip,
      day,
      // An ended trip keeps its dates — no stretching it for a new place.
      allowExtension: !tripHasEnded(trip?.endDate ?? trip?.startDate),
    );
    if (!result.proceed) return false;

    // Captured before the write so the toast count can't race the stream.
    final usedAfter = SubscriptionLimitService.ownPlaceCount(_ref) + 1;
    // Captured before the write: the day(s) that had no place yet — if any,
    // a trip day is materializing and the accommodation prompt should ask.
    final newDays = day == null
        ? const <DateTime>[]
        : _daysWithoutLocationsIn(trip?.id, day, day);

    if (!context.mounted) return false;
    final toAdd =
        tagConfirmed ? row : await _withConfirmedSavedTag(context, row);
    if (!context.mounted) return false;

    await _ref.read(locationRepositoryProvider).addLocation(toAdd);
    // The map shows this trip (or these loose places): its route is stale
    // now, not when the stream catches up.
    if (trip?.id == _ref.read(localActiveTripIdProvider)) {
      _ref.read(tripProvider.notifier).clearRouteForEdit();
    }
    AnalyticsService.instance.placeAdded(usedAfter);
    _scheduleHoursBackfill(
      toAdd.id,
      toAdd.placeId,
      hasHours: toAdd.googleOpeningHours != null,
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

  /// The tag step: the sheet opens with the tag suggested from the place's
  /// Google types; the user confirms it, picks another, or adds without
  /// one. Dismissing the sheet adds without a tag.
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

/// The saved row for a place Google described — the one shape every add
/// door writes. [day] null leaves the row unscheduled.
SavedLocation savedLocationFromPlace(
  PlaceDetails details, {
  required String id,
  String? tripId,
  DateTime? day,
  String? tag,
  int stayDurationSeconds = 1800,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  return SavedLocation(
    id: id,
    userId: '', // the repository stamps the writer
    fingerprint: '', // and computes this
    name: details.name,
    lat: details.coordinates.latitude,
    lng: details.coordinates.longitude,
    isSkipped: false,
    stayDuration: stayDurationSeconds,
    scheduledDate: day,
    createdAt: at,
    tripId: tripId,
    photoReference: details.photoReference,
    photoReferences:
        details.photoReferences.isEmpty ? null : details.photoReferences,
    photoAttributions: details.photoAttributions,
    placeId: details.placeId,
    originalName: details.name,
    placeTypes: details.types.isEmpty ? null : details.types,
    floor: details.floor,
    tag: tag,
    googleOpeningHours: details.openingHours,
    hoursLastRefreshedAt: details.openingHours != null ? at : null,
  );
}
