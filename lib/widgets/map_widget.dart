import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/all_days_route_provider.dart';
import 'package:voyza/providers/arrival_ring_provider.dart';
import 'package:voyza/providers/optimized_map_overlay_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import '../providers/map_ui_state_provider.dart';

class MapWidget extends ConsumerWidget {
  final Function(GoogleMapController) onMapCreated;
  final Function(LatLng)? onMapLongPress;
  final Function(LocationModel)? onMarkerTap;
  final Map<String, dynamic>? temporaryDrawing;

  const MapWidget({
    super.key,
    required this.onMapCreated,
    this.onMapLongPress,
    this.onMarkerTap,
    this.temporaryDrawing,
  });

  // OPTIMIZATION: Helper to reduce marker rebuild frequency. Also applies
  // the status pin filter (All / Active / Skipped / Done): hidden pins are
  // simply left out of the set handed to GoogleMap — no bitmap work, no
  // provider reload — so toggling the filter is a cheap marker diff.
  Set<Marker> _buildMarkers(
    Set<Marker> overlayMarkers,
    List<LocationModel> locationsForDate,
    MapPinFilter pinFilter,
  ) {
    // OPTIMIZATION: Limit marker processing to visible markers only
    // This prevents excessive marker object creation
    if (locationsForDate.isEmpty) {
      return overlayMarkers;
    }

    final out = <Marker>{};
    for (final marker in overlayMarkers) {
      final id = marker.markerId.value;
      // Special markers (current location, route markers) pass through.
      if (id == 'current_location' ||
          id.startsWith('leg_') ||
          id.startsWith('route_')) {
        out.add(marker);
        continue;
      }
      final idx = locationsForDate.indexWhere((loc) => loc.id == id);
      if (idx == -1) {
        out.add(marker);
        continue;
      }
      final location = locationsForDate[idx];
      if (!pinMatchesFilter(pinFilter,
          isSkipped: location.isSkipped, isDone: location.isDone)) {
        continue;
      }
      out.add(marker.copyWith(onTapParam: () => onMarkerTap?.call(location)));
    }
    return out;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mapOverlayAsync = ref.watch(assembledMapOverlaysProvider);
    final locationsForDate = ref.watch(locationsForSelectedDateProvider);
    final currentLocation =
        ref.watch(tripProvider.select((s) => s.currentLocation));
    // "All days" mode swaps the selected-date overlays for the whole-trip
    // ones: one colored route + labeled day-tinted pins per day. The
    // current-location marker is kept from the base set so the user doesn't
    // lose themselves.
    final allDaysMode = ref.watch(allDaysModeProvider);
    final pinFilter = ref.watch(mapPinFilterProvider);
    final allDaysPolylines = ref.watch(allDaysPolylinesProvider);
    // Days hidden from the day legend are already filtered out here; every
    // day's bitmaps stay cached, so a legend toggle never re-rasterises.
    final allDaysMarkers = ref.watch(visibleAllDaysMarkersProvider);
    final pinnedLocations = allDaysMode
        ? ref.watch(tripProvider.select((s) => s.pinnedLocations))
        : const <LocationModel>[];

    return mapOverlayAsync.when(
      data: (AssembledMapOverlays overlayState) {
        // All-days pins open the same location detail modal as single-day
        // pins: parse the location id back out of the marker id and route
        // the tap through the shared onMarkerTap callback.
        // The status pin filter applies here too (same rule as the
        // single-day path): hidden pins are dropped from the set.
        final tappableAllDays = <Marker>{};
        for (final m in allDaysMarkers) {
          final locId = locationIdFromAllDaysMarker(m.markerId.value);
          if (locId == null) {
            tappableAllDays.add(m);
            continue;
          }
          final idx = pinnedLocations.indexWhere((l) => l.id == locId);
          if (idx == -1) {
            tappableAllDays.add(m);
            continue;
          }
          final loc = pinnedLocations[idx];
          if (!pinMatchesFilter(pinFilter,
              isSkipped: loc.isSkipped, isDone: loc.isDone)) {
            continue;
          }
          tappableAllDays
              .add(m.copyWith(onTapParam: () => onMarkerTap?.call(loc)));
        }
        final markers = allDaysMode
            ? {
                ...tappableAllDays,
                ...overlayState.markers
                    .where((m) => m.markerId.value == 'current_location'),
              }
            : _buildMarkers(overlayState.markers, locationsForDate, pinFilter);
        // The dotted arrival ring around the current-location dot rides on
        // the same tick that already moves that dot — no extra rebuilds.
        final ring = ref.watch(arrivalRingPolylineProvider);
        final polylines = {
          ...(allDaysMode ? allDaysPolylines : overlayState.polylines),
          if (ring != null) ring,
        };
        final circles =
            allDaysMode ? const <Circle>{} : overlayState.automaticZones;
        // OPTIMIZATION: Wrap in RepaintBoundary to prevent parent repaints
        return RepaintBoundary(
          child: GoogleMap(
            key: const ValueKey('main_google_map'),
            onMapCreated: onMapCreated,
            onLongPress: onMapLongPress,
            onTap: (_) {
              // Two pieces of "selected route" state exist:
              //   - mapUIStateProvider.tappedPolylineId (drives the
              //     tapped-leg highlight + info marker)
              //   - tripProvider.selectedLegIndex (drives the in-list
              //     leg selection)
              // Both need to clear on a map tap so the route returns to
              // its idle visual state without removing the route itself.
              ref.read(mapUIStateProvider.notifier).clearHighlights();
              ref.read(tripProvider.notifier).selectLeg(null);
              // Tapping the map should also dismiss the search keyboard if
              // it's open. Routing through FocusManager keeps this widget
              // unaware of the search bar's FocusNode.
              FocusManager.instance.primaryFocus?.unfocus();
            },
            initialCameraPosition: CameraPosition(
              target: currentLocation ?? const LatLng(37.422, -122.084),
              zoom: currentLocation != null ? 15.0 : 10.0,
            ),
            // OPTIMIZATION: Use memoized marker building to reduce garbage
            markers: markers,
            polylines: polylines,
            circles: {...circles},
            polygons: const {},
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            tiltGesturesEnabled: false,
            rotateGesturesEnabled: true,
            scrollGesturesEnabled: true,
            zoomGesturesEnabled: true,
            compassEnabled: false,
            liteModeEnabled: false,
            // Thermal: 3D building extrusion and indoor floor plans are
            // GPU/data work at street zoom that a planning map never needs.
            buildingsEnabled: false,
            indoorViewEnabled: false,
            // OPTIMIZATION: Limit FPS to reduce rendering pressure
            minMaxZoomPreference: const MinMaxZoomPreference(0, 22),
          ),
        );
      },
      loading: () {
        return const Center(
          child: CircularProgressIndicator(),
        );
      },
      error: (error, stack) {
        return GoogleMap(
          key: const ValueKey('error_google_map'),
          onMapCreated: onMapCreated,
          onLongPress: onMapLongPress,
          initialCameraPosition: CameraPosition(
            target: currentLocation ?? const LatLng(37.422, -122.084),
            zoom: currentLocation != null ? 15.0 : 10.0,
          ),
          markers: const {},
          polylines: const {},
          circles: const {},
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
          tiltGesturesEnabled: false,
          rotateGesturesEnabled: true,
          scrollGesturesEnabled: true,
          zoomGesturesEnabled: true,
          compassEnabled: false,
          liteModeEnabled: false,
          buildingsEnabled: false,
          indoorViewEnabled: false,
        );
      },
    );
  }

  static Future<String> getMapStyle(
      ThemeMode themeMode, bool showLabels) async {
    String stylePath;
    if (themeMode == ThemeMode.dark) {
      stylePath = showLabels
          ? 'assets/map_styles/dark_map_style.json'
          : 'assets/map_styles/dark_map_style_no_labels.json';
    } else {
      stylePath = showLabels
          ? 'assets/map_styles/light_map_style.json'
          : 'assets/map_styles/light_map_style_no_labels.json';
    }
    return await rootBundle.loadString(stylePath);
  }
}
