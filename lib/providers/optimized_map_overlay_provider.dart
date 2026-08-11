import 'dart:math' as math;

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
  // provider needn't watch the live position at all. Two variants: plain
  // dot, and dot + heading beam (aimed downstream via Marker.rotation, so
  // neither bitmap ever regenerates as the device moves or turns).
  markerIcons['current_location'] =
      await markerCache.getCurrentLocationMarker();
  markerIcons['current_location_heading'] =
      await markerCache.getCurrentLocationHeadingMarker();
  markerIcons['leg_endpoint'] = await markerCache.getLegEndpointDot();

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
      // The start pin says so in words — the flag alone read as "just
      // another marker" and its numbering confused the map↔list mapping.
      name: spec.isStart ? '${spec.loc.name} (Start here)' : spec.loc.name,
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
  // Compass heading for the beam. Already noise-gated at the source
  // (MapScreen writes it only on ≥3° changes), so each emission here is a
  // real turn of the device — one cheap marker-set reassembly, one
  // single-marker rotation diff on the platform side.
  final deviceHeading = ref.watch(deviceHeadingProvider);
  // Leg geometry for the endpoint collars — changes on optimize only.
  final dotLegPolylines = ref.watch(tripProvider.select((s) => s.legPolylines));
  final dotLegDetails = ref.watch(tripProvider.select((s) => s.legDetails));

  return markerBitmapsAsync.when(
    // During a RELOAD (background sync updates locations), keep showing the
    // previous markers instead of flashing empty.  Only the very first load
    // (no previous data) calls loading(), and the overlay covers that period.
    skipLoadingOnReload: true,
    data: (cachedData) {
      final Set<Marker> markers = {};
      final markerIcons = cachedData.markerIcons;

      // Add current location marker — beam variant when a compass heading
      // exists, plain dot otherwise (simulator, missing magnetometer).
      if (currentLocation != null &&
          markerIcons.containsKey('current_location')) {
        final hasHeading = deviceHeading != null &&
            markerIcons.containsKey('current_location_heading');
        final result = hasHeading
            ? markerIcons['current_location_heading']!
            : markerIcons['current_location']!;
        markers.add(Marker(
          markerId: const MarkerId('current_location'),
          position: currentLocation,
          icon: result.bitmap,
          anchor: result.anchor,
          // flat + rotation = the Google-Maps beam: the wedge lies on the
          // map surface aimed at the real-world compass heading, so it stays
          // correct when the user rotates the camera. Rotation happens on
          // the platform side — no bitmap work per tick.
          flat: hasHeading,
          rotation: hasHeading ? deviceHeading : 0.0,
          infoWindow: const InfoWindow(title: 'Your Location'),
        ));
      }

      // Google-style white collars at leg boundaries and transit junctions
      // (board/alight points). Skipped wherever a numbered pin already sits
      // — they mark stations and hand-off points, not stops.
      final endpointIcon = markerIcons['leg_endpoint'];
      if (endpointIcon != null && dotLegPolylines.isNotEmpty) {
        bool nearAPin(LatLng p) => locationsForDate.any((l) =>
            (l.coordinates.latitude - p.latitude).abs() < 0.00015 &&
            (l.coordinates.longitude - p.longitude).abs() < 0.00015);
        final seen = <String>{};
        void addDot(LatLng p) {
          if (nearAPin(p)) return;
          final key = '${p.latitude.toStringAsFixed(5)},'
              '${p.longitude.toStringAsFixed(5)}';
          if (!seen.add(key)) return;
          markers.add(Marker(
            markerId: MarkerId('leg_dot_$key'),
            position: p,
            icon: endpointIcon.bitmap,
            anchor: endpointIcon.anchor,
            zIndexInt: 1,
          ));
        }

        for (var i = 0; i < dotLegPolylines.length; i++) {
          final steps = i < dotLegDetails.length
              ? (dotLegDetails[i]['transitSteps'] as List?)
              : null;
          if (steps != null && steps.isNotEmpty) {
            for (final run in steps) {
              final pts = ((run as Map)['points'] as List).cast<LatLng>();
              if (pts.isEmpty) continue;
              addDot(pts.first);
              addDot(pts.last);
            }
          } else {
            final pts = dotLegPolylines[i];
            if (pts.isEmpty) continue;
            addDot(pts.first);
            addDot(pts.last);
          }
        }
      }

      // Add location markers — explicitly ABOVE the leg-endpoint collars
      // (zIndexInt 1): a collar landing near a pin must never cover its
      // index number.
      for (final location in locationsForDate) {
        if (markerIcons.containsKey(location.id)) {
          final result = markerIcons[location.id]!;
          markers.add(Marker(
            markerId: MarkerId(location.id),
            position: location.coordinates,
            icon: result.bitmap,
            anchor: result.anchor,
            zIndexInt: 2,
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

/// '#RRGGBB' (Routes API transit line colors) → Color; null on any junk.
Color? _parseLineColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final cleaned = hex.replaceFirst('#', '');
  if (cleaned.length != 6) return null;
  final value = int.tryParse(cleaned, radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

final styledPolylinesProvider = Provider<Set<Polyline>>((ref) {
  // Narrow watches (moving-pin hygiene): a full tripProvider watch made
  // every GPS tick re-style the polylines via currentLocation.
  final legPolylinesState =
      ref.watch(tripProvider.select((s) => s.legPolylines));
  final legDetailsState = ref.watch(tripProvider.select((s) => s.legDetails));
  final optimizedForDate = ref
      .watch(tripProvider.select((s) => s.optimizedLocationsForSelectedDate));
  final tappedPolylineId = ref.watch(tappedPolylineIdProvider);

  // DEBUG: Uncomment to track polyline styling
  // debugPrint('🎨 Styling ${legPolylinesState.length} polylines, highlighted: $tappedPolylineId');

  final Set<Polyline> polylines = {};

  // The legPolylines are generated based on tripState.optimizedLocationsForSelectedDate.
  // So, we should use that list for checking bounds.
  final List<LocationModel> currentOptimizedLocations = optimizedForDate;

  // We iterate through the legs of the route. The number of legs should equal
  // the number of segments between locations (n locations = n-1 legs, or n legs if starting from current location).
  for (int i = 0; i < legPolylinesState.length; i++) {
    // Ensure we have a valid leg polyline.
    // The legPolylines array should contain all legs from the route, including the final leg to the destination.
    if (currentOptimizedLocations.isEmpty) {
      continue;
    }

    final legPoints = legPolylinesState[i];
    if (legPoints.isNotEmpty) {
      final polylineId = 'leg_$i';
      final isHighlighted = tappedPolylineId == polylineId;

      // ── Multi-modal styling — the industry grammar users already read:
      // walk = dotted · transit = solid in the LINE's official color ·
      // bike/moto = long dashes · drive = solid neutral/brand ·
      // direct (no route found in any mode) = faint dashes.
      // Patterns render platform-side: zero per-frame cost.
      final mode = i < legDetailsState.length
          ? (legDetailsState[i]['mode'] as String? ?? 'drive')
          : 'drive';
      Color? transitColor;
      if (mode == 'transit' && i < legDetailsState.length) {
        final segs = legDetailsState[i]['transit'] as List?;
        if (segs != null && segs.isNotEmpty) {
          transitColor =
              _parseLineColor((segs.first as Map)['lineColor'] as String?);
        }
      }
      // NO PatternItem.dot anywhere: the iOS plugin maps each pattern item
      // to a style span of `length ?: 0` — a dot has no length, so dotted
      // lines rendered as ZERO visible pixels on iPhone (walking legs
      // simply vanished). Short round-capped dashes read as dots and carry
      // an explicit length on both platforms.
      final patterns = switch (mode) {
        // Walk: tight dot-like dashes. Bike/moto: long-short "dash-dot"
        // rhythm so it can't be mistaken for walking at a glance.
        'walk' => <PatternItem>[PatternItem.dash(8), PatternItem.gap(11)],
        'bicycle' || 'two_wheeler' => <PatternItem>[
            PatternItem.dash(28),
            PatternItem.gap(9),
            PatternItem.dash(7),
            PatternItem.gap(9),
          ],
        'direct' => <PatternItem>[PatternItem.dash(14), PatternItem.gap(12)],
        _ => const <PatternItem>[],
      };
      final hasPattern = patterns.isNotEmpty;

      // ── Transit legs with step geometry: Google's grammar, properly ──
      // A transit leg is walk → ride → walk. Drawing it as ONE solid line
      // in the ride's color made the vaporetto appear to depart from the
      // user's feet. Each run gets its own polyline AND its own tap
      // identity ('leg_i_sj'): tapping a run highlights JUST that run and
      // surfaces a chip describing it (walk to the station / the ride
      // between its two stops) — routeInfoMarkersProvider decodes the id.
      // Walk CONNECTORS are deliberately quieter than a standalone walking
      // leg (thinner, tighter dots, translucent): they're an approach to
      // the ride, not a route of their own, and styling them identically
      // made a "walk to the station" read as a full A→B walking route.
      final transitSteps = mode == 'transit' && i < legDetailsState.length
          ? (legDetailsState[i]['transitSteps'] as List?)
          : null;
      if (transitSteps != null && transitSteps.isNotEmpty) {
        for (var j = 0; j < transitSteps.length; j++) {
          final run = transitSteps[j] as Map;
          final runPoints = (run['points'] as List).cast<LatLng>();
          if (runPoints.isEmpty) continue;
          final runId = '${polylineId}_s$j';
          final isRunSelected = tappedPolylineId == runId;
          // Leg-level selection (chip "Show on map") still lights the whole
          // journey; a run tap lights only that run.
          final emphasized = isRunSelected || isHighlighted;
          final isRide = run['mode'] == 'TRANSIT';
          final runColor = isRide
              ? (_parseLineColor(run['lineColor'] as String?) ??
                  transitColor ??
                  AppTheme.primaryColor)
              : Colors.white.withValues(alpha: emphasized ? 0.95 : 0.55);
          if (isRide) {
            polylines.add(
              Polyline(
                polylineId: PolylineId('${runId}_shadow'),
                points: runPoints,
                color: Colors.black.withValues(alpha: emphasized ? 0.2 : 0.12),
                width: emphasized ? 10 : 9,
                consumeTapEvents: false,
                startCap: Cap.roundCap,
                endCap: Cap.roundCap,
                jointType: JointType.round,
                geodesic: true,
                zIndex: 1,
              ),
            );
          }
          polylines.add(
            Polyline(
              polylineId: PolylineId(runId),
              points: runPoints,
              color: runColor,
              width: isRide
                  ? (isRunSelected ? 9 : (isHighlighted ? 8 : 7))
                  : (emphasized ? 6 : 4),
              // dash, not dot — see the pattern comment above (iOS renders
              // dots as zero-length spans = invisible). Connector dots are
              // tighter/shorter than walking-leg dots on purpose.
              patterns: isRide
                  ? const <PatternItem>[]
                  : <PatternItem>[PatternItem.dash(4), PatternItem.gap(9)],
              consumeTapEvents: true,
              onTap: () {
                ref.read(mapUIStateProvider.notifier).setTappedPolyline(runId);
              },
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
              jointType: JointType.round,
              geodesic: true,
              zIndex: isRunSelected ? 12 : (isRide ? (emphasized ? 10 : 6) : 5),
            ),
          );
          // Selected ride gets the same white inner border the whole-leg
          // selection uses — "this exact segment" reads instantly.
          if (isRunSelected && isRide) {
            polylines.add(
              Polyline(
                polylineId: PolylineId('${runId}_border'),
                points: runPoints,
                color: Colors.white.withValues(alpha: 0.4),
                width: 3,
                consumeTapEvents: false,
                startCap: Cap.roundCap,
                endCap: Cap.roundCap,
                jointType: JointType.round,
                geodesic: true,
                zIndex: 13,
              ),
            );
          }
        }
        continue;
      }

      // Shadow under solid lines only — a solid shadow beneath a dotted
      // walk line read as a second (phantom) route.
      if (!hasPattern) {
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
      }

      // Main polyline with professional styling
      polylines.add(
        Polyline(
          polylineId: PolylineId(polylineId),
          points: legPoints,
          // Tapped vs untapped must be unmistakable: an untapped leg is
          // neutral grey, the tapped one is the brand color (plus extra
          // width and the white inner border added below). Transit keeps
          // its line's official color in BOTH states — the line identity
          // is the information — and selection shows via width + border.
          color: transitColor ??
              (mode == 'direct'
                  ? const Color(0x66B9C1CC)
                  : isHighlighted
                      ? AppTheme.primaryColor
                      : const Color(0xFFB9C1CC)),
          // Professional width: thicker when highlighted
          width: isHighlighted ? 8 : (mode == 'transit' ? 7 : 6),
          patterns: patterns,
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
    this.legIndex = -1,
    this.mode = 'drive',
    this.transit,
  });

  final LocationModel origin;
  final LocationModel destination;
  final String distanceLabel;
  final String? durationLabel;

  /// Index into tripState.legDetails/legPolylines — the mode switcher needs
  /// it to re-route exactly this leg. -1 for previews with no leg identity.
  final int legIndex;
  final String mode;
  final List<Map<String, dynamic>>? transit;
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

  // Narrow watches — same reasoning as styledPolylinesProvider above.
  final legDetailsState = ref.watch(tripProvider.select((s) => s.legDetails));
  final legPolylinesState =
      ref.watch(tripProvider.select((s) => s.legPolylines));
  final orderedForDate = ref
      .watch(tripProvider.select((s) => s.optimizedLocationsForSelectedDate));
  final startLocationIdState =
      ref.watch(tripProvider.select((s) => s.startLocationId));
  // 'leg_3' selects the whole leg; 'leg_3_s1' selects one RUN of a transit
  // leg (a walk connector or a ride) — the chip then describes just that
  // run instead of the whole journey.
  final idMatch =
      RegExp(r'^leg_(\d+)(?:_s(\d+))?$').firstMatch(tappedPolylineId);
  final legIndex = idMatch == null ? -1 : int.parse(idMatch.group(1)!);
  final int? runIndex =
      idMatch?.group(2) == null ? null : int.parse(idMatch!.group(2)!);

  // Ensure the leg index is valid.
  if (legIndex < 0 ||
      legIndex >= legDetailsState.length ||
      legIndex >= legPolylinesState.length) {
    return {};
  }

  final legPoints = legPolylinesState[legIndex];
  if (legPoints.isEmpty) return {};

  // Calculate midpoint for marker placement.
  final midIndex = legPoints.length ~/ 2;
  final midpoint = legPoints[midIndex];

  // Format distance label from legDetails
  final legData = legDetailsState[legIndex];
  final distanceMeters = (legData['distance'] as num?)?.toDouble() ?? 0.0;
  final String distanceLabel = distanceMeters >= 1000
      ? '${(distanceMeters / 1000).toStringAsFixed(1)} km'
      : '${distanceMeters.round()} m';
  final legDuration = legData['duration'] as Duration?;
  final String? durationLabel =
      legDuration == null ? null : formatLegDuration(legDuration);

  final start = legPoints.first;
  final end = legPoints.last;

  // Resolve the leg's start/end LocationModels — the chip prints their names
  // ("A → B") and the external-app handoff uses place_id + originalName
  // instead of bare coordinates. Index mapping mirrors
  // _performRouteOptimization in trip_provider.dart:
  //   - When startLocationId == 'current_location', `optimizedLocationsForSelectedDate`
  //     contains only the waypoints (no start), so leg i goes from
  //     [i-1] → [i], and leg 0's "from" is the device's current position
  //     (no LocationModel, falls back to coords).
  //   - Otherwise, the start stop is at index 0, so leg i goes from
  //     [i] → [i+1].
  final ordered = orderedForDate;
  final isStartCurrentLocation = startLocationIdState == 'current_location';
  final fromIdx = isStartCurrentLocation ? legIndex - 1 : legIndex;
  final toIdx = isStartCurrentLocation ? legIndex : legIndex + 1;
  // Out-of-range indices fall back to the leg's own ids before bare
  // coordinates — the loop-home return leg points BACK to the day's first
  // stop (the accommodation), which positional math can't reach.
  LocationModel resolveById(String? id, LocationModel fallback) {
    if (id == null) return fallback;
    for (final l in ordered) {
      if (l.id == id) return l;
    }
    return fallback;
  }

  final fromLoc = (fromIdx >= 0 && fromIdx < ordered.length)
      ? ordered[fromIdx]
      : resolveById(legData['fromId'] as String?, _coordOnlyLocation(start));
  final toLoc = (toIdx >= 0 && toIdx < ordered.length)
      ? ordered[toIdx]
      : resolveById(legData['toId'] as String?, _coordOnlyLocation(end));

  final markerCache = MarkerCacheService();
  // ONE compact chip on the polyline: [mode glyph] 4.4 km · 12 min (>) with
  // "From → To" beneath — walk/boat/bus/train glyph per leg, plus the
  // transit line's colored badge (Google's "[2]") when the leg rides one.
  // Bitmap cached per (mode, badge, labels, endpoints), so a given chip
  // rasterizes once. A nameless endpoint (leg 0 from the device position)
  // prints as "Your location".
  final legMode = legData['mode'] as String? ?? 'drive';
  final transitSegs = legData['transit'] as List?;
  final firstSeg = (transitSegs != null && transitSegs.isNotEmpty)
      ? transitSegs.first as Map
      : null;

  // Defaults describe the WHOLE leg; a run tap swaps in that run's story.
  var chipPosition = midpoint;
  var chipMode = legMode;
  String? chipVehicleType = firstSeg?['vehicleType'] as String?;
  String? chipBadgeText = firstSeg?['lineShort'] as String?;
  Color? chipBadgeColor = _parseLineColor(firstSeg?['lineColor'] as String?);
  var chipDistanceLabel = distanceLabel;
  String? chipDurationLabel = durationLabel;
  var chipFromName = fromLoc.name.isEmpty ? 'Your location' : fromLoc.name;
  var chipToName = toLoc.name.isEmpty ? 'Your location' : toLoc.name;

  // ── Per-run chip: "walk to the station" / "the ride between two stops".
  // Stop names come from the ride cards (boardStop/alightStop). A walk
  // connector borrows its far end from the neighbouring ride, so the text
  // literally says where the walk is taking you — e.g.
  // "Pavilion KL → Raja Chulan" for the approach walk, then
  // "Raja Chulan → Batu Caves" for the ride itself.
  final transitRuns = legData['transitSteps'] as List?;
  if (runIndex != null &&
      transitRuns != null &&
      runIndex >= 0 &&
      runIndex < transitRuns.length) {
    final run = transitRuns[runIndex] as Map;
    final runPoints = (run['points'] as List).cast<LatLng>();
    if (runPoints.isNotEmpty) {
      chipPosition = runPoints[runPoints.length ~/ 2];
      final isRide = run['mode'] == 'TRANSIT';
      chipMode = isRide ? 'transit' : 'walk';
      chipVehicleType = isRide ? run['vehicleType'] as String? : null;
      chipBadgeText = isRide ? run['lineShort'] as String? : null;
      chipBadgeColor =
          isRide ? _parseLineColor(run['lineColor'] as String?) : null;
      // Per-run distance isn't in the API payload — derive it from the
      // run's own geometry.
      final meters = _polylineMeters(runPoints);
      chipDistanceLabel = meters >= 1000
          ? '${(meters / 1000).toStringAsFixed(1)} km'
          : '${meters.round()} m';
      final secs = (run['durationSeconds'] as num?)?.toInt();
      chipDurationLabel =
          secs == null ? null : formatLegDuration(Duration(seconds: secs));

      // Ride ordinal = how many TRANSIT runs precede this one — pairs a run
      // with its ride card, which carries the stop names.
      String? boardOf(int k) =>
          (transitSegs != null && k >= 0 && k < transitSegs.length)
              ? (transitSegs[k] as Map)['boardStop'] as String?
              : null;
      String? alightOf(int k) =>
          (transitSegs != null && k >= 0 && k < transitSegs.length)
              ? (transitSegs[k] as Map)['alightStop'] as String?
              : null;
      var ridesBefore = 0;
      for (var r = 0; r < runIndex; r++) {
        if ((transitRuns[r] as Map)['mode'] == 'TRANSIT') ridesBefore++;
      }
      String nonEmpty(String? s, String fallback) =>
          (s == null || s.isEmpty) ? fallback : s;
      if (isRide) {
        chipFromName = nonEmpty(boardOf(ridesBefore), chipFromName);
        chipToName = nonEmpty(alightOf(ridesBefore), chipToName);
      } else {
        // Walk connector: from the previous ride's alight stop (or the leg
        // origin when it's the first run) to the next ride's board stop (or
        // the leg destination when it's the last).
        chipFromName = nonEmpty(alightOf(ridesBefore - 1), chipFromName);
        chipToName = nonEmpty(boardOf(ridesBefore), chipToName);
      }
    }
  }

  final chipResult = await markerCache.getRouteLegChipMarker(
    distanceLabel: chipDistanceLabel,
    durationLabel: chipDurationLabel,
    mode: chipMode,
    vehicleType: chipVehicleType,
    badgeText: chipBadgeText,
    badgeColor: chipBadgeColor,
    fromName: chipFromName,
    toName: chipToName,
  );

  // anchor=(0.5, 0.5) → the chip straddles the tapped geometry's midpoint
  // (the leg's, or the tapped run's), so the line reads through on both
  // sides of it. Tapping the chip always opens the FULL leg sheet — the
  // run chip is a caption, the sheet is the journey.
  return {
    Marker(
        markerId: MarkerId('route_leg_chip_$legIndex'),
        position: chipPosition,
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
            legIndex: legIndex,
            mode: legMode,
            transit: transitSegs?.cast<Map<String, dynamic>>(),
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

/// Total ground length of a polyline in meters (haversine per segment) —
/// per-run distances aren't in the API payload, so the run chip derives
/// them from geometry.
double _polylineMeters(List<LatLng> pts) {
  const r = 6371000.0;
  var total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final dLat = (b.latitude - a.latitude) * math.pi / 180.0;
    final dLng = (b.longitude - a.longitude) * math.pi / 180.0;
    final la1 = a.latitude * math.pi / 180.0;
    final la2 = b.latitude * math.pi / 180.0;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la1) * math.cos(la2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    total += 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
  }
  return total;
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
