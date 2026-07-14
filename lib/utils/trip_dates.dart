/// Shared helper for deriving the set of day slots a trip spans.
///
/// VoyZa shows a trip's itinerary day-by-day in several places (the trip
/// detail page, the trip-plan bottom sheet's day-chip strip and "All" tab).
/// Every one of those must show the SAME days, and — crucially — must never
/// drop an empty interstitial day: if a user schedules stops on Jan 1 and
/// Jan 3, Jan 2 still needs a slot so they can drag or add a place into it.
///
/// [contiguousTripDates] is the single source of truth for that: it returns
/// the inclusive, gap-free range from the earliest to the latest date among
/// [marks] (nulls ignored), normalized to midnight. Callers pass the trip's
/// declared start/end plus each location's scheduled start and end; the fill
/// in between guarantees no day is missing, even when the trip has no
/// explicit date range at all.
///
/// Returns an empty list when [marks] contains no non-null date.
List<DateTime> contiguousTripDates(Iterable<DateTime?> marks) {
  DateTime? min;
  DateTime? max;
  for (final raw in marks) {
    if (raw == null) continue;
    final d = DateTime(raw.year, raw.month, raw.day);
    if (min == null || d.isBefore(min)) min = d;
    if (max == null || d.isAfter(max)) max = d;
  }

  final lo = min;
  final hi = max;
  if (lo == null || hi == null) return const <DateTime>[];

  // Step by CALENDAR day (DateTime(y, m, d + 1)) rather than adding a fixed
  // 24h Duration: across a DST transition a 23h/25h day would otherwise drift
  // off local midnight, corrupting date-equality lookups (grouped[date], chip
  // highlighting) and dropping the final day. This always lands on local
  // midnight and rolls month/year boundaries correctly.
  final out = <DateTime>[];
  for (var d = lo; !d.isAfter(hi); d = DateTime(d.year, d.month, d.day + 1)) {
    out.add(d);
  }
  return out;
}
