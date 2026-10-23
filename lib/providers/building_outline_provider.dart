import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../core/theme.dart';
import '../models/location_model.dart';
import '../services/building_outline_service.dart';
import '../services/marker_cache_service.dart';
import '../utils/marker_ids.dart';

/// The place whose building is highlighted on the map: the pin last opened.
/// Cleared by a tap on the map and by a change of day.
final focusedPlaceProvider = StateProvider<LocationModel?>((_) => null);

/// The focused place's name card above its pin — the app's own callout in
/// the route chip's style, in place of the platform's white info window.
/// One marker (`place_callout_<id>`), gone with the focus. The tap opens
/// the place like the pin does (wired in the map widget).
final focusedPlaceCalloutProvider = FutureProvider<Set<Marker>>((ref) async {
  final place = ref.watch(focusedPlaceProvider);
  if (place == null) return const {};
  final address = place.address.trim();
  final callout = await MarkerCacheService().getPlaceCallout(
    place.name,
    subtitle: address.isEmpty ? place.floor : address,
  );
  return {
    Marker(
      markerId: MarkerId(
          versionedMarkerId('place_callout_${place.id}', callout.bitmap)),
      position: place.coordinates,
      icon: callout.bitmap,
      anchor: callout.anchor,
      zIndexInt: 3,
      consumeTapEvents: true,
    ),
  };
});

/// The focused place's footprint, fetched once per place per run (see
/// [BuildingOutlineService]). Null while nothing is focused, for a place
/// without a Google place id, and when Google has no footprint for it.
final focusedBuildingProvider = FutureProvider<BuildingOutline?>((ref) async {
  final place = ref.watch(focusedPlaceProvider);
  final id = place?.placeId;
  if (id == null || id.isEmpty) return null;
  return BuildingOutlineService.forPlace(id);
});

/// The highlight itself: one translucent polygon per building part, drawn
/// under the pins and routes. An empty set until the outline is known, so
/// the map is never blocked on the lookup.
final buildingPolygonsProvider = Provider<Set<Polygon>>((ref) {
  final outline = ref.watch(focusedBuildingProvider).valueOrNull;
  if (outline == null || outline.isEmpty) return const <Polygon>{};
  return {
    for (var i = 0; i < outline.rings.length; i++)
      Polygon(
        polygonId: PolygonId('building_${outline.placeId}_$i'),
        points: outline.rings[i],
        fillColor: AppTheme.accentColor.withValues(alpha: 0.22),
        strokeColor: AppTheme.accentColor.withValues(alpha: 0.9),
        strokeWidth: 2,
        zIndex: 1,
        consumeTapEvents: false,
        geodesic: false,
      ),
  };
});
