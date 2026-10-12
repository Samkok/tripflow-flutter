import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/places_service.dart';

/// Floor / unit lookup for a place saved before the app stored it (its row
/// has `floor == null`). One Place Details call per place id per run; the
/// detail sheet shows the answer and, when it may write, keeps it on the
/// row so no one asks Google again. Null = the lookup failed (offline,
/// quota); '' = Google lists nothing for this place.
final placeFloorLookupProvider =
    FutureProvider.family<String?, String>((ref, placeId) async {
  return PlacesService.fetchPlaceFloor(placeId);
});
