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
import '../utils/external_app_links.dart';
import '../core/theme.dart';

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
  final locationIds =
      locations.map((l) => '${l.id}-${l.isSkipped}-${l.isDone}').join('_');
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
  final locationsForDate = ref.watch(
      locationsForSelectedDateProvider); // This will now be the optimized list if available
  final selectedDate = ref.watch(selectedDateProvider);
  // NARROW watches (pin-appearance fix): this used to watch the ENTIRE
  // tripProvider plus the live GPS position — every location tick and any
  // trip-state mutation re-ran the whole bitmap pass. Only two fields
  // actually influence the bitmaps:
  final routeActive =
      ref.watch(tripProvider.select((s) => s.optimizedRoute.isNotEmpty));
  final startLocationId =
      ref.watch(tripProvider.select((s) => s.startLocationId));
  final isDarkMode = ref.watch(themeProvider) == ThemeMode.dark;

  // currentLocation deliberately excluded from the key: the marker's
  // POSITION is applied downstream in finalMarkersProvider — its ICON is
  // static, so the moving dot must not invalidate this cache.
  final cacheKey =
      _generateLocationsCacheKey(locationsForDate, null, selectedDate);

  final Map<String, MarkerBitmapResult> markerIcons = {};
  final markerCache = MarkerCacheService();

  // Static, cached after first build — generated unconditionally so this
  // provider needn't watch the live position at all.
  markerIcons['current_location'] =
      await markerCache.getCurrentLocationMarker();

  // Numbering is order-dependent → compute it synchronously first, THEN
  // rasterize every bitmap in PARALLEL. The serial awaits here were the
  // "pins take seconds to appear" lag: 40 places meant 40 back-to-back
  // canvas→GPU→PNG round-trips.
  var nonSkippedIndex = 0;
  final specs = <({LocationModel loc, int number, bool isStart})>[];
  for (final location in locationsForDate) {
    final isStartLocation = routeActive && startLocationId == location.id;
    int markerNumber;
    if (isStartLocation) {
      markerNumber = 0;
    } else if (location.isDone) {
      markerNumber = -2;
    } else if (location.isSkipped) {
      markerNumber = -1;
    } else {
      nonSkippedIndex++;
      markerNumber = nonSkippedIndex;
    }
    specs.add((loc: location, number: markerNumber, isStart: isStartLocation));
  }

  final results = await Future.wait(specs.map(
    (spec) => markerCache.getNumberedMarker(
      isStart: spec.isStart,
      number: spec.number,
      name: spec.loc.name,
      backgroundColor: AppTheme.accentColor,
      textColor: Colors.white,
      isDarkMode: isDarkMode,
      isSkipped: spec.loc.isSkipped,
      isDone: spec.loc.isDone,
    ),
  ));
  for (var i = 0; i < specs.length; i++) {
    markerIcons[specs[i].loc.id] = results[i];
  }

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

  debugPrint(
      'finalMarkersProvider: Building ${locationsForDate.length} markers (${locationsForDate.where((l) => !l.isSkipped).length} active)');

  return markerBitmapsAsync.when(
    // During a RELOAD (background sync updates locations), keep showing the
    // previous markers instead of flashing empty.  Only the very first load
    // (no previous data) calls loading(), and the overlay covers that period.
    skipLoadingOnReload: true,
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
      debugPrint(
          'finalMarkersProvider: Created ${markers.length} total markers');
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
  // debugPrint('📏 Computing zones with key: $cacheKey');

  if (locationsForDate.isEmpty) {
    return {};
  }

  final zones = ZoneUtils.getZoneCircles(locationsForDate, threshold);

  // DEBUG: Uncomment to track zone generation
  // debugPrint('🏞️ Generated ${zones.length} automatic zone circles');

  return zones;
});

final styledPolylinesProvider = Provider<Set<Polyline>>((ref) {
  final tripState = ref.watch(tripProvider);
  final tappedPolylineId = ref.watch(tappedPolylineIdProvider);

  // DEBUG: Uncomment to track polyline styling
  // debugPrint('🎨 Styling ${tripState.legPolylines.length} polylines, highlighted: $tappedPolylineId, optimized locations: ${tripState.optimizedLocationsForSelectedDate.length}');

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
          // Tapped vs untapped must be unmistakable: an untapped leg is
          // neutral grey, the tapped one is the brand color (plus extra
          // width and the white inner border added below). Same-color
          // opacity tweaks were indistinguishable on a real map.
          color:
              isHighlighted ? AppTheme.primaryColor : const Color(0xFFB9C1CC),
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

/// A leg chip was tapped — MapScreen listens for this and opens
/// [showRouteLegSheet]. Routed through a provider because the markers are
/// built inside a FutureProvider, which has no BuildContext of its own.
class RouteLegSheetRequest {
  const RouteLegSheetRequest({
    required this.origin,
    required this.destination,
    required this.distanceLabel,
    this.durationLabel,
  });

  final LocationModel origin;
  final LocationModel destination;
  final String distanceLabel;
  final String? durationLabel;
}

/// Set by a chip tap, cleared by MapScreen once the sheet is shown.
final routeLegSheetRequestProvider =
    StateProvider<RouteLegSheetRequest?>((_) => null);

/// "12 min" / "1h 5m" — compact enough for the on-map chip.
String formatLegDuration(Duration d) {
  final totalMinutes = d.inMinutes;
  if (totalMinutes < 60) return '$totalMinutes min';
  final h = totalMinutes ~/ 60;
  final m = totalMinutes % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

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

  // Format distance label from legDetails
  final legData = tripState.legDetails[legIndex];
  final distanceMeters = (legData['distance'] as num?)?.toDouble() ?? 0.0;
  final String distanceLabel = distanceMeters >= 1000
      ? '${(distanceMeters / 1000).toStringAsFixed(1)} km'
      : '${distanceMeters.round()} m';
  final legDuration = legData['duration'] as Duration?;
  final String? durationLabel =
      legDuration == null ? null : formatLegDuration(legDuration);

  final markerCache = MarkerCacheService();
  // ONE compact chip on the polyline: [car] 4.4 km · 12 min (>). Replaces
  // the old stacked distance-chip + OPEN MAPS + OPEN GRAB bitmaps, which
  // covered the route the user had just tapped. Actions moved into the leg
  // sheet that this chip opens.
  final chipResult = await markerCache.getRouteLegChipMarker(
    distanceLabel: distanceLabel,
    durationLabel: durationLabel,
  );

  final start = legPoints.first;
  final end = legPoints.last;

  // Resolve the leg's start/end LocationModels so the external-app handoff
  // can use place_id + originalName instead of bare coordinates. Index
  // mapping mirrors _performRouteOptimization in trip_provider.dart:
  //   - When startLocationId == 'current_location', `optimizedLocationsForSelectedDate`
  //     contains only the waypoints (no start), so leg i goes from
  //     [i-1] → [i], and leg 0's "from" is the device's current position
  //     (no LocationModel, falls back to coords).
  //   - Otherwise, the start stop is at index 0, so leg i goes from
  //     [i] → [i+1].
  final ordered = tripState.optimizedLocationsForSelectedDate;
  final isStartCurrentLocation =
      tripState.startLocationId == 'current_location';
  final fromIdx = isStartCurrentLocation ? legIndex - 1 : legIndex;
  final toIdx = isStartCurrentLocation ? legIndex : legIndex + 1;
  final fromLoc = (fromIdx >= 0 && fromIdx < ordered.length)
      ? ordered[fromIdx]
      : _coordOnlyLocation(start);
  final toLoc = (toIdx >= 0 && toIdx < ordered.length)
      ? ordered[toIdx]
      : _coordOnlyLocation(end);

  // anchor=(0.5, 0.5) → the chip straddles the leg midpoint, so the route
  // line reads through on both sides of it.
  return {
    Marker(
        markerId: MarkerId('route_leg_chip_$legIndex'),
        position: midpoint,
        icon: chipResult.bitmap,
        anchor: chipResult.anchor,
        zIndex: 100,
        consumeTapEvents: true,
        onTap: () {
          ref.read(routeLegSheetRequestProvider.notifier).state =
              RouteLegSheetRequest(
            origin: fromLoc,
            destination: toLoc,
            distanceLabel: distanceLabel,
            durationLabel: durationLabel,
          );
        }),
    // ── RIDE PROVIDER BUTTON — DISABLED 2026-08-05 ────────────────────────
    // Was an unconditional "OPEN GRAB" button. Grab only operates in eight
    // SEA countries (SG, MY, ID, TH, VN, PH, MM, KH), so on a Hong Kong (or
    // any non-SEA) trip it deep-linked to an app that cannot serve the city
    // and fell through to an install page for an app useless there.
    //
    // Kept commented rather than deleted: it returns once the country →
    // provider table lands, gated on the leg's country and hidden entirely
    // where no provider is known. openGrabRoute() and
    // MarkerCacheService.getGrabButtonMarker() are intentionally left in
    // place so re-enabling is a matter of uncommenting + adding the gate.
    //
    // Marker(
    //     markerId: MarkerId('route_grab_$legIndex'),
    //     position: midpoint,
    //     icon: grabResult.bitmap,      // grabResult declared above
    //     anchor: grabResult.anchor,    // anchor=(0.5, 0.0) → below midpoint
    //     zIndex: 100,
    //     consumeTapEvents: true,
    //     onTap: () {
    //       openGrabRoute(origin: fromLoc, destination: toLoc);
    //     }),
  };
});

/// Builds a synthetic [LocationModel] from a bare [LatLng] for legs whose
/// "from" side is the device's current position (no saved place_id) — keeps
/// [openDirectionsInGoogleMaps] / [openGrabRoute] callable without
/// nullable params.
LocationModel _coordOnlyLocation(LatLng coord) => LocationModel(
      id: 'leg_anchor',
      name: '',
      address: '',
      coordinates: coord,
      addedAt: DateTime.now(),
    );

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
        skipLoadingOnReload: true,
        data: (_) {
          // We don't need the data here, just the state.
          final routeInfoMarkers = routeInfoMarkersAsync.valueOrNull ?? {};

          // DEBUG: Uncomment to track overlay assembly
          // debugPrint('✅ Assembling map overlays: ${markers.length} base markers, ${routeInfoMarkers.length} route info markers, ${polylines.length} polylines, ${automaticZones.length} auto zones');

          return AsyncValue.data(AssembledMapOverlays(
            markers: {...markers, ...routeInfoMarkers},
            polylines: polylines,
            automaticZones: automaticZones,
          ));
        },
        loading: () {
          // DEBUG: Uncomment to track loading state
          // debugPrint('⏳ Loading markers...');
          return AsyncValue.loading();
        },
        error: (error, stack) {
          // Keep error logging for debugging issues
          debugPrint('❌ Error loading markers: $error');
          return AsyncValue.error(error, stack);
        },
      );
});
