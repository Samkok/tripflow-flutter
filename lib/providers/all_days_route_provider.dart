import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../models/location_model.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/trip_provider.dart';
import '../services/google_maps_service.dart';
import '../services/marker_cache_service.dart';
import '../services/multi_modal_router.dart';
import '../utils/marker_utils.dart';
import '../utils/polyline_simplify.dart';
import '../utils/trip_dates.dart';

/// "All days" mode for the map: instead of showing the selected date's route,
/// the map overlays every day of the active trip at once — one route per day,
/// each in its own color. Toggled by the "All" chip in the trip-plan sheet's
/// day strip.
final allDaysModeProvider = StateProvider<bool>((ref) => false);

DateTime _dayKey(DateTime d) => DateTime(d.year, d.month, d.day);

/// Palette used for per-day route colors. Hand-picked for mutual contrast and
/// legibility over both light and dark map tiles. 12 entries → trips up to 12
/// days get strictly unique colors; longer trips cycle (day 13 shares day 1's
/// color, which is the least-confusable reuse since they're far apart).
const kDayRouteColors = <Color>[
  Color(0xFF2E5BD0), // blue
  Color(0xFFE53935), // red
  Color(0xFF1EA672), // green
  Color(0xFFF5793B), // orange
  Color(0xFF7C4DFF), // purple
  Color(0xFF00ACC1), // cyan
  Color(0xFFE0568A), // pink
  Color(0xFF6D4C41), // brown
  Color(0xFF3949AB), // indigo
  Color(0xFF15BFB6), // teal
  Color(0xFFAFB42B), // olive
  Color(0xFFFF8F00), // amber
];

/// The active trip's day axis — the same gap-free day list every other
/// surface uses ([contiguousTripDates]), derived from the trip's declared
/// range plus every location's scheduled dates.
final activeTripDayAxisProvider = Provider<List<DateTime>>((ref) {
  final trip = ref.watch(realtimeActiveTripProvider).valueOrNull;
  final locations = ref.watch(tripProvider.select((s) => s.pinnedLocations));
  if (trip == null && locations.isEmpty) return const <DateTime>[];
  return contiguousTripDates([
    trip?.startDate,
    trip?.endDate,
    for (final loc in locations) ...[
      // Unscheduled rows (null) don't stretch the axis — they live in the
      // bucket, not on a day. contiguousTripDates skips nulls.
      loc.scheduledDate,
      loc.scheduledEndDate,
    ],
  ]);
});

/// Color assignment for each day of the active trip.
///
/// Derived (not stored): the color of a day is its index in the trip's day
/// axis. Because this recomputes whenever the axis changes — a date created,
/// a trip's range updated, a stop rescheduled, a day deleted — the
/// "every day has a different color" invariant re-applies automatically after
/// any such change; there is no stale stored color to fix up.
final tripDayColorsProvider = Provider<Map<DateTime, Color>>((ref) {
  final axis = ref.watch(activeTripDayAxisProvider);
  return {
    for (var i = 0; i < axis.length; i++)
      axis[i]: kDayRouteColors[i % kDayRouteColors.length],
  };
});

/// The active trip's stops grouped per day. ONLY skipped stops are excluded —
/// a done stop is still part of the trip's story, so the whole-trip overview
/// keeps showing it (on the map and in its day's route). Multi-day stays
/// appear on every day they span.
final allDayStopsProvider = Provider<Map<DateTime, List<LocationModel>>>((ref) {
  final axis = ref.watch(activeTripDayAxisProvider);
  final locations = ref.watch(tripProvider.select((s) => s.pinnedLocations));
  final byDay = <DateTime, List<LocationModel>>{};
  for (final day in axis) {
    final stops =
        locations.where((l) => !l.isSkipped && l.isActiveOnDate(day)).toList();
    if (stops.isNotEmpty) byDay[day] = stops;
  }
  return byDay;
});

/// Process-lifetime cache of fetched day-route geometry, keyed by the day's
/// stop signature. Bounded so a long session can't grow it unboundedly.
final Map<String, List<LatLng>> _dayRouteCache = {};

String _daySignature(DateTime day, List<LocationModel> stops) {
  final ids = stops
      .map((l) =>
          '${l.id}:${l.coordinates.latitude.toStringAsFixed(5)},${l.coordinates.longitude.toStringAsFixed(5)}')
      .join('|');
  return '${day.toIso8601String()}#$ids';
}

/// Road-following route geometry for every day of the active trip, fetched
/// when All-days mode is on. Per day:
///   * 0–1 stops → no polyline (markers only),
///   * the currently-optimized day → reuses the in-memory optimized geometry
///     (identical to what the user just saw), and
///   * other days → one Directions call (waypoints optimized, purely visual —
///     nothing is written back), cached by stop signature so re-toggling the
///     mode or unrelated rebuilds never re-bill the API.
/// A failed fetch falls back to straight lines between the day's stops so the
/// overview still reads offline.
final allDayRoutesProvider =
    FutureProvider<Map<DateTime, List<LatLng>>>((ref) async {
  final enabled = ref.watch(allDaysModeProvider);
  if (!enabled) return const {};
  final stopsByDay = ref.watch(allDayStopsProvider);
  if (stopsByDay.isEmpty) return const {};

  // Read (not watch): legPolylines churn is excluded from TripState equality,
  // and we only need a point-in-time snapshot for the reuse check below.
  final tripState = ref.read(tripProvider);
  final optimizedDay = _dayKey(ref.read(selectedDateProvider));
  final hasOptimized =
      tripState.optimizedRoute.isNotEmpty && tripState.legPolylines.isNotEmpty;

  if (_dayRouteCache.length > 48) _dayRouteCache.clear();

  final results = <DateTime, List<LatLng>>{};
  await Future.wait(stopsByDay.entries.map((entry) async {
    final day = entry.key;
    final stops = entry.value;
    if (stops.length < 2) return; // single stop: marker only, no route line

    final signature = _daySignature(day, stops);
    final cached = _dayRouteCache[signature];
    if (cached != null) {
      results[day] = cached;
      return;
    }

    // Reuse the freshly-optimized geometry for the day the user optimized.
    if (hasOptimized && day == optimizedDay) {
      final merged =
          tripState.legPolylines.expand((leg) => leg).toList(growable: false);
      if (merged.isNotEmpty) {
        _dayRouteCache[signature] = merged;
        results[day] = merged;
        return;
      }
    }

    // Over the Routes 25-intermediate cap: skip the doomed API call and go
    // straight to the offline fallback below (straight segments).
    final details = stops.length - 2 > MultiModalRouter.maxRoutableStopsPerDay
        ? const <String, dynamic>{}
        : await GoogleMapsService.getOptimizedRouteDetails(
            origin: stops.first.coordinates,
            destination: stops.last,
            waypoints:
                stops.length > 2 ? stops.sublist(1, stops.length - 1) : const [],
            optimizeWaypoints: true,
          );
    var points = (details['routePoints'] as List<LatLng>?) ?? const <LatLng>[];
    if (points.isEmpty) {
      // Offline / API failure: straight segments through the stops.
      points = stops.map((l) => l.coordinates).toList(growable: false);
    }
    _dayRouteCache[signature] = points;
    results[day] = points;
  }));

  return results;
});

/// Styled polylines for All-days mode — every day's route in its assigned
/// color (shadow + main line, mirroring the single-day route styling).
/// Because this watches [tripDayColorsProvider], any color reassignment
/// (day created/updated/removed) restyles the routes automatically.
final allDaysPolylinesProvider = Provider<Set<Polyline>>((ref) {
  if (!ref.watch(allDaysModeProvider)) return const {};
  final routes = ref.watch(allDayRoutesProvider).valueOrNull ?? const {};
  final colors = ref.watch(tripDayColorsProvider);
  final axis = ref.watch(activeTripDayAxisProvider);

  final polylines = <Polyline>{};
  for (final day in axis) {
    final points = routes[day];
    if (points == null || points.isEmpty) continue;
    final color = colors[day] ?? kDayRouteColors.first;
    final dayId = day.toIso8601String();
    final zBase = 2 * (axis.indexOf(day) + 1);

    // Display-only thinning + no geodesic interpolation: a whole day's
    // road geometry per day, several days at once — every vertex is SDK
    // work on each zoom frame.
    final drawn = simplifyForDisplay(points);
    polylines.add(Polyline(
      polylineId: PolylineId('all_day_${dayId}_shadow'),
      points: drawn,
      color: Colors.black.withValues(alpha: 0.12),
      width: 8,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
      jointType: JointType.round,
      geodesic: false,
      zIndex: zBase,
    ));
    polylines.add(Polyline(
      polylineId: PolylineId('all_day_$dayId'),
      points: drawn,
      color: color.withValues(alpha: 0.9),
      width: 6,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
      jointType: JointType.round,
      geodesic: false,
      zIndex: zBase + 1,
    ));
  }
  return polylines;
});

/// Separator for all-days marker ids: `allday|<day iso>|<location id>`.
/// '|' can't appear in an ISO date or a UUID, so [locationIdFromAllDaysMarker]
/// can parse the location back out for tap handling.
const kAllDaysMarkerIdPrefix = 'allday|';

String? locationIdFromAllDaysMarker(String markerId) {
  if (!markerId.startsWith(kAllDaysMarkerIdPrefix)) return null;
  final parts = markerId.split('|');
  return parts.length == 3 ? parts[2] : null;
}

/// Markers for All-days mode: the same numbered, name-labeled marker style as
/// single-day view (bitmaps via [MarkerCacheService]), tinted per day. The
/// place name is BAKED INTO the bitmap, so it's always visible next to the
/// pin — independent of the "show place names" info-window toggle. Numbering
/// restarts per day (1..n within each day's stops).
final allDaysMarkersProvider = FutureProvider<Set<Marker>>((ref) async {
  if (!ref.watch(allDaysModeProvider)) return const {};
  final stopsByDay = ref.watch(allDayStopsProvider);
  final colors = ref.watch(tripDayColorsProvider);
  final axis = ref.watch(activeTripDayAxisProvider);
  final isDarkMode = ref.watch(themeProvider) == ThemeMode.dark;

  final markerCache = MarkerCacheService();

  // Numbering is order-dependent per day → compute all specs synchronously,
  // THEN rasterize every bitmap in PARALLEL. The serial awaits here were
  // why tapping "All" left the map bare for seconds: every location of
  // every day queued one-by-one through the canvas→PNG pipeline.
  final specs = <({
    LocationModel loc,
    DateTime day,
    int number,
    Color color,
    String dayLabel,
  })>[];
  for (final entry in stopsByDay.entries) {
    final day = entry.key;
    final color = colors[day] ?? kDayRouteColors.first;
    final dayIndex = axis.indexOf(day) + 1;
    final dayLabel = 'Day $dayIndex · ${DateFormat('MMM d').format(day)}';
    // Done stops render with the done treatment (marker number -2, matching
    // the single-day map) and don't consume a sequence number, so the
    // remaining stops still read 1..n.
    var seq = 0;
    for (final loc in entry.value) {
      if (!loc.isDone) seq++;
      specs.add((
        loc: loc,
        day: day,
        number: loc.isDone ? -2 : seq,
        color: color,
        dayLabel: dayLabel,
      ));
    }
  }

  final results = await Future.wait(specs.map((spec) {
    // Amber + caution line when Google lists no hours for that weekday —
    // a "might", never a verdict (Places hours are often stale).
    final mightBeClosed =
        !spec.loc.isDone && spec.loc.mightBeClosedOn(spec.day);
    return markerCache.getNumberedMarker(
      isStart: false,
      number: spec.number,
      name: spec.loc.name,
      backgroundColor: mightBeClosed ? MarkerUtils.warningAmber : spec.color,
      textColor: Colors.white,
      isDarkMode: isDarkMode,
      isSkipped: false,
      isDone: spec.loc.isDone,
      warningLine:
          mightBeClosed ? 'Might be closed on this date — please check' : null,
    );
  }));

  final markers = <Marker>{};
  for (var i = 0; i < specs.length; i++) {
    final spec = specs[i];
    final result = results[i];
    markers.add(Marker(
      markerId: MarkerId('$kAllDaysMarkerIdPrefix${spec.day.toIso8601String()}'
          '|${spec.loc.id}'),
      position: spec.loc.coordinates,
      icon: result.bitmap,
      anchor: result.anchor,
      infoWindow: InfoWindow(title: spec.loc.name, snippet: spec.dayLabel),
    ));
  }
  return markers;
});
