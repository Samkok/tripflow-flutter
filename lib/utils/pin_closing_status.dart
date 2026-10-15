import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/location_model.dart';
import '../services/timing_simulation.dart';

/// What a stop's pin says about its opening hours right now, or at the
/// moment the traveller is expected to reach it.
///
/// Four states, two colours (Sam's rule, 2026-10-15):
///   * closed now            → red,    "Already closed at 6:00 PM" /
///                                       "Closed today"
///   * closing within 30 min → yellow, "Closes in 25 min"
///   * closed on arrival     → red,    "Closed on arrival"
///   * closing within 30 min
///     of arrival            → yellow, "Closes 25 min after arrival"
///   * not open yet          → yellow, "Opens at 10:00 AM" /
///                                       "Not open on arrival · Opens at …"
/// Arrival wins over now when it is known and still ahead.
enum PinClosingKind {
  none,
  closed,
  closingSoon,
  closedOnArrival,
  closingSoonAfterArrival,
  notOpenYet,
}

/// "About to close" means this close or closer.
const Duration nearCloseWindow = Duration(minutes: 30);

@immutable
class PinClosingStatus {
  const PinClosingStatus(this.kind, this.line);

  static const none = PinClosingStatus(PinClosingKind.none, '');

  final PinClosingKind kind;

  /// The line under the pin's name; empty for [PinClosingKind.none].
  final String line;

  bool get isNone => kind == PinClosingKind.none;

  bool get isRed =>
      kind == PinClosingKind.closed || kind == PinClosingKind.closedOnArrival;

  /// Text colour for the pin's name and the line: red for closed, yellow
  /// for closing soon.
  Color get color => isRed ? closedRed : closingYellow;

  static const Color closedRed = Color(0xFFFF5252);
  static const Color closingYellow = Color(0xFFFFD740);

  @override
  bool operator ==(Object other) =>
      other is PinClosingStatus && other.kind == kind && other.line == line;

  @override
  int get hashCode => Object.hash(kind, line);

  @override
  String toString() => 'PinClosingStatus($kind, "$line")';
}

/// The pin status for [loc].
///
/// [arrival] is when the traveller is expected at the stop (the plan's
/// simulated arrival, or the ETA of a route from the device); it counts
/// only while it is still ahead of [now] — a plan the traveller has fallen
/// behind says nothing about the place. [todayView] is whether the map is
/// showing today's plan: the "now" rules apply to today only, a future
/// day's pins are judged by their planned arrival alone.
PinClosingStatus pinClosingStatus({
  required LocationModel loc,
  required DateTime now,
  DateTime? arrival,
  required bool todayView,
  Duration near = nearCloseWindow,
}) {
  if (loc.isAccommodation) return PinClosingStatus.none;
  final DateTime at;
  final bool onArrival;
  if (arrival != null && arrival.isAfter(now)) {
    at = arrival;
    onArrival = true;
  } else if (todayView) {
    at = now;
    onArrival = false;
  } else {
    return PinClosingStatus.none;
  }

  final intervals = effectiveHoursIntervalsOn(loc, at);
  if (intervals == null) return PinClosingStatus.none; // 24/7 or unknown
  if (intervals.isEmpty) {
    return onArrival
        ? const PinClosingStatus(
            PinClosingKind.closedOnArrival, 'Closed on arrival')
        : PinClosingStatus(
            PinClosingKind.closed, 'Closed today${_opensNext(loc, at)}');
  }

  HoursInterval? cover;
  for (final iv in intervals) {
    if (iv.covers(at)) {
      if (cover == null || iv.close.isAfter(cover.close)) cover = iv;
    }
  }
  if (cover != null) {
    final remaining = cover.close.difference(at);
    if (remaining > near) return PinClosingStatus.none;
    final mins = remaining.inMinutes < 1 ? 1 : remaining.inMinutes;
    return onArrival
        ? PinClosingStatus(PinClosingKind.closingSoonAfterArrival,
            'Closes $mins min after arrival')
        : PinClosingStatus(PinClosingKind.closingSoon, 'Closes in $mins min');
  }

  // Not open at [at] but opening later today (the morning, or a midday
  // break): yellow, with the time the doors open.
  HoursInterval? next;
  for (final iv in intervals) {
    if (iv.open.isAfter(at) && (next == null || iv.open.isBefore(next.open))) {
      next = iv;
    }
  }
  if (next != null) {
    final opens = 'Opens at ${DateFormat.jm().format(next.open)}';
    return PinClosingStatus(PinClosingKind.notOpenYet,
        onArrival ? 'Not open on arrival · $opens' : opens);
  }
  DateTime? lastClose;
  for (final iv in intervals) {
    if (lastClose == null || iv.close.isAfter(lastClose)) lastClose = iv.close;
  }
  if (onArrival) {
    return const PinClosingStatus(
        PinClosingKind.closedOnArrival, 'Closed on arrival');
  }
  final when =
      lastClose == null ? '' : ' at ${DateFormat.jm().format(lastClose)}';
  return PinClosingStatus(
      PinClosingKind.closed, 'Already closed$when${_opensNext(loc, at)}');
}

/// " · Opens at 10:00 AM" for the place's next opening after [after]
/// (tomorrow), " · Opens Fri at 10:00 AM" when it is further off, '' when
/// nothing opens within a week. The closed pin then says when to come
/// back, not only that it is too late.
String _opensNext(LocationModel loc, DateTime after) {
  final next = nextOpeningAfter(loc, after);
  if (next == null) return '';
  final time = DateFormat.jm().format(next);
  final day = DateTime(after.year, after.month, after.day);
  final nextDay = DateTime(next.year, next.month, next.day);
  final daysAhead = nextDay.difference(day).inDays;
  if (daysAhead <= 1) return ' · Opens at $time';
  return ' · Opens ${DateFormat.E().format(next)} at $time';
}

/// The first moment the place opens after [after], looking a week ahead
/// through Google's opening periods; null when the place has no opening
/// hours (nothing to promise) or never closes. Google's periods, not the
/// effective intervals: the user's closing override says when THEY want
/// to be done, and the planner models it as "open from the first opening
/// (or midnight) until then" — not a statement about when doors open.
DateTime? nextOpeningAfter(LocationModel loc, DateTime after) {
  final hours = loc.googleOpeningHours;
  if (hours == null || hours.isEmpty) return null;
  if (hours.any((p) => p.isAlwaysOpen)) return null;
  for (var d = 0; d <= 7; d++) {
    final day = DateTime(after.year, after.month, after.day + d);
    final googleDay = day.weekday % 7; // Sunday = 0 … Saturday = 6
    DateTime? best;
    for (final p in hours) {
      if (p.openDay != googleDay) continue;
      final open = day.add(Duration(minutes: p.openMinutes));
      if (!open.isAfter(after)) continue;
      if (best == null || open.isBefore(best)) best = open;
    }
    if (best != null) return best;
  }
  return null;
}
