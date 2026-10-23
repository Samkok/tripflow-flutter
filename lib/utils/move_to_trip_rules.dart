import '../models/trip.dart';
import 'trip_dates.dart';

/// Rules for moving planned places from one trip to another, kept pure so
/// the sheet, the service and the tests agree on them.

String? _norm(String? code) {
  final c = code?.trim().toUpperCase();
  return (c == null || c.isEmpty) ? null : c;
}

/// The country that forbids the move, or null when it may go ahead.
///
/// A target without a tagged country takes anything. A tagged SOURCE trip
/// settles the question for every place in it (the strict add guard kept
/// them in that country): same tag → allowed, different tag → that country
/// is the answer. Only an untagged source needs the places' own countries;
/// a place whose country is unknown is let through, as on add.
String? moveCountryMismatch({
  required String? targetCode,
  required String? sourceCode,
  required Iterable<String?> locationCodes,
}) {
  final target = _norm(targetCode);
  if (target == null) return null;
  final source = _norm(sourceCode);
  if (source != null) return source == target ? null : source;
  for (final raw in locationCodes) {
    final code = _norm(raw);
    if (code != null && code != target) return code;
  }
  return null;
}

/// True when [moveCountryMismatch] can answer from the trip tags alone,
/// without looking any place up: the target is untagged, or the source
/// trip is tagged.
bool moveCountrySettledByTags({
  required String? targetCode,
  required String? sourceCode,
}) =>
    _norm(targetCode) == null || _norm(sourceCode) != null;

/// Trips the places may move to: every candidate except the one they are
/// in, de-duplicated, trips still to come first (by start date), then the
/// ones already over; within a group, undated trips follow the dated ones,
/// by name.
List<Trip> moveTargetTrips(
  Iterable<Trip> candidates, {
  required String? exceptTripId,
  DateTime? today,
}) {
  final seen = <String>{};
  final out = <Trip>[];
  for (final t in candidates) {
    if (t.id == exceptTripId || !seen.add(t.id)) continue;
    out.add(t);
  }
  int group(Trip t) =>
      tripHasEnded(t.endDate ?? t.startDate, today: today) ? 1 : 0;
  out.sort((a, b) {
    final g = group(a).compareTo(group(b));
    if (g != 0) return g;
    final da = a.isUndated ? null : a.startDate;
    final db = b.isUndated ? null : b.startDate;
    if (da != null && db != null) {
      final c = da.compareTo(db);
      if (c != 0) return c;
    } else if (da != null) {
      return -1;
    } else if (db != null) {
      return 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

/// The days a moved place can land on in [target]: its declared range, day
/// by day. Empty when the trip has no dates, so only "Unscheduled" remains.
List<DateTime> moveTargetDays(Trip target) =>
    contiguousTripDates([target.startDate, target.endDate]);
