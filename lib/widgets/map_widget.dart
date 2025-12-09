import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mapOverlayAsync = ref.watch(assembledMapOverlaysProvider);
    final locationsForDate = ref.watch(locationsForSelectedDateProvider);
    final currentLocation =
        ref.watch(tripProvider.select((s) => s.currentLocation));

    return mapOverlayAsync.when(
      data: (AssembledMapOverlays overlayState) {
        return RepaintBoundary(
          child: GoogleMap(
            key: const ValueKey('main_google_map'),
            onMapCreated: onMapCreated,
            onLongPress: onMapLongPress,
            onTap: (_) {
              ref.read(mapUIStateProvider.notifier).clearHighlights();
            },
            initialCameraPosition: CameraPosition(
              target: currentLocation ?? const LatLng(37.422, -122.084),
              zoom: currentLocation != null ? 15.0 : 10.0,
            ),
            markers: overlayState.markers.map((marker) {
              final id = marker.markerId.value;
              if (id == 'current_location' ||
                  id.startsWith('leg_') ||
                  id.startsWith('route_info_')) {
                return marker;
              }
              final location = locationsForDate.firstWhere(
                (loc) => loc.id == marker.markerId.value,
                orElse: () => locationsForDate.first,
              );
              return marker.copyWith(
                  onTapParam: () => onMarkerTap?.call(location));
            }).toSet(),
            polylines: overlayState.polylines,
            circles: {
              ...overlayState.automaticZones,
            },
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
