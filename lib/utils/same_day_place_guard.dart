import 'dart:math' as math;

import '../models/location_model.dart';
import '../models/saved_location.dart';
import 'search_text.dart';

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

/// Looser identity for NEW adds: [isSamePlace], or the same name (case- and
/// accent-insensitive, see [normalizeSearchText]) within
/// [likelySamePlaceMeters]. Google often carries several entries for one
/// landmark — a "Golden Gate Bridge" tourist attraction and a road-segment
/// entry, a temple and its gate — each with its own place_id and pin, so
/// the strict rule let the nearby picker add the same bridge twice to one
/// day. A user tapping the second entry means the place they already
/// planned, not a new stop.
///
/// Deliberately NOT used by the reschedule paths (drag, move, copy, date
/// edit): a row already in the trip was accepted once, and moving it must
/// never be refused by a fuzzy match against a different row.
const double likelySamePlaceMeters = 1000;

bool isLikelySamePlace(PlaceKey a, PlaceKey b) {
  if (isSamePlace(a, b)) return true;
  final nameA = normalizeSearchText(a.name);
  if (nameA.isEmpty || nameA != normalizeSearchText(b.name)) return false;
  if (a.lat.isNaN || a.lng.isNaN || b.lat.isNaN || b.lng.isNaN) return false;
  return _haversineMeters(a.lat, a.lng, b.lat, b.lng) <= likelySamePlaceMeters;
}

double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
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
/// blocked. [samePlace] is the identity rule: the strict [isSamePlace] by
/// default (reschedule paths), [isLikelySamePlace] for new adds.
({Set<String> allowedIds, List<String> blockedNames}) filterSameDayDuplicates({
  required Iterable<PlaceKey> moving,
  required Iterable<PlaceKey> occupantsOnDay,
  bool Function(PlaceKey a, PlaceKey b) samePlace = isSamePlace,
}) {
  final allowed = <String>{};
  final blocked = <String>[];
  final taken = List<PlaceKey>.of(occupantsOnDay);
  for (final key in moving) {
    if (taken.any((o) => samePlace(o, key))) {
      blocked.add(key.name);
    } else {
      allowed.add(key.id);
      taken.add(key);
    }
  }
  return (allowedIds: allowed, blockedNames: blocked);
}
