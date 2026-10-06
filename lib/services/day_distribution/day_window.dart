/// What a trip's arrival and departure times leave of its first and last
/// day. PURE DART (shared by the engine and by the screens that explain
/// the times to the traveller).
library;

import 'dart:math' as math;

import 'distribution_constants.dart';

/// The part of an arrival or departure day that is left for visits.
class DayWindow {
  /// Earliest minute after midnight a visit can begin.
  final int start;

  /// Latest minute after midnight a visit can end.
  final int end;

  /// Visiting minutes the day holds (never above [kDayBudgetMinutes]).
  final int budget;

  /// The arrival cuts the morning off / the departure cuts the evening off.
  final bool startsLate;
  final bool endsEarly;

  const DayWindow({
    required this.start,
    required this.end,
    required this.budget,
    required this.startsLate,
    required this.endsEarly,
  });

  /// False when the day is too short to plan anything on.
  bool get usable => budget >= kMinUsableDayMinutes;
}

/// The window of one trip day, or null when the trip's times leave it a
/// full day. [arrivalMinute] counts on the first day and [departureMinute]
/// on the last (minutes after midnight); a one-day trip is both.
///
/// Visits start [kArrivalBufferMinutes] after the arrival, never before
/// [kDayStartMinute], and end [kDepartureBufferMinutes] before the
/// departure. An arrival day may run past [kDayEndMinute] (a night market
/// is still a fair plan), but its budget only counts the time up to it.
DayWindow? dayWindowFor({
  required bool isFirstDay,
  required bool isLastDay,
  int? arrivalMinute,
  int? departureMinute,
}) {
  var start = kDayStartMinute;
  var end = 24 * 60;
  var countedEnd = kDayEndMinute;
  var startsLate = false;
  var endsEarly = false;
  if (isFirstDay && arrivalMinute != null) {
    final free = arrivalMinute.clamp(0, 1439) + kArrivalBufferMinutes;
    if (free > kDayStartMinute) {
      start = free;
      startsLate = true;
    }
  }
  if (isLastDay && departureMinute != null) {
    end = departureMinute.clamp(0, 1439) - kDepartureBufferMinutes;
    countedEnd = math.min(countedEnd, end);
    endsEarly = true;
  }
  if (!startsLate && !endsEarly) return null;
  final clock = math.max(0, countedEnd - start);
  return DayWindow(
    start: start,
    end: end,
    budget: math.min(kDayBudgetMinutes,
        (clock * kDayBudgetMinutes / kStandardDayClockMinutes).round()),
    startsLate: startsLate,
    endsEarly: endsEarly,
  );
}
