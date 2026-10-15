import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/material.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/theme_provider.dart';
import '../providers/trip_provider.dart';
import 'building_outline_provider.dart';
import '../providers/debounced_settings_provider.dart';
import '../services/marker_cache_service.dart';
import '../utils/zone_utils.dart';
import '../utils/place_tags.dart';
import '../utils/marker_utils.dart';
import '../utils/transit_line_style.dart'; // Needed for MarkerBitmapResult type
import '../utils/polyline_simplify.dart';
import '../utils/external_app_links.dart';
import '../core/theme.dart';
import 'trip_day_labeler_provider.dart';
import 'pin_clock_provider.dart';
import 'trip_simulation_provider.dart';
import '../utils/pin_closing_status.dart';

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
  final locationIds = locations
      .map((l) => '${l.id}-${l.isSkipped}-${l.isDone}-${l.tag ?? ''}')
      .join('_');
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
  markerIcons['transit_stop'] = await markerCache.getTransitStopDot();

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

  // A trip without dates has no weekday: the "might be closed" hint would
  // be noise, so it stays off until dates are set.
  final undated = ref.watch(activeTripDayLabelerProvider).tbd;

  // Opening-hours status per pin (pin_closing_status.dart): judged at the
  // traveller's expected arrival when the plan knows it — the day's
  // simulation, or the ETA of a route from the device — else at the
  // minute clock for today's view. The clock ticks once a minute while the
  // map is shown; the bitmaps are cached by their text, so a tick only
  // rasterizes pins whose line actually changed.
  final now = ref.watch(pinClockProvider);
  final todayView = selectedDate.year == now.year &&
      selectedDate.month == now.month &&
      selectedDate.day == now.day;
  final arrivalById = <String, DateTime>{
    for (final s in ref.watch(tripSimulationProvider)?.stops ?? const [])
      s.locationId: s.arrival,
  };
  final previewTargetId = ref.watch(tripProvider.select((s) =>
      s.isRoutePreview &&
              s.startLocationId == 'current_location' &&
              s.optimizedLocationsForSelectedDate.isNotEmpty
          ? s.optimizedLocationsForSelectedDate.last.id
          : null));
  if (previewTargetId != null) {
    final travel = ref.watch(tripProvider.select((s) =>
        s.legDetails.isNotEmpty ? s.legDetails.first['duration'] : null));
    if (travel is Duration) arrivalById[previewTargetId] = now.add(travel);
  }

  final results = await Future.wait(specs.map((spec) {
    // "Might be closed": Google lists no opening period for this weekday.
    // Amber pin + caution line — phrased as a maybe, because Places hours
    // are often stale. Done/skipped pins keep their own treatment.
    final mightBeClosed = !undated &&
        !spec.loc.isDone &&
        !spec.loc.isSkipped &&
        spec.loc.mightBeClosedOn(selectedDate);
    final status = (spec.loc.isDone || spec.loc.isSkipped)
        ? PinClosingStatus.none
        : pinClosingStatus(
            loc: spec.loc,
            now: now,
            arrival: arrivalById[spec.loc.id],
            todayView: todayView,
          );
    return markerCache.getNumberedMarker(
      isStart: spec.isStart,
      number: spec.number,
      // Sequence numbers mean "visit order" — which only exists once the
      // day is optimized. Before that, pins carry a plain dot.
      showNumber: routeActive,
      // The start pin says so in words — the flag alone read as "just
      // another marker" and its numbering confused the map↔list mapping.
      name: spec.isStart ? '${spec.loc.name} (Start here)' : spec.loc.name,
      // Status first (amber caution; done/skipped inside the builder),
      // then the stop's tag colour, then the coral default.
      backgroundColor: mightBeClosed
          ? MarkerUtils.warningAmber
          : (placeTagColor(spec.loc.tag) ?? AppTheme.accentColor),
      textColor: Colors.white,
      isDarkMode: isDarkMode,
      isSkipped: spec.loc.isSkipped,
      isDone: spec.loc.isDone,
      warningLine:
          mightBeClosed ? 'Might be closed on this date — please check' : null,
      // The hours status outranks the weekday hint: red/yellow name and
      // its line replace the amber caution.
      nameColor: status.isNone ? null : status.color,
      statusLine: status.isNone ? null : status.line,
      statusColor: status.isNone ? null : status.color,
    );
  }));
  for (var i = 0; i < specs.length; i++) {
    markerIcons[specs[i].loc.id] = results[i];
  }

  return CachedMarkersState(markerIcons: markerIcons, cacheKey: cacheKey);
});

/// A lightweight provider that assembles the final Marker set.
/// It watches the marker bitmaps and the `showPlaceNamesProvider`.
/// This provider rebuilds instantly when names are toggled, without re-running the expensive bitmap generation.
/// Label bitmaps for the names of the day's transit stops (board / alight
/// points), keyed by name. Rasterised once per name and theme; the markers
/// themselves are placed by [finalMarkersProvider].
final transitStopLabelsProvider =
    FutureProvider<Map<String, MarkerBitmapResult>>((ref) async {
  final legDetails = ref.watch(tripProvider.select((s) => s.legDetails));
  final isDarkMode = ref.watch(themeProvider) == ThemeMode.dark;
  final names = <String>{};
  for (final leg in legDetails) {
    for (final seg in (leg['transit'] as List?) ?? const []) {
      for (final key in const ['boardStop', 'alightStop']) {
        final name = ((seg as Map)[key] as String?)?.trim();
        if (name != null && name.isNotEmpty) names.add(name);
      }
    }
  }
  if (names.isEmpty) return const {};
  final cache = MarkerCacheService();
  final out = <String, MarkerBitmapResult>{};
  for (final name in names) {
    out[name] = await cache.getStopLabel(name, isDarkMode: isDarkMode);
  }
  return out;
});

final finalMarkersProvider = Provider<Set<Marker>>((ref) {
  final markerBitmapsAsync = ref.watch(cachedMarkerBitmapsProvider);
  final stopLabels =
      ref.watch(transitStopLabelsProvider).valueOrNull ?? const {};
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
  // The selected leg's rides get their intermediate-stop dots (Google's
  // "N stops" beads). Only the selected leg: a transit-heavy day would
  // otherwise bead every line at once, and the dots are there to read
  // the ride you are looking at.
  final tappedLegMatch = RegExp(r'^leg_(\d+)')
      .firstMatch(ref.watch(tappedPolylineIdProvider) ?? '');
  final tappedLeg =
      tappedLegMatch == null ? -1 : int.parse(tappedLegMatch.group(1)!);

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

        // Station names at the board / alight points of every ride, so a
        // transit leg reads on the map as it does in its sheet: where you
        // get on and where you get off. Follows the place-name switch.
        final labelled = <String>{};
        void addStopLabel(LatLng p, String? name) {
          if (!showPlaceNames || name == null) return;
          final text = name.trim();
          if (text.isEmpty || nearAPin(p)) return;
          final icon = stopLabels[text];
          if (icon == null) return;
          final key = '${p.latitude.toStringAsFixed(5)},'
              '${p.longitude.toStringAsFixed(5)}';
          if (!labelled.add(key)) return;
          markers.add(Marker(
            markerId: MarkerId('leg_stop_label_$key'),
            position: p,
            icon: icon.bitmap,
            anchor: icon.anchor,
            zIndexInt: 1,
            consumeTapEvents: false,
          ));
        }

        for (var i = 0; i < dotLegPolylines.length; i++) {
          final steps = i < dotLegDetails.length
              ? (dotLegDetails[i]['transitSteps'] as List?)
              : null;
          if (steps != null && steps.isNotEmpty) {
            // Ride ordinal pairs a run with its ride card, which carries
            // the stop names (same pairing as the chip).
            final rides = (dotLegDetails[i]['transit'] as List?) ?? const [];
            var ride = 0;
            for (final run in steps) {
              final r = run as Map;
              final pts = (r['points'] as List).cast<LatLng>();
              if (pts.isEmpty) continue;
              addDot(pts.first);
              addDot(pts.last);
              if (r['mode'] == 'TRANSIT') {
                if (ride < rides.length) {
                  final seg = rides[ride] as Map;
                  addStopLabel(pts.first, seg['boardStop'] as String?);
                  addStopLabel(pts.last, seg['alightStop'] as String?);
                  final stopIcon = markerIcons['transit_stop'];
                  if (i == tappedLeg && stopIcon != null) {
                    final dots = transitStopDotPositions(
                        pts, (seg['stopCount'] as num?)?.toInt() ?? 0);
                    for (var k = 0; k < dots.length; k++) {
                      markers.add(Marker(
                        markerId: MarkerId('leg_stop_dot_${i}_${ride}_$k'),
                        position: dots[k],
                        icon: stopIcon.bitmap,
                        anchor: stopIcon.anchor,
                        zIndexInt: 1,
                        consumeTapEvents: false,
                      ));
                    }
                  }
                }
                ride++;
              }
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
            // No platform info window: the focused place gets the app's
            // own callout (focusedPlaceCalloutProvider) instead of the
            // white box the platform draws. Also keeps the pin identical
            // whether names are shown or hidden — any change to a pin
            // makes the platform re-apply its icon, and on iOS that
            // redraws the pin, so toggling names made pins blink out.
            infoWindow: InfoWindow.noText,
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
  // The pin status filter hides zones with their pins: a circle around a
  // stop whose pin is filtered out would be an orphan on the map.
  final pinFilter = ref.watch(mapPinFilterProvider);

  // Filter locations to only include those for the selected date and are not skipped.
  final locationsForDate = allLocations.where((loc) {
    if (loc.isSkipped) return false;
    if (!pinMatchesFilter(pinFilter,
        isSkipped: loc.isSkipped, isDone: loc.isDone)) {
      return false;
    }

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

    // Display-only thinning: Google's full-density geometry costs the SDK
    // per vertex per zoom frame (and per dash, for patterned lines).
    final legPoints = simplifyForDisplay(legPolylinesState[i]);
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
      // One colour per line everywhere (map, chip, sheet): the feed's, or
      // the shared transit blue when it publishes none.
      Color? transitColor;
      if (mode == 'transit' && i < legDetailsState.length) {
        final segs = legDetailsState[i]['transit'] as List?;
        transitColor = transitLineFill(
            (segs != null && segs.isNotEmpty) ? segs.first as Map : null);
      }
      // NO PatternItem.dot anywhere: the iOS plugin maps each pattern item
      // to a style span of `length ?: 0` — a dot has no length, so dotted
      // lines rendered as ZERO visible pixels on iPhone (walking legs
      // simply vanished). Short round-capped dashes read as dots and carry
      // an explicit length on both platforms.
      // NO dash pattern on walking legs. Both Maps SDKs re-cut every dash
      // of a patterned polyline on EVERY zoom frame (iOS: one span object
      // per dash; Android: per-segment pattern recompute) — a day of
      // walking routes became thousands of segments rebuilt per frame and
      // the map stuttered on every pinch, on both platforms. Thinner
      // dashes, fewer vertices and a zoom cut-off didn't fix it; only
      // solid strokes do. Walking is now drawn as a solid "footpath" —
      // a dark casing with a thin translucent white core (see below) —
      // still unmistakable next to drive (solid grey) and transit (thick,
      // line-colored). Dashes survive only where they're short and rare:
      // bike/moto legs and the straight-line 'direct' fallback.
      final patterns = switch (mode) {
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
      final isWalk = mode == 'walk';

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
          final runPoints =
              simplifyForDisplay((run['points'] as List).cast<LatLng>());
          if (runPoints.isEmpty) continue;
          final runId = '${polylineId}_s$j';
          final isRunSelected = tappedPolylineId == runId;
          // Leg-level selection (chip "Show on map") still lights the whole
          // journey; a run tap lights only that run.
          final emphasized = isRunSelected || isHighlighted;
          final isRide = run['mode'] == 'TRANSIT';
          final runColor = isRide
              ? transitLineFill(run)
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
                geodesic:
                    false, // road paths, not great circles — no per-segment interpolation
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
              // Solid: connectors are short, but patterned lines are the
              // per-zoom-frame cost class (see the walking-leg note). Their
              // "approach, not a route" read comes from thinness + alpha.
              patterns: const <PatternItem>[],
              consumeTapEvents: true,
              onTap: () => _onLegGeometryTap(ref, runId, i),
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
              jointType: JointType.round,
              geodesic:
                  false, // road paths, not great circles — no per-segment interpolation
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
                geodesic:
                    false, // road paths, not great circles — no per-segment interpolation
                zIndex: 13,
              ),
            );
          }
        }
        continue;
      }

      // Shadow under solid lines only (a shadow beneath a dashed fallback
      // line read as a second, phantom route). For walking it doubles as
      // the footpath's dark casing.
      if (!hasPattern) {
        polylines.add(
          Polyline(
            polylineId: PolylineId('${polylineId}_shadow'),
            points: legPoints,
            color: Colors.black.withValues(
                alpha: isHighlighted ? 0.2 : (isWalk ? 0.22 : 0.12)),
            width: isHighlighted ? 10 : (isWalk ? 7 : 8),
            consumeTapEvents: false,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
            geodesic:
                false, // road paths, not great circles — no per-segment interpolation
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
                      : isWalk
                          // Footpath core: thin, light, translucent — the
                          // pedestrian line next to the car's solid grey.
                          ? Colors.white.withValues(alpha: 0.72)
                          : const Color(0xFFB9C1CC)),
          // Professional width: thicker when highlighted
          width: isHighlighted ? 8 : (mode == 'transit' ? 7 : (isWalk ? 4 : 6)),
          patterns: patterns,
          // Ensure tap events are captured for interaction
          consumeTapEvents: true,
          onTap: () => _onLegGeometryTap(ref, polylineId, i),
          // Round caps for smooth, professional appearance
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          // Round joints for smooth corners
          jointType: JointType.round,
          // Geodesic for accurate path representation
          geodesic:
              false, // road paths, not great circles — no per-segment interpolation
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
            geodesic:
                false, // road paths, not great circles — no per-segment interpolation
            zIndex: 11,
          ),
        );
      }
    }
  }

  // ── Road-to-pin connectors ─────────────────────────────────────────────
  // A leg routed by place id ends at the place's access point, which can
  // sit tens of metres from the pin (the pin marks the place, the road
  // ends at its entrance). A thin line joins the two, as Google Maps does,
  // so the route visibly reaches each stop. Solid, not dotted: patterned
  // lines are the per-zoom-frame cost class. A leg routed by coordinates
  // ends within a few metres of the pin and draws nothing here.
  final startLocationIdState =
      ref.watch(tripProvider.select((s) => s.startLocationId));
  final connectorColor = const Color(0xFF9AA3AE).withValues(alpha: 0.8);
  void connect(String id, LatLng roadEnd, LocationModel stop) {
    if (stop.id == 'leg_anchor' || stop.id == 'current_location') return;
    final d = _metersBetween(roadEnd, stop.coordinates);
    if (d < 12 || d > 1500) return;
    polylines.add(Polyline(
      polylineId: PolylineId(id),
      points: [roadEnd, stop.coordinates],
      color: connectorColor,
      width: 2,
      zIndex: 4,
      consumeTapEvents: false,
      geodesic: false,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
    ));
  }

  for (var i = 0; i < legPolylinesState.length; i++) {
    final pts = legPolylinesState[i];
    if (pts.isEmpty) continue;
    final ends = legEndpointsFor(
      legDetails: legDetailsState,
      legPolylines: legPolylinesState,
      ordered: optimizedForDate,
      startLocationId: startLocationIdState,
      legIndex: i,
    );
    if (ends == null) continue;
    // Every stop is the END of one leg; the day's first stop can also be
    // the start of leg 0 (a day that starts at a saved place).
    if (i == 0) connect('leg_${i}_from_pin', pts.first, ends.from);
    connect('leg_${i}_to_pin', pts.last, ends.to);
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

/// The two stops leg [legIndex] of the day's route runs between. Leg 0
/// starts at the device when the route starts from the current location,
/// in which case the stops are shifted by one. Out-of-range indices fall
/// back to the ids the router recorded on the leg (the loop-home return leg
/// points BACK to the day's first stop, which positional math can't
/// reach), then to a nameless point on the geometry, so a leg can always
/// be described. Null when the index is out of range.
({LocationModel from, LocationModel to})? legEndpointsFor({
  required List<Map<String, dynamic>> legDetails,
  required List<List<LatLng>> legPolylines,
  required List<LocationModel> ordered,
  required String? startLocationId,
  required int legIndex,
}) {
  if (legIndex < 0 ||
      legIndex >= legDetails.length ||
      legIndex >= legPolylines.length) {
    return null;
  }
  final legPoints = legPolylines[legIndex];
  if (legPoints.isEmpty) return null;
  final legData = legDetails[legIndex];
  final isStartCurrentLocation = startLocationId == 'current_location';
  final fromIdx = isStartCurrentLocation ? legIndex - 1 : legIndex;
  final toIdx = isStartCurrentLocation ? legIndex : legIndex + 1;
  LocationModel resolveById(String? id, LocationModel fallback) {
    if (id == null) return fallback;
    for (final l in ordered) {
      if (l.id == id) return l;
    }
    return fallback;
  }

  final from = (fromIdx >= 0 && fromIdx < ordered.length)
      ? ordered[fromIdx]
      : resolveById(
          legData['fromId'] as String?, _coordOnlyLocation(legPoints.first));
  final to = (toIdx >= 0 && toIdx < ordered.length)
      ? ordered[toIdx]
      : resolveById(
          legData['toId'] as String?, _coordOnlyLocation(legPoints.last));
  return (from: from, to: to);
}

/// Everything the leg sheet needs to show leg [legIndex] of the day's
/// route, from the live route state. One builder for the chip tap, the
/// polyline tap and the sheet's own previous/next stepping, so the three
/// can never describe the same leg differently. Null when there is no
/// such leg.
RouteLegSheetRequest? routeLegSheetRequestFor({
  required List<Map<String, dynamic>> legDetails,
  required List<List<LatLng>> legPolylines,
  required List<LocationModel> ordered,
  required String? startLocationId,
  required int legIndex,
}) {
  final ends = legEndpointsFor(
    legDetails: legDetails,
    legPolylines: legPolylines,
    ordered: ordered,
    startLocationId: startLocationId,
    legIndex: legIndex,
  );
  if (ends == null) return null;
  final legData = legDetails[legIndex];
  final distanceMeters = (legData['distance'] as num?)?.toDouble() ?? 0.0;
  final distanceLabel = distanceMeters >= 1000
      ? '${(distanceMeters / 1000).toStringAsFixed(1)} km'
      : '${distanceMeters.round()} m';
  final legDuration = legData['duration'] as Duration?;
  return RouteLegSheetRequest(
    origin: ends.from,
    destination: ends.to,
    distanceLabel: distanceLabel,
    durationLabel: legDuration == null ? null : formatLegDuration(legDuration),
    legIndex: legIndex,
    mode: legData['mode'] as String? ?? 'drive',
    transit: (legData['transit'] as List?)?.cast<Map<String, dynamic>>(),
  );
}

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
  // The chip sits on the selected geometry at the point nearest the map's
  // centre — near what the person is looking at. A long ride's geometric
  // midpoint was usually off screen, which read as "no box appeared".
  final viewCentre = ref.read(mapCameraTargetProvider);
  final midpoint = _chipAnchorOn(legPoints, viewCentre);

  // Format distance label from legDetails
  final legData = legDetailsState[legIndex];
  final distanceMeters = (legData['distance'] as num?)?.toDouble() ?? 0.0;
  final String distanceLabel = distanceMeters >= 1000
      ? '${(distanceMeters / 1000).toStringAsFixed(1)} km'
      : '${distanceMeters.round()} m';
  final legDuration = legData['duration'] as Duration?;
  final String? durationLabel =
      legDuration == null ? null : formatLegDuration(legDuration);

  final ends = legEndpointsFor(
    legDetails: legDetailsState,
    legPolylines: legPolylinesState,
    ordered: orderedForDate,
    startLocationId: startLocationIdState,
    legIndex: legIndex,
  );
  if (ends == null) return {};
  final fromLoc = ends.from;
  final toLoc = ends.to;

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
  // Every ride of the leg gets its badge ("[Tram] [Island Line]"), so a
  // two-ride journey is not announced by its first line alone.
  var chipBadges = chipBadgesFor(transitSegs);
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
      chipPosition = _chipAnchorOn(runPoints, viewCentre);
      final isRide = run['mode'] == 'TRANSIT';
      chipMode = isRide ? 'transit' : 'walk';
      chipVehicleType = isRide ? run['vehicleType'] as String? : null;
      chipBadges = isRide ? chipBadgesFor([run]) : const [];
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
    badges: chipBadges,
    fromName: chipFromName,
    toName: chipToName,
  );

  // anchor=(0.5, 0.5) → the chip straddles the tapped geometry's midpoint
  // (the leg's, or the tapped run's), so the line reads through on both
  // sides of it. Tapping the chip always opens the FULL leg sheet — the
  // run chip is a caption, the sheet is the journey.
  return {
    Marker(
        // Keyed by the tapped id (leg or run), not the leg index: a run
        // chip and the whole-leg chip are different bitmaps at different
        // points, and mutating one platform marker into the other left
        // stale chips behind on iOS.
        markerId: MarkerId('route_leg_chip_$tappedPolylineId'),
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
/// A tap on a leg's line (or one run of a transit leg). First tap selects
/// it: highlight, chip, camera. A tap on the line that is ALREADY selected
/// opens its sheet — the selected leg is drawn above the others, so where
/// legs share a road every further tap lands on it; without this, the
/// other legs there could never be reached from the map (the sheet steps
/// through all of them).
void _onLegGeometryTap(Ref ref, String tappedId, int legIndex) {
  final ui = ref.read(mapUIStateProvider.notifier);
  if (ref.read(tappedPolylineIdProvider) != tappedId) {
    ui.setTappedPolyline(tappedId);
    return;
  }
  final s = ref.read(tripProvider);
  final request = routeLegSheetRequestFor(
    legDetails: s.legDetails,
    legPolylines: s.legPolylines,
    ordered: s.optimizedLocationsForSelectedDate,
    startLocationId: s.startLocationId,
    legIndex: legIndex,
  );
  if (request != null) {
    ref.read(routeLegSheetRequestProvider.notifier).state = request;
  }
}

/// The point of [points] nearest to [near] (the map's centre), or the
/// list's middle point when the centre is unknown. Flat-earth squared
/// distance in degrees: an ordering, not a measurement, and cheap.
LatLng _chipAnchorOn(List<LatLng> points, LatLng? near) {
  if (points.isEmpty) return const LatLng(0, 0);
  if (near == null || points.length < 3) return points[points.length ~/ 2];
  final cosLat = math.cos(near.latitude * math.pi / 180);
  var best = points[points.length ~/ 2];
  var bestD = double.infinity;
  for (final p in points) {
    final dy = p.latitude - near.latitude;
    final dx = (p.longitude - near.longitude) * cosLat;
    final d = dx * dx + dy * dy;
    if (d < bestD) {
      bestD = d;
      best = p;
    }
  }
  return best;
}

/// The chip badges for a list of ride cards / ride runs: one per ride
/// that names its line, in the line's colour (shared fallback when the
/// feed has none). Public for the test.
List<ChipBadge> chipBadgesFor(List? rides) {
  if (rides == null) return const [];
  final out = <ChipBadge>[];
  for (final r in rides) {
    if (r is! Map) continue;
    final text = ((r['lineShort'] as String?) ?? '').trim();
    if (text.isEmpty) continue;
    out.add(ChipBadge(text,
        fill: transitLineFill(r), textColor: transitLineTextColor(r)));
  }
  return out;
}

double _metersBetween(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = (b.latitude - a.latitude) * math.pi / 180;
  final dLng = (b.longitude - a.longitude) * math.pi / 180;
  final la1 = a.latitude * math.pi / 180;
  final la2 = b.latitude * math.pi / 180;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
}

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

  /// The focused place's building footprint (see
  /// building_outline_provider.dart); empty when none is focused.
  final Set<Polygon> polygons;

  const AssembledMapOverlays({
    required this.markers,
    required this.polylines,
    required this.automaticZones,
    this.polygons = const {},
  });
}

final assembledMapOverlaysProvider =
    Provider<AsyncValue<AssembledMapOverlays>>((ref) {
  final markers = ref.watch(finalMarkersProvider);
  final polylines = ref.watch(styledPolylinesProvider);
  final automaticZones = ref.watch(memoizedAutomaticZonesProvider);
  final routeInfoMarkersAsync = ref.watch(routeInfoMarkersProvider);
  // The focused place's callout: like the chip, the previous one stays
  // while a new one rasterizes; none on an error.
  final calloutAsync = ref.watch(focusedPlaceCalloutProvider);
  final calloutMarkers =
      calloutAsync.hasError ? const <Marker>{} : calloutAsync.valueOrNull ?? {};
  final buildingPolygons = ref.watch(buildingPolygonsProvider);

  // Since finalMarkersProvider is synchronous (deriving from an async one),
  // we can treat it more directly. We'll use the async state of the bitmap provider to manage loading/error states.
  return ref.watch(cachedMarkerBitmapsProvider).when(
        skipLoadingOnReload: true,
        data: (_) {
          // We don't need the data here, just the state.
          // While a new chip rasterizes the previous one stays (no
          // flicker); if rasterizing FAILED, show none rather than the
          // previous leg's chip with its stale tap target.
          final routeInfoMarkers = routeInfoMarkersAsync.hasError
              ? const <Marker>{}
              : routeInfoMarkersAsync.valueOrNull ?? {};

          // DEBUG: Uncomment to track overlay assembly
          // debugPrint('✅ Assembling map overlays: ${markers.length} base markers, ${routeInfoMarkers.length} route info markers, ${polylines.length} polylines, ${automaticZones.length} auto zones');

          return AsyncValue.data(AssembledMapOverlays(
            markers: {...markers, ...routeInfoMarkers, ...calloutMarkers},
            polylines: polylines,
            automaticZones: automaticZones,
            polygons: buildingPolygons,
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
