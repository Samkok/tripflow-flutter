import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/material.dart';
import 'package:tripflow/providers/map_ui_state_provider.dart';
import 'package:tripflow/providers/theme_provider.dart';
import '../models/location_model.dart';
import '../providers/settings_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/debounced_settings_provider.dart';
import '../services/marker_cache_service.dart';
import '../utils/zone_utils.dart';
import '../core/theme.dart';

class CachedMarkersState {
  final Set<Marker> markers;
  final String cacheKey;

  const CachedMarkersState({
    required this.markers,
    required this.cacheKey,
  });
}

String _generateLocationsCacheKey(List<LocationModel> locations, LatLng? currentLocation, DateTime selectedDate) {
  // Use a combination of IDs and count to ensure the key changes when items are added/removed.
  final locationIds = locations.map((l) => '${l.id}-${l.isSkipped}').join('_');
  final currentLocKey = currentLocation != null ? '${currentLocation.latitude}_${currentLocation.longitude}' : 'none';
  final dateKey = selectedDate.toIso8601String();
  return 'locations_${locations.length}_${locationIds}_current_${currentLocKey}_date_$dateKey';
}

final cachedMarkersProvider = FutureProvider<CachedMarkersState>((ref) async {
  // OPTIMIZED: Use select() to only rebuild when locations or currentLocation change
  final locationsForDate = ref.watch(locationsForSelectedDateProvider); // This will now be the optimized list if available
  final selectedDate = ref.watch(selectedDateProvider);
  final tripState = ref.watch(tripProvider);
  final currentLocation = ref.watch(tripProvider.select((state) => state.currentLocation));
  final showPlaceNames = ref.watch(showMarkerNamesProvider);
  final isDarkMode = ref.watch(themeProvider) == ThemeMode.dark;
  
  final cacheKey = _generateLocationsCacheKey(locationsForDate, currentLocation, selectedDate);

  // DEBUG: Uncomment to track marker generation
  // print('🎨 Generating cached markers - locations: ${pinnedLocations.length}, showNames: $showPlaceNames');

  final Set<Marker> markers = {};
  final markerCache = MarkerCacheService();

  if (currentLocation != null) {
    final currentLocationIcon = await markerCache.getCurrentLocationMarker();
    markers.add(
      Marker(
        markerId: const MarkerId('current_location'),
        position: currentLocation,
        icon: currentLocationIcon,
        infoWindow: const InfoWindow(title: 'Your Location'), // Keep for current location
      ),
    );
  }

  // OPTIMIZED: Use batch marker generation for better performance
  int nonSkippedIndex = 0; // This index will now correctly reflect the optimized order
  for (final location in locationsForDate) { // Iterate over the correctly ordered list
    int markerNumber;

    // Check if this location is the designated start location for the route
    final isStartLocation = tripState.optimizedRoute.isNotEmpty &&
                              tripState.startLocationId == location.id;

    if (isStartLocation) {
      markerNumber = 0; // Use 0 to signify the start location
    }
    if (location.isSkipped) {
      markerNumber = -1; // Use -1 to indicate a skipped location to the marker service
    } else {
      nonSkippedIndex++;
      markerNumber = nonSkippedIndex;
    }

    final customIcon = await markerCache.getNumberedMarker(
      isStart: isStartLocation,
      number: markerNumber,
      name: location.name,
      backgroundColor: AppTheme.accentColor,
      textColor: Colors.white,
      isDarkMode: isDarkMode,
      isSkipped: location.isSkipped, // Pass the skipped status
    );

    markers.add(
      Marker(
        markerId: MarkerId(location.id),
        position: location.coordinates,
        icon: customIcon,
        infoWindow: showPlaceNames
            ? InfoWindow(
                title: location.name,
                snippet: location.address,
              )
            : InfoWindow.noText,
      ),
    );
  }

  // DEBUG: Uncomment to track marker generation completion
  // print('✅ Generated ${markers.length} cached markers');

  return CachedMarkersState(markers: markers, cacheKey: cacheKey);
});

class ZoneCacheKey {
  final String locationIds;
  final double threshold;

  const ZoneCacheKey(this.locationIds, this.threshold);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoneCacheKey &&
          runtimeType == other.runtimeType &&
          locationIds == other.locationIds &&
          threshold == other.threshold;

  @override
  int get hashCode => locationIds.hashCode ^ threshold.hashCode;

  @override
  String toString() => 'ZoneCacheKey($locationIds, $threshold)';
}

ZoneCacheKey _generateZoneCacheKey(List<LocationModel> locations, double threshold) {
  final locationIds = locations.map((l) => l.id).join('_');
  return ZoneCacheKey(locationIds, threshold);
}

final memoizedAutomaticZonesProvider = Provider<Set<Circle>>((ref) {
  // Watch all locations and the selected date to filter them.
  final allLocations = ref.watch(tripProvider.select((state) => state.pinnedLocations));
  final selectedDate = ref.watch(selectedDateProvider);
  final threshold = ref.watch(proximityThresholdCommittedProvider);

  // Filter locations to only include those for the selected date and are not skipped.
  final locationsForDate = allLocations.where((loc) {
    if (loc.isSkipped) return false;

    // This logic now mirrors `locationsForSelectedDateProvider` exactly.
    if (loc.scheduledDate == null) {
      final addedAtDate = DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
      return selectedDate.isAtSameMomentAs(addedAtDate);
    }
    final locDate = loc.scheduledDate!;
    final scheduledDateAtMidnight = DateTime(locDate.year, locDate.month, locDate.day);
    return selectedDate.isAtSameMomentAs(scheduledDateAtMidnight);
  }).toList();

  final cacheKey = _generateZoneCacheKey(locationsForDate, threshold);

  // DEBUG: Uncomment to track zone computation
  // print('📏 Computing zones with key: $cacheKey');

  if (locationsForDate.isEmpty) {
    return {};
  }

  final zones = ZoneUtils.getZoneCircles(locationsForDate, threshold);

  // DEBUG: Uncomment to track zone generation
  // print('🏞️ Generated ${zones.length} automatic zone circles');

  return zones;
});

final styledPolylinesProvider = Provider<Set<Polyline>>((ref) {
  final tripState = ref.watch(tripProvider);
  final selectedDate = ref.watch(selectedDateProvider);
  final tappedPolylineId = ref.watch(tappedPolylineIdProvider);

  // DEBUG: Uncomment to track polyline styling
  // print('🎨 Styling ${tripState.legPolylines.length} polylines, highlighted: $tappedPolylineId, optimized locations: ${tripState.optimizedLocationsForSelectedDate.length}');

  final Set<Polyline> polylines = {};

  // The legPolylines are generated based on tripState.optimizedLocationsForSelectedDate.
  // So, we should use that list for checking bounds.
  final List<LocationModel> currentOptimizedLocations = tripState.optimizedLocationsForSelectedDate;

  // We iterate through the legs of the route. The number of legs should be one less
  // than the number of optimized locations for the selected date.
  for (int i = 0; i < tripState.legPolylines.length; i++) {
    // Ensure we have corresponding locations for this leg.
    // This check needs to be against the locations that were used to generate the route.
    // If the optimizedLocationsForSelectedDate is empty, it means no route is generated for the current date.
    if (currentOptimizedLocations.isEmpty || i + 1 >= currentOptimizedLocations.length) {
      continue;
    }

    final legPoints = tripState.legPolylines[i];
    if (legPoints.isNotEmpty) {
      final polylineId = 'leg_$i';
      final isHighlighted = tappedPolylineId == polylineId;
      polylines.add(
        Polyline(
          polylineId: PolylineId(polylineId),
          points: legPoints,
          color: isHighlighted ? AppTheme.primaryColor : Colors.grey.withOpacity(0.6),
          width: isHighlighted ? 5 : 4,
          consumeTapEvents: true,
          onTap: () {
            ref.read(mapUIStateProvider.notifier).setTappedPolyline(polylineId);
          },
        ),
      );
    }
  }

  return polylines;
});

final routeInfoMarkersProvider = FutureProvider<Set<Marker>>((ref) async {
  // This provider now only generates a marker for the *tapped* route segment.
  final tappedPolylineId = ref.watch(tappedPolylineIdProvider);

  // If no route is tapped, show no info markers.
  if (tappedPolylineId == null) {
    return {};
  }

  final tripState = ref.watch(tripProvider);
  final legIndex = int.tryParse(tappedPolylineId.replaceFirst('leg_', '')) ?? -1;

  // Ensure the leg index is valid.
  if (legIndex < 0 || legIndex >= tripState.legDetails.length || legIndex >= tripState.legPolylines.length) {
    return {};
  }

  final legPoints = tripState.legPolylines[legIndex];
  if (legPoints.isEmpty) return {};

  final legDetail = tripState.legDetails[legIndex];
  final duration = legDetail['duration'] as Duration;
  final distance = legDetail['distance'] as double;

  // Calculate midpoint for marker placement.
  final midIndex = legPoints.length ~/ 2;
  final midpoint = legPoints[midIndex];

  // Determine if this specific marker should be highlighted
  final isHighlighted = tappedPolylineId == 'leg_$legIndex';

  final markerCache = MarkerCacheService();
  final icon = await markerCache.getRouteInfoMarker(
    duration: _formatDurationForMarker(duration),
    distance: _formatDistanceForMarker(distance),
    isHighlighted: isHighlighted,
  );

  return {Marker(markerId: MarkerId('route_info_$legIndex'), position: midpoint, icon: icon, anchor: const Offset(0.5, 0.5), zIndex: 10)};
});

String _formatDurationForMarker(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;

  if (hours > 0) {
    return '${hours}h ${minutes}m';
  } else {
    return '${minutes}m';
  }
}

String _formatDistanceForMarker(double distanceInMeters) {
  if (distanceInMeters < 1000) {
    return '${distanceInMeters.toInt()}m';
  } else {
    final kilometers = distanceInMeters / 1000;
    return '${kilometers.toStringAsFixed(1)}km';
  }
}

class AssembledMapOverlays {
  final Set<Marker> markers;
  final Set<Polyline> polylines;
  final Set<Circle> automaticZones;

  const AssembledMapOverlays({
    required this.markers,
    required this.polylines,
    required this.automaticZones,
  });
}

final assembledMapOverlaysProvider = Provider<AsyncValue<AssembledMapOverlays>>((ref) {
  final markersAsync = ref.watch(cachedMarkersProvider);
  final polylines = ref.watch(styledPolylinesProvider);
  final automaticZones = ref.watch(memoizedAutomaticZonesProvider);
  final routeInfoMarkersAsync = ref.watch(routeInfoMarkersProvider);

  return markersAsync.when(
    data: (cachedMarkers) {
      final routeInfoMarkers = routeInfoMarkersAsync.valueOrNull ?? {};

      // DEBUG: Uncomment to track overlay assembly
      // print('✅ Assembling map overlays: ${cachedMarkers.markers.length} base markers, ${routeInfoMarkers.length} route info markers, ${polylines.length} polylines, ${automaticZones.length} auto zones');

      return AsyncValue.data(AssembledMapOverlays(
        markers: {...cachedMarkers.markers, ...routeInfoMarkers},
        polylines: polylines,
        automaticZones: automaticZones,
      ));
    },
    loading: () {
      // DEBUG: Uncomment to track loading state
      // print('⏳ Loading markers...');
      return AsyncValue.loading();
    },
    error: (error, stack) {
      // Keep error logging for debugging issues
      print('❌ Error loading markers: $error');
      return AsyncValue.error(error, stack);
    },
  );
});
