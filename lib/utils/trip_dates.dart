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

/// Normalizes any timestamp to its local calendar day (local midnight).
/// The shared day key for grouping, chip highlighting, and day math —
/// always pair with [daySpanDays] instead of `difference().inDays`.
DateTime dayKey(DateTime d) => DateTime(d.year, d.month, d.day);

/// Calendar days from [from] to [to] (positive when [to] is later), immune
/// to DST: `difference().inDays` between local midnights truncates across a
/// spring-forward (23h day), shifting every rescheduled place a day early.
/// Comparing the dates in UTC removes the offset change from the math.
int daySpanDays(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

/// When a row with a stay range moves to [newStart], its end must move with
/// it — writing only the start leaves `start > end`, and `isActiveOnDate`
/// then matches NO day at all (the row vanishes from every list). Returns
/// the new end preserving the stay's calendar length, or null when the row
/// has no forward span (callers should write that null to clear any stale
/// stored end).
DateTime? shiftedSpanEnd({
  required DateTime oldStart,
  required DateTime? oldEnd,
  required DateTime newStart,
}) {
  if (oldEnd == null) return null;
  final span = daySpanDays(dayKey(oldStart), dayKey(oldEnd));
  if (span <= 0) return null;
  final ns = dayKey(newStart);
  return DateTime(ns.year, ns.month, ns.day + span);
}

// ── Trips without dates yet ─────────────────────────────────────────────
//
// A trip can be planned before its dates are known. Nothing date-keyed
// changes for that: the trip just sits on a far-future anchor — Day 1 is
// [tripDatesTbdAnchor], Day N is anchor + (N - 1) — and `Trip.datesTbd`
// tells every surface to print "Day N" instead of a calendar date and to
// hide weekday-dependent hints. Setting the real start date is one shift
// of the whole plan (server: set_trip_dates(); guests: [shiftTripDay]).
// The anchor is far in the future so no undated plan is ever "past" or
// due (rollover, past-trip locks).

/// Day 1 of every trip whose dates are still to be decided.
final DateTime tripDatesTbdAnchor = DateTime(2100, 1, 1);

/// True once [last] (a trip's last day) is a calendar day before today —
/// the trip has ended. An ended trip keeps its dates: no rescheduling, no
/// adding or removing days, no extending it to fit a new place; places
/// can still be added to the days it had.
bool tripHasEnded(DateTime? last, {DateTime? today}) {
  if (last == null) return false;
  final t = dayKey(today ?? DateTime.now());
  return dayKey(last).isBefore(t);
}

/// True when [day] sits on the undated-trip anchor year — for surfaces
/// that only have a date in hand (auto-plan cards, the copy preview) and
/// no trip flag. The anchor year is reserved for numbered days.
bool isOnTbdAnchor(DateTime day) => day.year >= tripDatesTbdAnchor.year;

/// 1-based day number of [date] within a trip whose Day 1 is [start]
/// (both taken as calendar days; DST-safe).
int tripDayNumber(DateTime start, DateTime date) =>
    daySpanDays(dayKey(start), dayKey(date)) + 1;

/// "Day 3" — the label undated trips use where dated ones show a date.
String tripDayLabel(DateTime start, DateTime date) =>
    'Day ${tripDayNumber(start, date)}';

/// Calendar day [days] after [day], landing on local midnight regardless
/// of DST (a fixed 24h Duration would drift across a transition). Negative
/// [days] moves earlier.
DateTime shiftTripDay(DateTime day, int days) {
  final k = dayKey(day);
  return DateTime(k.year, k.month, k.day + days);
}
