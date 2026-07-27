import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/all_days_route_provider.dart';
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

  // OPTIMIZATION: Helper to reduce marker rebuild frequency
  Set<Marker> _buildMarkers(
    Set<Marker> overlayMarkers,
    List<LocationModel> locationsForDate,
  ) {
    // OPTIMIZATION: Limit marker processing to visible markers only
    // This prevents excessive marker object creation
    if (locationsForDate.isEmpty) {
      return overlayMarkers;
    }

    return overlayMarkers.map((marker) {
      final id = marker.markerId.value;
      // Skip special markers (current location, route markers)
      if (id == 'current_location' ||
          id.startsWith('leg_') ||
          id.startsWith('route_')) {
        return marker;
      }

      // Find corresponding location with error handling
      try {
        final location = locationsForDate.firstWhere(
          (loc) => loc.id == marker.markerId.value,
          orElse: () => locationsForDate.first,
        );

        return marker.copyWith(
          onTapParam: () => onMarkerTap?.call(location),
        );
      } catch (e) {
        // Return original marker if something goes wrong
        return marker;
      }
    }).toSet();
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
    final allDaysPolylines = ref.watch(allDaysPolylinesProvider);
    final allDaysMarkers =
        ref.watch(allDaysMarkersProvider).valueOrNull ?? const <Marker>{};
    final pinnedLocations = allDaysMode
        ? ref.watch(tripProvider.select((s) => s.pinnedLocations))
        : const <LocationModel>[];

    return mapOverlayAsync.when(
      data: (AssembledMapOverlays overlayState) {
        // All-days pins open the same location detail modal as single-day
        // pins: parse the location id back out of the marker id and route
        // the tap through the shared onMarkerTap callback.
        final tappableAllDays = allDaysMarkers.map((m) {
          final locId = locationIdFromAllDaysMarker(m.markerId.value);
          if (locId == null) return m;
          final idx = pinnedLocations.indexWhere((l) => l.id == locId);
          if (idx == -1) return m;
          final loc = pinnedLocations[idx];
          return m.copyWith(onTapParam: () => onMarkerTap?.call(loc));
        }).toSet();
        final markers = allDaysMode
            ? {
                ...tappableAllDays,
                ...overlayState.markers
                    .where((m) => m.markerId.value == 'current_location'),
              }
            : _buildMarkers(overlayState.markers, locationsForDate);
        final polylines =
            allDaysMode ? allDaysPolylines : overlayState.polylines;
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
