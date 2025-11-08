import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:tripflow/models/location_model.dart';
import 'package:tripflow/providers/optimized_map_overlay_provider.dart';
import 'package:tripflow/providers/trip_provider.dart';
import '../providers/theme_provider.dart';
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
    // DEBUG: Uncomment to track widget rebuilds
    // print('🗺️ MapWidget build called');

    final mapOverlayAsync = ref.watch(assembledMapOverlaysProvider);
    final locationsForDate = ref.watch(locationsForSelectedDateProvider);
    final themeMode = ref.watch(themeProvider);
    final currentLocation = ref.watch(cachedMarkersProvider).valueOrNull?.markers.firstWhere((m) => m.markerId.value == 'current_location', orElse: () => Marker(markerId: MarkerId(''))).position;

    return mapOverlayAsync.when(
      data: (AssembledMapOverlays overlayState) {
        // DEBUG: Uncomment to track rendering details
        // print('✅ MapWidget rendering with ${overlayState.markers.length} markers, ${overlayState.polylines.length} polylines, ${overlayState.automaticZones.length} circles');

        // OPTIMIZED: Use RepaintBoundary to isolate map repaints from parent widget tree
        // This prevents unnecessary repaints when parent widgets rebuild
        return RepaintBoundary(
          child:
              // OPTIMIZED: GoogleMap widget with all overlays
              // Flutter's GoogleMap handles internal optimizations for marker/polyline updates
              GoogleMap(
                // PERFORMANCE: Using a stable key prevents full widget recreation
                key: const ValueKey('main_google_map'),
                onMapCreated: onMapCreated,
                onLongPress: onMapLongPress,
                onTap: (_) {
                  // Clear polyline highlighting when map is tapped
                  ref.read(mapUIStateProvider.notifier).clearHighlights();
                },
                initialCameraPosition: CameraPosition(
                  target: currentLocation ?? const LatLng(37.422, -122.084), // Default to GooglePlex
                  zoom: currentLocation != null ? 15.0 : 10.0,
                ),
                markers: overlayState.markers.map((marker) {
                  // The 'current_location' marker doesn't have a corresponding LocationModel,
                  // so we handle it separately to avoid a 'Bad state: No element' error.
                  final id = marker.markerId.value;
                  if (id == 'current_location' || id.startsWith('leg_') || id.startsWith('route_info_')) {
                    return marker;
                  }
                  // For all other markers, find the location and attach the tap handler.
                  final location = locationsForDate.firstWhere(
                    (loc) => loc.id == marker.markerId.value,
                    orElse: () => locationsForDate.first, // Should not happen, but a safe fallback.
                  );
                  return marker.copyWith(onTapParam: () => onMarkerTap?.call(location));
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
        // OPTIMIZED: Show loading state with minimal UI impact
        return const Center(
          child: CircularProgressIndicator(),
        );
      },
      error: (error, stack) {
        // DEBUG: Uncomment to track errors
        // print('❌ MapWidget error: $error');
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

  static String getMapStyle(ThemeMode themeMode, bool showLabels) {
    if (!showLabels) {
      return themeMode == ThemeMode.dark ? mapStyleDarkNoLabels : mapStyleLightNoLabels;
    }
    return themeMode == ThemeMode.dark ? mapStyleDark : mapStyleLight;
  }

  // Made public to be accessible from MapScreen
  static const String mapStyle = '''
  [
    {
      "elementType": "geometry",
      "stylers": [
        {
          "color": "#1d2c4d"
        }
      ]
    },
    {
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#8ec3b9"
        }
      ]
    },
    {
      "elementType": "labels.text.stroke",
      "stylers": [
        {
          "color": "#1a3646"
        }
      ]
    },
    {
      "featureType": "administrative.country",
      "elementType": "geometry.stroke",
      "stylers": [
        {
          "color": "#4b6878"
        }
      ]
    },
    {
      "featureType": "poi",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#00D4FF"
        }
      ]
    },
    {
      "featureType": "poi",
      "elementType": "labels.text.stroke",
      "stylers": [
        {
          "color": "#1a3646"
        }
      ]
    },
    {
      "featureType": "poi",
      "elementType": "labels.icon",
      "stylers": [
        {
          "visibility": "on"
        }
      ]
    },
    {
      "featureType": "poi.business",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#FF6B6B"
        }
      ]
    },
    {
      "featureType": "poi.park",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#10B981"
        }
      ]
    },
    {
      "featureType": "poi.attraction",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#7C3AED"
        }
      ]
    },
    {
      "featureType": "administrative.locality",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#FFFFFF"
        }
      ]
    },
    {
      "featureType": "administrative.neighborhood",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#B0B0B0"
        }
      ]
    },
    {
      "featureType": "road",
      "elementType": "geometry",
      "stylers": [
        {
          "color": "#304a7d"
        }
      ]
    },
    {
      "featureType": "road",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#98a5be"
        }
      ]
    },
    {
      "featureType": "road.highway",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#FFFFFF"
        }
      ]
    },
    {
      "featureType": "road.arterial",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#E0E0E0"
        }
      ]
    },
    {
      "featureType": "transit.station",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#F59E0B"
        }
      ]
    },
    {
      "featureType": "water",
      "elementType": "geometry",
      "stylers": [
        {
          "color": "#0e1626"
        }
      ]
    },
    {
      "featureType": "water",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#00D4FF"
        }
      ]
    }
  ]
  ''';

  static const String mapStyleLightNoLabels = '''
  [
    {
      "elementType": "labels",
      "stylers": [
        { "visibility": "off" }
      ]
    },
    {
      "featureType": "road",
      "elementType": "labels",
      "stylers": [ { "visibility": "off" } ]
    }
  ]
  ''';
  static const String mapStyleDark = '''
  [
    {
      "elementType": "geometry",
      "stylers": [
        {
          "color": "#1d2c4d"
        }
      ]
    },
    {
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#8ec3b9"
        }
      ]
    },
    {
      "elementType": "labels.text.stroke",
      "stylers": [
        {
          "color": "#1a3646"
        }
      ]
    },
    {
      "featureType": "administrative.country",
      "elementType": "geometry.stroke",
      "stylers": [
        {
          "color": "#4b6878"
        }
      ]
    },
    {
      "featureType": "poi",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#00D4FF"
        }
      ]
    },
    {
      "featureType": "poi",
      "elementType": "labels.text.stroke",
      "stylers": [
        {
          "color": "#1a3646"
        }
      ]
    },
    {
      "featureType": "poi",
      "elementType": "labels.icon",
      "stylers": [
        {
          "visibility": "on"
        }
      ]
    },
    {
      "featureType": "poi.business",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#FF6B6B"
        }
      ]
    },
    {
      "featureType": "poi.park",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#10B981"
        }
      ]
    },
    {
      "featureType": "poi.attraction",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#7C3AED"
        }
      ]
    },
    {
      "featureType": "administrative.locality",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#FFFFFF"
        }
      ]
    },
    {
      "featureType": "administrative.neighborhood",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#B0B0B0"
        }
      ]
    },
    {
      "featureType": "road",
      "elementType": "geometry",
      "stylers": [
        {
          "color": "#304a7d"
        }
      ]
    },
    {
      "featureType": "road",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#98a5be"
        }
      ]
    },
    {
      "featureType": "road.highway",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#FFFFFF"
        }
      ]
    },
    {
      "featureType": "road.arterial",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#E0E0E0"
        }
      ]
    },
    {
      "featureType": "transit.station",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#F59E0B"
        }
      ]
    },
    {
      "featureType": "water",
      "elementType": "geometry",
      "stylers": [
        {
          "color": "#0e1626"
        }
      ]
    },
    {
      "featureType": "water",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#00D4FF"
        }
      ]
    }
  ]
  ''';

  static const String mapStyleLight = '''
  [
    {
      "featureType": "water",
      "elementType": "geometry",
      "stylers": [
        {
          "color": "#e9e9e9"
        },
        {
          "lightness": 17
        }
      ]
    },
    {
      "featureType": "landscape",
      "elementType": "geometry",
      "stylers": [
        {
          "color": "#f5f5f5"
        },
        {
          "lightness": 20
        }
      ]
    },
    {
      "featureType": "road.highway",
      "elementType": "geometry.fill",
      "stylers": [
        {
          "color": "#ffffff"
        },
        {
          "lightness": 17
        }
      ]
    }
  ]
  ''';

  // Made public to be accessible from MapScreen
  static const String mapStyleDarkNoLabels = '''
  [
    {
      "elementType": "labels",
      "stylers": [
        {
          "visibility": "off"
        }
      ]
    },
    {
      "elementType": "geometry",
      "stylers": [
        {
          "color": "#1d2c4d"
        }
      ]
    },
    {
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#8ec3b9"
        }
      ]
    },
    {
      "elementType": "labels.text.stroke",
      "stylers": [
        {
          "color": "#1a3646"
        }
      ]
    },
    {
      "featureType": "administrative.country",
      "elementType": "geometry.stroke",
      "stylers": [
        {
          "color": "#4b6878"
        }
      ]
    },
    {
      "featureType": "poi",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#00D4FF"
        }
      ]
    },
    {
      "featureType": "poi",
      "elementType": "labels.text.stroke",
      "stylers": [
        {
          "color": "#1a3646"
        }
      ]
    },
    {
      "featureType": "poi.business",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#FF6B6B"
        }
      ]
    },
    {
      "featureType": "poi.park",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#10B981"
        }
      ]
    },
    {
      "featureType": "poi.attraction",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#7C3AED"
        }
      ]
    },
    {
      "featureType": "administrative.locality",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#FFFFFF"
        }
      ]
    },
    {
      "featureType": "administrative.neighborhood",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#B0B0B0"
        }
      ]
    },
    {
      "featureType": "road",
      "elementType": "geometry",
      "stylers": [
        {
          "color": "#304a7d"
        }
      ]
    },
    {
      "featureType": "transit.station",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#F59E0B"
        }
      ]
    },
    {
      "featureType": "water",
      "elementType": "geometry",
      "stylers": [
        {
          "color": "#0e1626"
        }
      ]
    },
    {
      "featureType": "water",
      "elementType": "labels.text.fill",
      "stylers": [
        {
          "color": "#00D4FF"
        }
      ]
    }
  ]
  ''';
}