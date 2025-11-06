import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:tripflow/providers/map_ui_state_provider.dart';
import 'package:tripflow/providers/debounced_settings_provider.dart';
import 'package:tripflow/providers/theme_provider.dart';import '../models/location_model.dart';
import '../providers/trip_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/marker_utils.dart';
import '../utils/zone_utils.dart';
import '../core/theme.dart';

class MapOverlayState {
  final List<LocationModel> originalLocations;
  final Set<Marker> markers;
  final Set<Polyline> polylines;
  final Set<Circle> automaticZones;

  MapOverlayState({
    required this.originalLocations,
    required this.markers,
    required this.polylines,
    required this.automaticZones,
  });

  MapOverlayState copyWith({
    List<LocationModel>? originalLocations,
    Set<Marker>? markers,
    Set<Polyline>? polylines,
    Set<Circle>? automaticZones,
  }) {
    return MapOverlayState(
      originalLocations: originalLocations ?? this.originalLocations,
      markers: markers ?? this.markers,
      polylines: polylines ?? this.polylines,
      automaticZones: automaticZones ?? this.automaticZones,
    );
  }
}

class MapOverlayNotifier extends AsyncNotifier<MapOverlayState> {
  BitmapDescriptor? _currentLocationIcon;  final Map<String, BitmapDescriptor> _numberedMarkerIcons = {}; // Cache for numbered markers

  @override
  Future<MapOverlayState> build() async {
    print('🏗️ Building MapOverlayNotifier');
    
    // Watch dependencies
    final tripState = ref.watch(tripProvider);
    final proximityThreshold = ref.watch(proximityThresholdCommittedProvider);
    final tappedPolylineId = ref.watch(tappedPolylineIdProvider);
    final showMarkerNames = ref.watch(showMarkerNamesProvider);
    final isDarkMode = ref.watch(themeProvider) == ThemeMode.dark;
    
    print('🔄 MapOverlay build triggered - locations: ${tripState.pinnedLocations.length}, threshold: ${proximityThreshold}m');
    
    // Load marker icons if not already loaded
    if (_currentLocationIcon == null) {
      _currentLocationIcon = await MarkerUtils.getCurrentLocationMarker(backgroundColor: Colors.black);
    }
    
    return await _generateOverlays(tripState, proximityThreshold, tappedPolylineId, showMarkerNames, isDarkMode);
  }

  Future<MapOverlayState> _generateOverlays(
    TripState tripState,
    double proximityThreshold,
    String? tappedPolylineId,
    bool showMarkerNames,
    bool isDarkMode,
  ) async {
    print('🎨 Generating overlays with ${tripState.pinnedLocations.length} locations');
    
    final Set<Marker> markers = {};
    final Set<Polyline> polylines = {};

    // Current location marker
    if (tripState.currentLocation != null && _currentLocationIcon != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('current_location'),
          position: tripState.currentLocation!,
          anchor: const Offset(0.5, 0.5), // Center the icon on the coordinate
          icon: _currentLocationIcon!,
        ),
      );
    }

    // Pinned location markers with custom numbered icons
    for (int i = 0; i < tripState.pinnedLocations.length; i++) {
      final location = tripState.pinnedLocations[i];
      
      // Get custom numbered marker from cache or generate if not present
      final int markerNumber = i + 1;
      final String cacheKey = '${markerNumber}_${location.name}_$isDarkMode';
      BitmapDescriptor? customIcon = _numberedMarkerIcons[cacheKey];
      if (customIcon == null) {
        customIcon = await MarkerUtils.getCustomMarkerBitmap(
          number: markerNumber,
          name: location.name,
          backgroundColor: AppTheme.accentColor,
          textColor: Colors.white,
          isDarkMode: isDarkMode,
        );
        _numberedMarkerIcons[cacheKey] = customIcon;
      }

      markers.add(
        Marker(
          markerId: MarkerId(location.id),
          position: location.coordinates,
          icon: customIcon,
        ),
      );
    }

    // Individual leg polylines (clickable)
    for (int i = 0; i < tripState.legPolylines.length; i++) {
      final legPoints = tripState.legPolylines[i];
      if (legPoints.isNotEmpty) {
        final polylineId = 'leg_$i';
        final isHighlighted = tappedPolylineId == polylineId;
        
        polylines.add(
          Polyline(
            polylineId: PolylineId(polylineId),
            points: legPoints,
            color: isHighlighted ? AppTheme.primaryColor : Colors.grey.withOpacity(0.7),
            width: isHighlighted ? 12 : 8,
          ),
        );
      }
    }

    // Generate zone polygons around clustered locations
    print('📏 Using proximity threshold: ${proximityThreshold}m for zone generation');

    final automaticZones = ZoneUtils.getZoneCircles(
      tripState.pinnedLocations,
      proximityThreshold,
    );
    print('🏞️ Generated ${automaticZones.length} automatic zone circles');

    return MapOverlayState(
      originalLocations: tripState.pinnedLocations,
      markers: markers,
      polylines: polylines,
      automaticZones: automaticZones,
    );
  }
}

final mapOverlayProvider = AsyncNotifierProvider<MapOverlayNotifier, MapOverlayState>(() {
  return MapOverlayNotifier();
});