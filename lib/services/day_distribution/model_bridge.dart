/// Converters between the app's [LocationModel] world and the pure engine
/// types — shared by the auto-plan provider (compute side) and TripNotifier
/// (apply side) so the fingerprint and place-key definitions can never
/// drift between them.
library;

import '../../models/location_model.dart';
import '../../models/saved_location.dart' show OpeningPeriod;
import '../timing_simulation.dart' show kNeverCloses;
import 'distribution_models.dart';

/// PLACE-identity string for the engine's same-day duplicate pre-check.
/// Mirrors same_day_place_guard's `isSamePlace`: Google place id wins,
/// else name @ coordinates. (The authoritative check still re-runs through
/// `_allowedForDay` when a plan is applied — this only stops the engine
/// proposing duplicates.)
String enginePlaceKey(LocationModel l) {
  final pid = l.placeId;
  if (pid != null && pid.isNotEmpty) return 'pid:$pid';
  return 'nm:${l.name.toLowerCase()}'
      '@${l.coordinates.latitude.toStringAsFixed(6)},'
      '${l.coordinates.longitude.toStringAsFixed(6)}';
}

/// Staleness token for a plan: computed over the in-memory rows the plan
/// was built from and re-checked at apply time. A plan whose fingerprint
/// no longer matches the live rows must be recomputed, never applied.
String distributionFingerprint(List<LocationModel> locations) {
  final parts = locations
      .map((l) => '${l.id}|${l.coordinates.latitude}|'
          '${l.coordinates.longitude}|'
          '${l.scheduledDate?.millisecondsSinceEpoch}|'
          '${l.scheduledEndDate?.millisecondsSinceEpoch}|'
          '${l.isSkipped}|${l.isDone}|${l.stayDuration.inMinutes}|'
          '${l.isAccommodation}')
      .toList()
    ..sort();
  return parts.join(';');
}

EnginePlace toEnginePlace(LocationModel l) {
  Set<int>? openWeekdays;
  final hours = l.googleOpeningHours;
  if (hours != null && hours.isNotEmpty) {
    if (hours.any((p) => p.isAlwaysOpen)) {
      openWeekdays = null; // 24/7 — no weekday constraint
    } else {
      openWeekdays = {for (final p in hours) p.openDay};
    }
  }
  return EnginePlace(
    id: l.id,
    name: l.name,
    placeKey: enginePlaceKey(l),
    lat: l.coordinates.latitude,
    lng: l.coordinates.longitude,
    stayMinutes: l.stayDuration.inMinutes,
    scheduledDay: l.scheduledDate,
    scheduledEndDay: l.scheduledEndDate,
    isDone: l.isDone,
    isSkipped: l.isSkipped,
    isAccommodation: l.isAccommodation,
    openWeekdays: openWeekdays,
    openSpans: engineOpenSpans(
      l.googleOpeningHours,
      closingOverride: l.userClosingMinuteOverride,
    ),
  );
}

/// A place's opening hours WITH times, for the days Auto-plan plans by the
/// clock (arrival and departure). Same reading of the data as the day
/// timing simulation (timing_simulation.dart), so the two never disagree:
///  • the traveller's own closing time wins: open from the day's first
///    Google opening (midnight when there is none) until that time, or
///    past midnight when it is not after the opening;
///  • "never closes", no hours, or open around the clock → null: nothing
///    to check;
///  • otherwise one span per Google period, after-midnight closes included.
/// Null also when the periods carry no usable times.
List<OpenSpan>? engineOpenSpans(
  List<OpeningPeriod>? hours, {
  int? closingOverride,
}) {
  const day = 1440;
  if (closingOverride != null) {
    if (closingOverride >= kNeverCloses) return null;
    return [
      for (var d = 0; d < 7; d++)
        () {
          int? first;
          for (final p in hours ?? const <OpeningPeriod>[]) {
            if (p.openDay != d) continue;
            if (first == null || p.openMinutes < first) first = p.openMinutes;
          }
          final open = first ?? 0;
          final close =
              closingOverride <= open ? closingOverride + day : closingOverride;
          return OpenSpan(d * day + open, d * day + close);
        }(),
    ];
  }
  if (hours == null || hours.isEmpty) return null;
  if (hours.any((p) => p.isAlwaysOpen)) return null;
  final spans = <OpenSpan>[];
  for (final p in hours) {
    final closeDay = p.closeDay;
    final closeMinutes = p.closeMinutes;
    if (closeDay == null || closeMinutes == null) continue;
    final start = p.openDay * day + p.openMinutes;
    final end = (p.openDay + (closeDay - p.openDay) % 7) * day + closeMinutes;
    if (end > start) spans.add(OpenSpan(start, end));
  }
  return spans.isEmpty ? null : spans;
}
