import 'package:flutter/foundation.dart';

import '../models/location_model.dart';
import '../models/saved_location.dart' show OpeningPeriod;

/// Per-stop timing produced by [simulateTrip].
@immutable
class StopTiming {
  final String locationId;
  /// Wall-clock time the user is expected to arrive at the stop.
  final DateTime arrival;
  /// Wall-clock time the user leaves. Equal to [arrival] + the stop's
  /// `stayDuration`. The simulation does NOT auto-shift to opening time
  /// when a place isn't open yet — it surfaces a warning instead and lets
  /// the user decide whether to reorder.
  final DateTime departure;
  final List<TimingWarning> warnings;

  const StopTiming({
    required this.locationId,
    required this.arrival,
    required this.departure,
    this.warnings = const [],
  });
}

/// Why the simulation flagged a stop. Keep numeric ordering meaningful:
/// higher index = more severe — useful when collapsing multiple warnings
/// into a single visual badge.
enum WarningKind {
  /// Place was open at arrival, but planned stay extends past closing.
  willOverrunClose,

  /// Arrival is before any opening period today; the place will open later.
  notOpenYet,

  /// Arrival is after the last closing today (the place is open today,
  /// just not when the user gets there).
  closedOnArrival,

  /// The place has no open periods at all on the planned weekday.
  closedAllDay,
}

@immutable
class TimingWarning {
  final WarningKind kind;
  /// Short human-readable summary suitable for a per-card badge or
  /// row in the warnings sheet. Callers may compose their own copy from
  /// [kind] + [overrun] / [wait] when they need richer formatting.
  final String message;
  /// How far past close the planned stay extends. Set only when
  /// [kind] is [WarningKind.willOverrunClose].
  final Duration? overrun;
  /// How long the user would wait if they didn't move on. Set only when
  /// [kind] is [WarningKind.notOpenYet].
  final Duration? wait;

  const TimingWarning({
    required this.kind,
    required this.message,
    this.overrun,
    this.wait,
  });
}

/// Aggregate result of a single simulation run.
@immutable
class TimingSimulationResult {
  final List<StopTiming> stops;

  const TimingSimulationResult(this.stops);

  /// True when no stop has any warnings — ready to ship the plan as-is.
  bool get fullyFeasible => stops.every((s) => s.warnings.isEmpty);

  /// All warnings flattened, preserving stop order.
  Iterable<TimingWarning> get allWarnings sync* {
    for (final s in stops) {
      yield* s.warnings;
    }
  }
}

/// Internal: a wall-clock open/close interval anchored to a real date.
@immutable
class _Interval {
  final DateTime open;
  final DateTime close;
  const _Interval(this.open, this.close);
}

/// Pure timing simulator. Walks [orderedStops] in order, accumulates wall-clock
/// arrival/departure for each stop using [legDetails] travel times between
/// consecutive stops, and flags warnings against each stop's effective hours.
///
/// Inputs:
/// - [startWallTime]: when the user starts the trip (e.g. now, or a chosen
///   "Start at" time). Arrival of the first stop = this value verbatim.
/// - [orderedStops]: the routable stops in visit order. Callers should have
///   filtered out skipped/done stops already (the optimizer's output meets
///   this).
/// - [legDetails]: the optimizer's `legDetails` array. Each entry must have a
///   `'duration'` field of type [Duration]. The list length should be
///   `orderedStops.length - 1`; missing legs are treated as zero duration.
///
/// Effective-hours rules (per stop):
/// - `userClosingMinuteOverride != null` → single interval
///   `[firstOpenForDay or 00:00, override]` on the arrival's calendar date.
///   When the override is *before* the opening minute, the override is treated
///   as next-day (after-midnight cutoff).
/// - Else `googleOpeningHours == null` → treated as always-open. No warnings.
/// - Else split & after-midnight aware: any period whose `[open, close]`
///   spans the arrival time produces no warning; otherwise the simulation
///   reports `notOpenYet` (next opening today exists), `closedOnArrival`
///   (after the last closing), or `closedAllDay` (no periods cover this day).
///
/// The function never mutates its inputs and never reads ambient state
/// (current time, providers, etc) — easy to unit test deterministically.
TimingSimulationResult simulateTrip({
  required DateTime startWallTime,
  required List<LocationModel> orderedStops,
  required List<Map<String, dynamic>> legDetails,
}) {
  if (orderedStops.isEmpty) {
    return const TimingSimulationResult([]);
  }

  final out = <StopTiming>[];
  DateTime cursor = startWallTime;

  for (var i = 0; i < orderedStops.length; i++) {
    if (i > 0) {
      final leg = i - 1 < legDetails.length ? legDetails[i - 1] : null;
      final travel = leg?['duration'];
      cursor = cursor
          .add(travel is Duration ? travel : Duration.zero);
    }

    final stop = orderedStops[i];
    final arrival = cursor;
    final stay = stop.stayDuration;
    final departure = arrival.add(stay);

    final warnings = _evaluateStop(stop, arrival, stay);

    out.add(StopTiming(
      locationId: stop.id,
      arrival: arrival,
      departure: departure,
      warnings: warnings,
    ));

    cursor = departure;
  }

  return TimingSimulationResult(out);
}

/// Generates warnings for a single stop given its arrival time and planned
/// stay duration. Returns an empty list when the place is open and the stay
/// fits comfortably within the covering period (or the place is 24/7).
List<TimingWarning> _evaluateStop(
  LocationModel stop,
  DateTime arrival,
  Duration stay,
) {
  final intervals = _buildIntervalsForDate(stop, arrival);

  if (intervals == null) {
    // No effective hours constraint — 24/7 / no data / no override.
    return const [];
  }

  if (intervals.isEmpty) {
    return const [
      TimingWarning(
        kind: WarningKind.closedAllDay,
        message: 'Closed on this day',
      ),
    ];
  }

  // Find a covering interval (arrival is inside [open, close)).
  for (final iv in intervals) {
    if (!arrival.isBefore(iv.open) && arrival.isBefore(iv.close)) {
      final endOfStay = arrival.add(stay);
      if (endOfStay.isAfter(iv.close)) {
        final overrun = endOfStay.difference(iv.close);
        return [
          TimingWarning(
            kind: WarningKind.willOverrunClose,
            message:
                'Stay overruns closing by ${_formatDuration(overrun)}',
            overrun: overrun,
          ),
        ];
      }
      return const [];
    }
  }

  // Not in any interval — find the next one (if any) that opens after arrival.
  _Interval? next;
  for (final iv in intervals) {
    if (iv.open.isAfter(arrival)) {
      if (next == null || iv.open.isBefore(next.open)) next = iv;
    }
  }
  if (next != null) {
    final wait = next.open.difference(arrival);
    return [
      TimingWarning(
        kind: WarningKind.notOpenYet,
        message: 'Not open yet — opens in ${_formatDuration(wait)}',
        wait: wait,
      ),
    ];
  }

  return const [
    TimingWarning(
      kind: WarningKind.closedOnArrival,
      message: 'Closed on arrival',
    ),
  ];
}

/// Builds the wall-clock open/close intervals that could be relevant on
/// [arrival]'s calendar date. Returns:
///   - `null` when the stop has no effective-hours constraint (24/7, no
///     data, no override).
///   - An empty list when there's a constraint but no period covers this
///     day (closed all day).
///   - A list of one or more intervals otherwise.
List<_Interval>? _buildIntervalsForDate(
    LocationModel loc, DateTime arrival) {
  final override = loc.userClosingMinuteOverride;
  final hours = loc.googleOpeningHours;
  final dateOnly = DateTime(arrival.year, arrival.month, arrival.day);

  if (override != null) {
    // User says "treat closing as this time on the planned day". Open from
    // the first Google opening for the day if available, else from 00:00 —
    // this matches the UX of an override meaning "I want to be done by X",
    // not "the place is closed before X."
    final googleDay = _googleDayFor(arrival.weekday);
    final firstOpen =
        hours == null ? 0 : _firstOpenForDay(hours, googleDay) ?? 0;
    final openDt = dateOnly.add(Duration(minutes: firstOpen));
    DateTime closeDt = dateOnly.add(Duration(minutes: override));
    if (override <= firstOpen) {
      // Override expressed as next-day cutoff (e.g. 02:00 close after a
      // 18:00 open) — push close to tomorrow.
      closeDt = closeDt.add(const Duration(days: 1));
    }
    return [_Interval(openDt, closeDt)];
  }

  if (hours == null || hours.isEmpty) return null;
  if (hours.length == 1 && hours.first.isAlwaysOpen) return null;

  final googleDay = _googleDayFor(arrival.weekday);
  final intervals = <_Interval>[];

  // Periods opening today (may close today or any later day).
  for (final p in hours) {
    if (p.openDay != googleDay) continue;
    if (p.closeMinutes == null || p.closeDay == null) continue; // skip open-ended
    final dayOffset = ((p.closeDay! - p.openDay) % 7 + 7) % 7;
    final open = dateOnly.add(Duration(minutes: p.openMinutes));
    final close =
        dateOnly.add(Duration(days: dayOffset, minutes: p.closeMinutes!));
    intervals.add(_Interval(open, close));
  }

  // Period opened the previous day and closes today (after-midnight close
  // from the perspective of the arrival's date).
  final yesterday = dateOnly.subtract(const Duration(days: 1));
  final prevGoogleDay = (googleDay + 6) % 7;
  for (final p in hours) {
    if (p.openDay != prevGoogleDay) continue;
    if (p.closeMinutes == null || p.closeDay == null) continue;
    final dayOffset = ((p.closeDay! - p.openDay) % 7 + 7) % 7;
    if (dayOffset != 1) continue; // we only care about ones that close today
    final open = yesterday.add(Duration(minutes: p.openMinutes));
    final close = dateOnly.add(Duration(minutes: p.closeMinutes!));
    intervals.add(_Interval(open, close));
  }

  return intervals;
}

/// Dart `DateTime.weekday` is 1=Mon..7=Sun. Google's `OpeningPeriod.openDay`
/// is 0=Sun..6=Sat. Storage uses Google's convention; this is the boundary
/// translation.
int _googleDayFor(int dartWeekday) =>
    dartWeekday == DateTime.sunday ? 0 : dartWeekday;

int? _firstOpenForDay(List<OpeningPeriod> hours, int googleDay) {
  int? best;
  for (final p in hours) {
    if (p.openDay != googleDay) continue;
    if (best == null || p.openMinutes < best) best = p.openMinutes;
  }
  return best;
}

String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h > 0 && m > 0) return '${h}h ${m}m';
  if (h > 0) return '${h}h';
  return '${m}m';
}
