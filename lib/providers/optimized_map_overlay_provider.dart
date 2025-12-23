import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/material.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/theme_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/debounced_settings_provider.dart';
import '../services/marker_cache_service.dart';
import '../utils/zone_utils.dart';
import '../utils/marker_utils.dart'; // Needed for MarkerBitmapResult type
import '../core/theme.dart';
import 'package:url_launcher/url_launcher.dart';

class CachedMarkersState {
  // This will now hold the generated bitmaps AND anchors
  final Map<String, MarkerBitmapResult> markerIcons;
  final String cacheKey;

  const CachedMarkersState({
    required this.markerIcons,
    required this.cacheKey,
  });
}

String _generateLocationsCacheKey(List<LocationModel> locations,
    LatLng? currentLocation, DateTime selectedDate) {
  // Use a combination of IDs and count to ensure the key changes when items are added/removed.
  final locationIds = locations.map((l) => '${l.id}-${l.isSkipped}').join('_');
  final currentLocKey = currentLocation != null
      ? '${currentLocation.latitude}_${currentLocation.longitude}'
      : 'none';
  final dateKey = selectedDate.toIso8601String();
  return 'locations_${locations.length}_${locationIds}_current_${currentLocKey}_date_$dateKey';
}

/// A provider that generates and caches marker bitmaps.
/// This is the expensive part that should only run when location data changes.
final cachedMarkerBitmapsProvider =
    FutureProvider<CachedMarkersState>((ref) async {
  // OPTIMIZED: Use select() to only rebuild when locations or currentLocation change
  final locationsForDate = ref.watch(
      locationsForSelectedDateProvider); // This will now be the optimized list if available
  final selectedDate = ref.watch(selectedDateProvider);
  final tripState = ref.watch(tripProvider);
  final currentLocation =
      ref.watch(tripProvider.select((state) => state.currentLocation));
  final isDarkMode = ref.watch(themeProvider) == ThemeMode.dark;

  final cacheKey = _generateLocationsCacheKey(
      locationsForDate, currentLocation, selectedDate);

  // DEBUG: Uncomment to track marker generation
  // print('🎨 Generating cached markers - locations: ${pinnedLocations.length}, showNames: $showPlaceNames');

  final Map<String, MarkerBitmapResult> markerIcons = {};
  final markerCache = MarkerCacheService();

  if (currentLocation != null) {
    final currentLocationIcon = await markerCache.getCurrentLocationMarker();
    markerIcons['current_location'] = currentLocationIcon;
  }

  // OPTIMIZED: Use batch marker generation for better performance
  int nonSkippedIndex =
      0; // This index will now correctly reflect the optimized order
  for (final location in locationsForDate) {
    // Iterate over the correctly ordered list
    int markerNumber;

    // Check if this location is the designated start location for the route
    final isStartLocation = tripState.optimizedRoute.isNotEmpty &&
        tripState.startLocationId == location.id;

    if (isStartLocation) {
      markerNumber = 0; // Use 0 to signify the start location
    }
    if (location.isSkipped) {
      markerNumber =
          -1; // Use -1 to indicate a skipped location to the marker service
    } else {
      nonSkippedIndex++;
      markerNumber = nonSkippedIndex;
    }

    final customIconResult = await markerCache.getNumberedMarker(
      isStart: isStartLocation,
      number: markerNumber,
      name: location.name,
      backgroundColor: AppTheme.accentColor,
      textColor: Colors.white,
      isDarkMode: isDarkMode,
      isSkipped: location.isSkipped, // Pass the skipped status
    );

    markerIcons[location.id] = customIconResult;
  }

  // DEBUG: Uncomment to track marker generation completion
  // print('✅ Generated ${markers.length} cached markers');

  return CachedMarkersState(markerIcons: markerIcons, cacheKey: cacheKey);
});

/// A lightweight provider that assembles the final Marker set.
/// It watches the marker bitmaps and the `showPlaceNamesProvider`.
/// This provider rebuilds instantly when names are toggled, without re-running the expensive bitmap generation.
final finalMarkersProvider = Provider<Set<Marker>>((ref) {
  final markerBitmapsAsync = ref.watch(cachedMarkerBitmapsProvider);
  final showPlaceNames =
      ref.watch(showPlaceNamesProvider); // This watch is crucial
  final locationsForDate = ref.watch(locationsForSelectedDateProvider);
  final currentLocation =
      ref.watch(tripProvider.select((s) => s.currentLocation));

  debugPrint('finalMarkersProvider: Building ${locationsForDate.length} markers (${locationsForDate.where((l) => !l.isSkipped).length} active)');

  return markerBitmapsAsync.when(
    data: (cachedData) {
      final Set<Marker> markers = {};
      final markerIcons = cachedData.markerIcons;

      // Add current location marker
      if (currentLocation != null &&
          markerIcons.containsKey('current_location')) {
        final result = markerIcons['current_location']!;
        markers.add(Marker(
          markerId: const MarkerId('current_location'),
          position: currentLocation,
          icon: result.bitmap,
          anchor: result.anchor,
          infoWindow: const InfoWindow(title: 'Your Location'),
        ));
      }

      // Add location markers
      for (final location in locationsForDate) {
        if (markerIcons.containsKey(location.id)) {
          final result = markerIcons[location.id]!;
          markers.add(Marker(
            markerId: MarkerId(location.id),
            position: location.coordinates,
            icon: result.bitmap,
            anchor: result.anchor,
            infoWindow: showPlaceNames
                ? InfoWindow(title: location.name, snippet: location.address)
                : InfoWindow.noText,
          ));
        }
      }
      debugPrint('finalMarkersProvider: Created ${markers.length} total markers');
      return markers;
    },
    loading: () => {},
    error: (e, s) => {},
  );
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

final memoizedAutomaticZonesProvider = Provider<Set<Circle>>((ref) {
  // Watch all locations and the selected date to filter them.
  final allLocations =
      ref.watch(tripProvider.select((state) => state.pinnedLocations));
  final selectedDate = ref.watch(selectedDateProvider);
  final threshold = ref.watch(proximityThresholdCommittedProvider);

  // Filter locations to only include those for the selected date and are not skipped.
  final locationsForDate = allLocations.where((loc) {
    if (loc.isSkipped) return false;

    // This logic now mirrors `locationsForSelectedDateProvider` exactly.
    if (loc.scheduledDate == null) {
      final addedAtDate =
          DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
      return selectedDate.isAtSameMomentAs(addedAtDate);
    }
    final locDate = loc.scheduledDate!;
    final scheduledDateAtMidnight =
        DateTime(locDate.year, locDate.month, locDate.day);
    return selectedDate.isAtSameMomentAs(scheduledDateAtMidnight);
  }).toList();

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
  final tappedPolylineId = ref.watch(tappedPolylineIdProvider);

  // DEBUG: Uncomment to track polyline styling
  // print('🎨 Styling ${tripState.legPolylines.length} polylines, highlighted: $tappedPolylineId, optimized locations: ${tripState.optimizedLocationsForSelectedDate.length}');

  final Set<Polyline> polylines = {};

  // The legPolylines are generated based on tripState.optimizedLocationsForSelectedDate.
  // So, we should use that list for checking bounds.
  final List<LocationModel> currentOptimizedLocations =
      tripState.optimizedLocationsForSelectedDate;

  // We iterate through the legs of the route. The number of legs should equal
  // the number of segments between locations (n locations = n-1 legs, or n legs if starting from current location).
  for (int i = 0; i < tripState.legPolylines.length; i++) {
    // Ensure we have a valid leg polyline.
    // The legPolylines array should contain all legs from the route, including the final leg to the destination.
    if (currentOptimizedLocations.isEmpty) {
      continue;
    }

    final legPoints = tripState.legPolylines[i];
    if (legPoints.isNotEmpty) {
      final polylineId = 'leg_$i';
      final isHighlighted = tappedPolylineId == polylineId;

      // PROFESSIONAL ROUTE STYLING: Beautiful, crisp polylines with smooth transitions
      // The Google Maps SDK handles the visual transitions smoothly without reloading the map

      // Add shadow/outline polyline for depth effect
      polylines.add(
        Polyline(
          polylineId: PolylineId('${polylineId}_shadow'),
          points: legPoints,
          color: Colors.black.withValues(alpha: isHighlighted ? 0.2 : 0.12),
          width: isHighlighted ? 10 : 8,
          consumeTapEvents: false,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
          geodesic: true,
          zIndex: 1,
        ),
      );

      // Main polyline with professional styling
      polylines.add(
        Polyline(
          polylineId: PolylineId(polylineId),
          points: legPoints,
          // Grey when not clicked, vibrant primary color when highlighted
          color: isHighlighted
              ? AppTheme.primaryColor
              : Colors.grey.shade500,
          // Professional width: thicker when highlighted
          width: isHighlighted ? 8 : 6,
          // No patterns for cleaner, more professional look
          patterns: [],
          // Ensure tap events are captured for interaction
          consumeTapEvents: true,
          onTap: () {
            ref.read(mapUIStateProvider.notifier).setTappedPolyline(polylineId);
          },
          // Round caps for smooth, professional appearance
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          // Round joints for smooth corners
          jointType: JointType.round,
          // Geodesic for accurate path representation
          geodesic: true,
          // Higher z-index for main polyline
          zIndex: isHighlighted ? 10 : 5,
        ),
      );

      // Add white inner line for highlighted route (creates a bordered effect)
      if (isHighlighted) {
        polylines.add(
          Polyline(
            polylineId: PolylineId('${polylineId}_border'),
            points: legPoints,
            color: Colors.white.withValues(alpha: 0.4),
            width: 3,
            consumeTapEvents: false,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
            geodesic: true,
            zIndex: 11,
          ),
        );
      }
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
  final legIndex =
      int.tryParse(tappedPolylineId.replaceFirst('leg_', '')) ?? -1;

  // Ensure the leg index is valid.
  if (legIndex < 0 ||
      legIndex >= tripState.legDetails.length ||
      legIndex >= tripState.legPolylines.length) {
    return {};
  }

  final legPoints = tripState.legPolylines[legIndex];
  if (legPoints.isEmpty) return {};

  // Calculate midpoint for marker placement.
  final midIndex = legPoints.length ~/ 2;
  final midpoint = legPoints[midIndex];

  final markerCache = MarkerCacheService();
  final result = await markerCache.getGoogleMapsButtonMarker();

  return {
    Marker(
        markerId: MarkerId('route_info_$legIndex'),
        position: midpoint,
        icon: result.bitmap,
        anchor: result.anchor,
        zIndex: 10,
        consumeTapEvents: true,
        onTap: () {
          final start = legPoints.first;
          final end = legPoints.last;
          _launchMapsUrl(start, end);
        })
  };
});

Future<void> _launchMapsUrl(LatLng origin, LatLng destination) async {
  // For mobile devices, use the comgooglemaps:// URL scheme which opens Google Maps app directly
  // For web/desktop, fall back to https:// URL

  // First, try the Google Maps app URL scheme (works on both Android and iOS)
  final mapsAppUrl = Uri.parse(
    'comgooglemaps://?saddr=${origin.latitude},${origin.longitude}&daddr=${destination.latitude},${destination.longitude}&directionsmode=driving',
  );

  try {
    // Try to launch Google Maps app first
    if (await canLaunchUrl(mapsAppUrl)) {
      await launchUrl(mapsAppUrl, mode: LaunchMode.externalApplication);
      return;
    }
  } catch (e) {
    debugPrint('Google Maps app not available, trying web URL: $e');
  }

  // Fallback to web URL (works universally but opens in browser or maps app depending on platform)
  final webUrl = Uri.parse(
    'https://www.google.com/maps/dir/?api=1&origin=${origin.latitude},${origin.longitude}&destination=${destination.latitude},${destination.longitude}&travelmode=driving',
  );

  try {
    if (await canLaunchUrl(webUrl)) {
      await launchUrl(webUrl, mode: LaunchMode.externalApplication);
    } else {
      debugPrint('Could not launch maps URL');
    }
  } catch (e) {
    debugPrint('Error launching maps: $e');
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

final assembledMapOverlaysProvider =
    Provider<AsyncValue<AssembledMapOverlays>>((ref) {
  final markers = ref.watch(finalMarkersProvider);
  final polylines = ref.watch(styledPolylinesProvider);
  final automaticZones = ref.watch(memoizedAutomaticZonesProvider);
  final routeInfoMarkersAsync = ref.watch(routeInfoMarkersProvider);

  // Since finalMarkersProvider is synchronous (deriving from an async one),
  // we can treat it more directly. We'll use the async state of the bitmap provider to manage loading/error states.
  return ref.watch(cachedMarkerBitmapsProvider).when(
    data: (_) {
      // We don't need the data here, just the state.
      final routeInfoMarkers = routeInfoMarkersAsync.valueOrNull ?? {};

      // DEBUG: Uncomment to track overlay assembly
      // print('✅ Assembling map overlays: ${markers.length} base markers, ${routeInfoMarkers.length} route info markers, ${polylines.length} polylines, ${automaticZones.length} auto zones');

      return AsyncValue.data(AssembledMapOverlays(
        markers: {...markers, ...routeInfoMarkers},
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
