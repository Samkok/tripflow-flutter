import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/main.dart' show SharedPrefsCache;

import '../services/place_photo_refresh_service.dart';
import '../services/places_service.dart';
import 'location_provider.dart';
import 'trip_collaborator_provider.dart';

/// App wiring for [PlacePhotoRefreshService]: Google through
/// [PlacesService], rows through the location repository (a synced update
/// when the user may write to the trip, a device-local patch otherwise),
/// per-place records in SharedPreferences.
final placePhotoRefreshProvider = Provider<PlacePhotoRefreshService>((ref) {
  return PlacePhotoRefreshService(
    fetch: PlacesService.fetchPlacePhotos,
    canWrite: (tripId) async {
      // Rows outside any trip are the user's own.
      if (tripId == null || tripId.isEmpty) return true;
      try {
        return await ref.read(hasWriteAccessProvider(tripId).future);
      } catch (_) {
        return false;
      }
    },
    save: (id, updates, {required synced}) {
      final repository = ref.read(locationRepositoryProvider);
      return synced
          ? repository.updateLocation(id, updates)
          : repository.patchLocationLocally(id, updates);
    },
    readPref: (key) => SharedPrefsCache.maybeInstance?.getString(key),
    writePref: (key, value) async {
      await SharedPrefsCache.maybeInstance?.setString(key, value);
    },
  );
});
