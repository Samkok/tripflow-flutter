import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/saved_location.dart';
import '../models/trip.dart';
import '../providers/auth_provider.dart';
import '../providers/location_provider.dart';
import '../providers/user_trip_provider.dart';
import '../utils/fingerprint_utils.dart';
import '../utils/trip_dates.dart';

/// Trips planned before their dates are known ("Day 1, Day 2, …") and the
/// two operations around them: [duplicateTrip] copies a trip onto a chosen
/// start date or leaves the copy undated, [setStartDate] gives an undated
/// trip its real dates by shifting the whole plan. See
/// [tripDatesTbdAnchor] for how an undated trip is stored.
class TripDatesService {
  TripDatesService._();

  /// Gives [trip] real dates: Day 1 becomes [start] and every stop keeps its
  /// day offset. Signed in → one atomic server call (set_trip_dates) plus a
  /// cache refresh; guests → the local rows are shifted here. Works the same
  /// way for rescheduling an already-dated trip. Returns the updated trip.
  static Future<Trip> setStartDate(
      WidgetRef ref, Trip trip, DateTime start) async {
    final trips = ref.read(tripRepositoryProvider);
    final locations = ref.read(locationRepositoryProvider);
    final newStart = dayKey(start);
    final oldStart = dayKey(trip.startDate ?? tripDatesTbdAnchor);
    final oldEnd = dayKey(trip.endDate ?? oldStart);
    final span = daySpanDays(oldStart, oldEnd).clamp(0, 1 << 20);
    final newEnd = shiftTripDay(newStart, span);

    if (ref.read(currentUserIdProvider) != null) {
      await trips.setTripDatesRemote(trip.id, newStart);
      // The rows moved server-side; bring the cache up to date now rather
      // than waiting for the realtime echo.
      await locations.fetchRemoteLocations();
    } else {
      await locations.shiftTripDaysLocally(
          trip.id, daySpanDays(oldStart, newStart));
      await trips.updateTrip(
        trip.id,
        startDate: newStart,
        endDate: newEnd,
        datesTbd: false,
      );
    }
    ref.invalidate(userTripsProvider);
    return trip.copyWith(startDate: newStart, endDate: newEnd, datesTbd: false);
  }

  /// Takes the dates OFF [trip]: Day 1 moves onto the anchor, every stop
  /// keeps its day offset, and the trip reads "No dates yet" until new
  /// dates are set. Signed in → one atomic server call (clear_trip_dates)
  /// plus a cache refresh; guests → the local rows are shifted here.
  /// Returns the updated trip.
  static Future<Trip> clearDates(WidgetRef ref, Trip trip) async {
    final trips = ref.read(tripRepositoryProvider);
    final locations = ref.read(locationRepositoryProvider);
    final anchor = tripDatesTbdAnchor;

    // The current range: declared dates, else the span of the scheduled
    // stops (a legacy trip with no dates still has a Day 1).
    DateTime? earliest;
    DateTime? latest;
    for (final l in ref.read(savedLocationsProvider).valueOrNull ?? const []) {
      if (l.tripId != trip.id) continue;
      final s = l.scheduledDate;
      if (s == null) continue;
      final d = dayKey(s);
      final e = dayKey(l.scheduledEndDate ?? s);
      if (earliest == null || d.isBefore(earliest)) earliest = d;
      if (latest == null || e.isAfter(latest)) latest = e;
    }
    final oldStart = dayKey(trip.startDate ?? earliest ?? DateTime.now());
    final oldEnd = dayKey(trip.endDate ?? latest ?? oldStart);
    final span = daySpanDays(oldStart, oldEnd).clamp(0, 1 << 20);
    final newEnd = shiftTripDay(anchor, span);

    if (ref.read(currentUserIdProvider) != null) {
      await trips.clearTripDatesRemote(trip.id);
      await locations.fetchRemoteLocations();
    } else {
      await locations.shiftTripDaysLocally(
          trip.id, daySpanDays(oldStart, anchor));
      await trips.updateTrip(
        trip.id,
        startDate: anchor,
        endDate: newEnd,
        datesTbd: true,
      );
    }
    ref.invalidate(userTripsProvider);
    return trip.copyWith(startDate: anchor, endDate: newEnd, datesTbd: true);
  }

  /// Name for a duplicate: "Hong Kong (copy)", "Hong Kong (copy 2)", …
  static String copyName(String name, Iterable<String> existingNames) {
    final taken = existingNames.toSet();
    var candidate = '$name (copy)';
    var n = 2;
    while (taken.contains(candidate)) {
      candidate = '$name (copy $n)';
      n++;
    }
    return candidate;
  }

  /// A new trip in the same country with the same stops. The copy keeps
  /// the source's day layout: with [startDate] the source's first day lands
  /// on it and the trip is dated; without one the trip is planned "no dates
  /// yet" (numbered days) for the user to date later. Every stop starts
  /// active; tags, photos, hours, stay flags and durations carry over.
  /// Returns the new trip; the caller has already cleared the free-place
  /// allowance for [sourceLocations].
  static Future<Trip> duplicateTrip(
    WidgetRef ref,
    Trip source,
    List<SavedLocation> sourceLocations, {
    required String newName,
    DateTime? startDate,
  }) async {
    final trips = ref.read(tripRepositoryProvider);
    final locations = ref.read(locationRepositoryProvider);
    final userId = ref.read(currentUserIdProvider) ?? source.userId;

    DateTime? earliest;
    DateTime? latest;
    for (final l in sourceLocations) {
      final s = l.scheduledDate;
      if (s == null) continue;
      final d = dayKey(s);
      final e = dayKey(l.scheduledEndDate ?? s);
      if (earliest == null || d.isBefore(earliest)) earliest = d;
      if (latest == null || e.isAfter(latest)) latest = e;
    }
    final origin = dayKey(source.startDate ?? earliest ?? tripDatesTbdAnchor);
    final last = dayKey(source.endDate ?? latest ?? origin);
    final days = daySpanDays(origin, last).clamp(0, 1 << 20);
    final undated = startDate == null;
    final base = undated ? tripDatesTbdAnchor : dayKey(startDate);

    final trip = await trips.createTrip(
      userId: userId,
      name: newName,
      description: source.description,
      countryCode: source.countryCode,
      startDate: base,
      endDate: shiftTripDay(base, days),
      datesTbd: undated,
    );

    final now = DateTime.now();
    const uuid = Uuid();
    final copies = [
      for (final l in sourceLocations)
        copyStop(
          l,
          id: uuid.v4(),
          tripId: trip.id,
          userId: userId,
          origin: origin,
          base: base,
          days: days,
          now: now,
        ),
    ];
    try {
      await locations.addLocationsBatch(copies);
    } catch (e) {
      debugPrint('TripDatesService.duplicateTrip: copying stops failed: $e');
      rethrow;
    }
    ref.invalidate(userTripsProvider);
    return trip;
  }

  /// The copy of one stop for a duplicated trip: same place, TAG, place
  /// types, photos, hours, stay flag and duration; a fresh id and owner;
  /// done/skipped RESET (a copy starts as a fresh plan); its day = [base]
  /// + its offset from [origin], clamped into the copy's [days]; an
  /// unscheduled stop stays unscheduled.
  @visibleForTesting
  static SavedLocation copyStop(
    SavedLocation l, {
    required String id,
    required String tripId,
    required String userId,
    required DateTime origin,
    required DateTime base,
    required int days,
    required DateTime now,
  }) {
    DateTime? newStart;
    DateTime? newEnd;
    final s = l.scheduledDate;
    if (s != null) {
      final offset = daySpanDays(origin, dayKey(s)).clamp(0, days);
      newStart = shiftTripDay(base, offset);
      final e = l.scheduledEndDate;
      if (e != null) {
        final endOffset = daySpanDays(origin, dayKey(e)).clamp(offset, days);
        if (endOffset > offset) newEnd = shiftTripDay(base, endOffset);
      }
    }
    return SavedLocation(
      id: id,
      userId: userId,
      name: l.name,
      lat: l.lat,
      lng: l.lng,
      createdAt: now,
      // Salted with the new trip: the account sync matches guest rows by
      // fingerprint (name+lat+lng), so an unsalted copy would be taken
      // for the original and dropped on sign-in.
      fingerprint: FingerprintUtils.generateFingerprint(
        name: '${l.name}#$tripId',
        lat: l.lat,
        lng: l.lng,
      ),
      isSkipped: false,
      isDone: false,
      stayDuration: l.stayDuration,
      scheduledDate: newStart,
      scheduledEndDate: newEnd,
      tripId: tripId,
      photoReference: l.photoReference,
      photoReferences: l.photoReferences,
      photoAttributions: l.photoAttributions,
      placeId: l.placeId,
      originalName: l.originalName,
      googleOpeningHours: l.googleOpeningHours,
      userClosingMinuteOverride: l.userClosingMinuteOverride,
      hoursLastRefreshedAt: l.hoursLastRefreshedAt,
      isAccommodation: l.isAccommodation,
      tag: l.tag,
      placeTypes: l.placeTypes,
    );
  }
}
