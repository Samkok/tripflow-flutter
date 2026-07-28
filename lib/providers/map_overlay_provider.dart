import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/debounced_settings_provider.dart';
import 'package:voyza/providers/theme_provider.dart';
import '../models/location_model.dart';
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
  BitmapDescriptor? _currentLocationIcon;
  final Map<String, MarkerBitmapResult> _numberedMarkerIcons =
      {}; // Cache for numbered markers

  @override
  Future<MapOverlayState> build() async {
    // PERFORMANCE: Use .select() to only rebuild when specific fields change
    // instead of watching entire TripState which rebuilds on ANY change
    final pinnedLocations =
        ref.watch(tripProvider.select((s) => s.pinnedLocations));
    final currentLocation =
        ref.watch(tripProvider.select((s) => s.currentLocation));
    final legPolylines = ref.watch(tripProvider.select((s) => s.legPolylines));
    final proximityThreshold = ref.watch(proximityThresholdCommittedProvider);
    final tappedPolylineId = ref.watch(tappedPolylineIdProvider);
    final showMarkerNames = ref.watch(showMarkerNamesProvider);
    final isDarkMode =
        ref.watch(themeProvider.select((mode) => mode == ThemeMode.dark));

    // Load marker icons if not already loaded
    if (_currentLocationIcon == null) {
      _currentLocationIcon = await MarkerUtils.getCurrentLocationMarker(
          backgroundColor: Colors.black);
    }

    return await _generateOverlays(
        pinnedLocations,
        currentLocation,
        legPolylines,
        proximityThreshold,
        tappedPolylineId,
        showMarkerNames,
        isDarkMode);
  }

  Future<MapOverlayState> _generateOverlays(
    List<LocationModel> pinnedLocations,
    LatLng? currentLocation,
    List<List<LatLng>> legPolylines,
    double proximityThreshold,
    String? tappedPolylineId,
    bool showMarkerNames,
    bool isDarkMode,
  ) async {
    final Set<Marker> markers = {};
    final Set<Polyline> polylines = {};

    // Current location marker
    if (currentLocation != null && _currentLocationIcon != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('current_location'),
          position: currentLocation,
          anchor: const Offset(0.5, 0.5),
          icon: _currentLocationIcon!,
        ),
      );
    }

    // Pinned location markers with custom numbered icons
    for (int i = 0; i < pinnedLocations.length; i++) {
      final location = pinnedLocations[i];

      final int markerNumber = i + 1;
      final String cacheKey = '${markerNumber}_${location.name}_$isDarkMode';
      MarkerBitmapResult? customMarkerResult = _numberedMarkerIcons[cacheKey];
      if (customMarkerResult == null) {
        customMarkerResult = await MarkerUtils.getCustomMarkerBitmap(
          number: markerNumber,
          name: location.name,
          backgroundColor: AppTheme.accentColor,
          textColor: Colors.white,
          isDarkMode: isDarkMode,
        );
        _numberedMarkerIcons[cacheKey] = customMarkerResult;
      }

      markers.add(
        Marker(
          markerId: MarkerId(location.id),
          position: location.coordinates,
          icon: customMarkerResult.bitmap,
          anchor: customMarkerResult.anchor,
        ),
      );
    }

    // Individual leg polylines (clickable)
    for (int i = 0; i < legPolylines.length; i++) {
      final legPoints = legPolylines[i];
      if (legPoints.isNotEmpty) {
        final polylineId = 'leg_$i';
        final isHighlighted = tappedPolylineId == polylineId;

        polylines.add(
          Polyline(
            polylineId: PolylineId(polylineId),
            points: legPoints,
            color: isHighlighted
                ? AppTheme.primaryColor
                : Colors.grey.withValues(alpha: 0.7),
            width: isHighlighted ? 12 : 8,
          ),
        );
      }
    }

    // Generate zone polygons around clustered locations
    final nonSkippedLocations =
        pinnedLocations.where((loc) => !loc.isSkipped).toList();
    final automaticZones = ZoneUtils.getZoneCircles(
      nonSkippedLocations,
      proximityThreshold,
    );

    return MapOverlayState(
      originalLocations: pinnedLocations,
      markers: markers,
      polylines: polylines,
      automaticZones: automaticZones,
    );
  }
}

final mapOverlayProvider =
    AsyncNotifierProvider<MapOverlayNotifier, MapOverlayState>(() {
  return MapOverlayNotifier();
});
