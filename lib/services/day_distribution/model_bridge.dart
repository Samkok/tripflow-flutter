/// Converters between the app's [LocationModel] world and the pure engine
/// types — shared by the auto-plan provider (compute side) and TripNotifier
/// (apply side) so the fingerprint and place-key definitions can never
/// drift between them.
library;

import '../../models/location_model.dart';
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
  );
}
