import '../models/location_model.dart';
import '../models/saved_location.dart';

/// The identity of a place for duplicate purposes, independent of which
/// model (map-side [LocationModel] / repository-side [SavedLocation]) or
/// row it came from. Every location row has its own unique id — "the same
/// place twice" therefore means two rows that resolve to the same
/// [PlaceKey], which IS allowed within a trip, just never on the same day.
typedef PlaceKey = ({
  String id,
  String? placeId,
  String name,
  double lat,
  double lng,
});

PlaceKey placeKeyOfSaved(SavedLocation l) => (
      id: l.id,
      placeId: l.placeId,
      name: l.name,
      lat: l.lat,
      lng: l.lng,
    );

PlaceKey placeKeyOfModel(LocationModel l) => (
      id: l.id,
      placeId: l.placeId,
      name: l.name,
      lat: l.coordinates.latitude,
      lng: l.coordinates.longitude,
    );

/// Same PLACE (not same row): matching non-empty Google place id, else the
/// same name at the same coordinates.
bool isSamePlace(PlaceKey a, PlaceKey b) {
  if (a.placeId != null && a.placeId!.isNotEmpty && a.placeId == b.placeId) {
    return true;
  }
  return a.name.toLowerCase() == b.name.toLowerCase() &&
      (a.lat - b.lat).abs() < 1e-6 &&
      (a.lng - b.lng).abs() < 1e-6;
}

/// THE same-day duplicate gate — every path that schedules a place onto a
/// day (drag, move, copy, date edit, add, day removal, trip shift) runs its
/// candidates through here so the rule can never drift per-surface:
/// a place may repeat across a trip's days, but never within one day.
///
/// [moving] are the candidates headed for the day; [occupantsOnDay] is
/// everything already active on that day EXCLUDING the moving rows
/// themselves (a row "moving" onto a day it already occupies is a no-op,
/// not a duplicate). Duplicates *within* [moving] are also collapsed —
/// the first of each place passes, the rest are blocked.
///
/// Returns the ids that may proceed and the display names that were
/// blocked.
({Set<String> allowedIds, List<String> blockedNames}) filterSameDayDuplicates({
  required Iterable<PlaceKey> moving,
  required Iterable<PlaceKey> occupantsOnDay,
}) {
  final allowed = <String>{};
  final blocked = <String>[];
  final taken = List<PlaceKey>.of(occupantsOnDay);
  for (final key in moving) {
    if (taken.any((o) => isSamePlace(o, key))) {
      blocked.add(key.name);
    } else {
      allowed.add(key.id);
      taken.add(key);
    }
  }
  return (allowedIds: allowed, blockedNames: blocked);
}
