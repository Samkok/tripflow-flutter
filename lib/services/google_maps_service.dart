import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/location_model.dart';

/// Routing service, migrated from the legacy Directions API to the Routes
/// API v2 (`computeRoutes`). The legacy endpoint is EOL — disabled for all
/// new Google Cloud projects since March 2025 — and Routes is also the only
/// API with transit + multi-modal support, which the optimizer now uses.
///
/// Contract kept identical to the legacy implementation so existing callers
/// (trip_provider, all_days_route_provider) work unchanged:
///   { routePoints, waypointOrder, legDetails, legPolylines }
/// New additive keys: 'status' ('ok'|'empty'|'error') so the multi-modal
/// router can distinguish "no route exists" from transport errors, and — for
/// transit — 'legTransit' (per-leg transit segment payloads).
class GoogleMapsService {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));
  static String get _apiKey => dotenv.env['GOOGLE_DIRECTIONS_API_KEY'] ?? '';

  static const _endpoint =
      'https://routes.googleapis.com/directions/v2:computeRoutes';

  /// Travel modes accepted by [getOptimizedRouteDetails]'s [mode] param,
  /// mapped to Routes API enum values.
  static const modeEnum = {
    'drive': 'DRIVE',
    'walk': 'WALK',
    'bicycle': 'BICYCLE',
    'two_wheeler': 'TWO_WHEELER',
    'transit': 'TRANSIT',
  };

  static Map<String, dynamic> _emptyResult(String status) => {
        'routePoints': <LatLng>[],
        'waypointOrder': <int>[],
        'legDetails': <Map<String, dynamic>>[],
        'legPolylines': <List<LatLng>>[],
        'legTransit': <List<Map<String, dynamic>>?>[],
        'status': status,
      };

  static Future<Map<String, dynamic>> getOptimizedRouteDetails({
    required LatLng origin,
    LocationModel? destination,
    List<LocationModel> waypoints = const [],
    bool optimizeWaypoints = true,
    String mode = 'drive',
    DateTime? departureTime,
    // Single-leg calls only: also parse every returned route into
    // 'alternativeRoutes' (Google returns up to 3 alternates + default) so
    // the leg sheet can offer a choice. Never combined with waypoints —
    // the API doesn't support alternatives alongside intermediates.
    bool includeAlternatives = false,
  }) async {
    final allDestinations = [
      ...waypoints,
      if (destination != null) destination
    ];
    if (allDestinations.isEmpty) return _emptyResult('empty');

    // Routes API hard limit: TRANSIT supports no intermediate waypoints.
    // The multi-modal router only ever requests transit leg-by-leg; this
    // guard keeps the contract explicit.
    assert(!(mode == 'transit' && waypoints.isNotEmpty),
        'transit routing is single-leg only');

    try {
      final finalDestination = destination?.coordinates ??
          waypoints.last.coordinates; // destination null ⇒ waypoints nonempty

      Map<String, dynamic> latLng(LatLng p) => {
            'location': {
              'latLng': {'latitude': p.latitude, 'longitude': p.longitude}
            }
          };

      final isTransit = mode == 'transit';
      final travelMode = modeEnum[mode] ?? 'DRIVE';

      final body = <String, dynamic>{
        'origin': latLng(origin),
        'destination': latLng(finalDestination),
        if (destination != null && waypoints.isNotEmpty)
          'intermediates': [for (final w in waypoints) latLng(w.coordinates)],
        'travelMode': travelMode,
        // TRAFFIC_UNAWARE = cheapest tier and matches the legacy behavior
        // (no departure_time was ever sent). Only valid for DRIVE and
        // TWO_WHEELER — the API rejects it for WALK/BICYCLE/TRANSIT.
        if (travelMode == 'DRIVE' || travelMode == 'TWO_WHEELER')
          'routingPreference': 'TRAFFIC_UNAWARE',
        if (optimizeWaypoints &&
            waypoints.isNotEmpty &&
            destination != null &&
            !isTransit)
          'optimizeWaypointOrder': true,
        // Transit ranks pure-walking itineraries FIRST when walking beats
        // every ride — ask for alternatives so we can insist on a vehicle.
        // Any mode: alternatives on request (route-options UI), single-leg
        // only (no intermediates present).
        if (isTransit || (includeAlternatives && waypoints.isEmpty))
          'computeAlternativeRoutes': true,
        // Transit schedules need an anchor; must be in the future and
        // inside the timetable window (see _transitQueryTime).
        if (isTransit)
          'departureTime':
              _transitQueryTime(departureTime).toUtc().toIso8601String(),
      };

      // Field-mask API: unlisted fields are simply not returned. Transit
      // additionally needs steps (for line/stop/schedule details) — kept out
      // of other modes to keep payloads small.
      final fieldMask = [
        'routes.legs.distanceMeters',
        'routes.legs.duration',
        'routes.legs.polyline.encodedPolyline',
        if (optimizeWaypoints) 'routes.optimizedIntermediateWaypointIndex',
        if (isTransit) 'routes.legs.steps.travelMode',
        if (isTransit) 'routes.legs.steps.transitDetails',
        if (isTransit) 'routes.legs.steps.staticDuration',
        // Per-step geometry: a transit leg is walk → ride → walk, and the
        // map must draw those pieces differently (dotted walk, line-colored
        // ride) — one solid leg polyline looked like the ride started at
        // the user's feet.
        if (isTransit) 'routes.legs.steps.polyline.encodedPolyline',
        // Route-options UI: "via Tai Po Rd" descriptions differentiate
        // drive alternates the way line badges differentiate transit ones.
        if (includeAlternatives) 'routes.description',
        if (includeAlternatives) 'routes.routeLabels',
      ].join(',');

      final response = await _dio.post(
        _endpoint,
        data: body,
        options: Options(headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': _apiKey,
          'X-Goog-FieldMask': fieldMask,
          'X-Goog-Maps-Solution-ID': 'gmp_git_agentskills_v1',
        }),
      );

      final data = response.data as Map<String, dynamic>;
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return _emptyResult('empty');

      // TRANSIT: Google's top-ranked "transit" route is often a pure walk
      // (its own app shows "Walk 24 min" above the 42-min ride). A caller
      // asking for transit wants the RIDE — take the first alternative
      // that actually boards a vehicle; only fall back to the walk-shaped
      // top result when no alternative rides at all.
      Map<String, dynamic> route = routes[0] as Map<String, dynamic>;
      if (isTransit && routes.length > 1) {
        bool hasRide(Map<String, dynamic> r) {
          for (final leg in (r['legs'] as List?) ?? const []) {
            for (final st in ((leg as Map)['steps'] as List?) ?? const []) {
              if ((st as Map)['transitDetails'] != null) return true;
            }
          }
          return false;
        }

        if (!hasRide(route)) {
          for (final r in routes.skip(1)) {
            if (hasRide(r as Map<String, dynamic>)) {
              route = r;
              break;
            }
          }
        }
      }
      final legs = (route['legs'] as List?) ?? const [];
      if (legs.isEmpty) return _emptyResult('empty');

      final List<int> waypointOrder = [];
      if (optimizeWaypoints &&
          route['optimizedIntermediateWaypointIndex'] != null) {
        waypointOrder.addAll(
            (route['optimizedIntermediateWaypointIndex'] as List).cast<int>());
      } else if (waypoints.isNotEmpty) {
        waypointOrder.addAll(List.generate(waypoints.length, (i) => i));
      } else if (destination != null) {
        waypointOrder.add(0);
      }

      final List<Map<String, dynamic>> legDetails = [];
      final List<List<LatLng>> legPolylines = [];
      final List<List<Map<String, dynamic>>?> legTransit = [];
      final List<List<Map<String, dynamic>>?> legSteps = [];

      for (final legRaw in legs) {
        final leg = legRaw as Map<String, dynamic>;
        legDetails.add({
          'duration': _parseDuration(leg['duration']),
          'distance': ((leg['distanceMeters'] as num?) ?? 0).toDouble(),
        });
        final encoded =
            (leg['polyline'] as Map?)?['encodedPolyline'] as String?;
        legPolylines
            .add(encoded == null ? <LatLng>[] : _decodePolyline(encoded));
        legTransit.add(isTransit ? _extractTransitSegments(leg) : null);
        legSteps.add(isTransit ? _extractStepGeometry(leg) : null);
      }

      final fullRoutePoints =
          legPolylines.expand((leg) => leg).toList(growable: false);

      // Every returned route as its own bundle, ranked in Google's order,
      // for the route-options UI. Single-leg calls only (one leg each).
      List<Map<String, dynamic>>? alternativeRoutes;
      if (includeAlternatives) {
        alternativeRoutes = [];
        for (final rRaw in routes) {
          final r = rRaw as Map<String, dynamic>;
          final rLegs = (r['legs'] as List?) ?? const [];
          if (rLegs.isEmpty) continue;
          final rLeg = rLegs.first as Map<String, dynamic>;
          final encodedR =
              (rLeg['polyline'] as Map?)?['encodedPolyline'] as String?;
          final pointsR =
              encodedR == null ? <LatLng>[] : _decodePolyline(encodedR);
          if (pointsR.isEmpty) continue;
          alternativeRoutes.add({
            'duration': _parseDuration(rLeg['duration']),
            'distance': ((rLeg['distanceMeters'] as num?) ?? 0).toDouble(),
            'points': pointsR,
            'transit': isTransit ? _extractTransitSegments(rLeg) : null,
            'steps': isTransit ? _extractStepGeometry(rLeg) : null,
            'description': r['description'],
            'labels': (r['routeLabels'] as List?)?.cast<String>(),
          });
        }
      }

      return {
        'routePoints': fullRoutePoints,
        'waypointOrder': waypointOrder,
        'legDetails': legDetails,
        'legPolylines': legPolylines,
        'legTransit': legTransit,
        'legSteps': legSteps,
        if (alternativeRoutes != null) 'alternativeRoutes': alternativeRoutes,
        'status': 'ok',
      };
    } on DioException catch (e) {
      // 4xx with an explanatory body usually means "no route for this mode
      // here" (e.g. drive in Venice) — that's a ladder signal, not an error.
      final code = e.response?.statusCode ?? 0;
      debugPrint('Routes API ($mode) failed [$code]: '
          '${e.response?.data ?? e.message}');
      return _emptyResult(code >= 400 && code < 500 ? 'empty' : 'error');
    } catch (e) {
      debugPrint('Error getting optimized route ($mode): $e');
      return _emptyResult('error');
    }
  }

  /// Transit timetables are only queryable a limited number of days ahead —
  /// a trip planned weeks out gets its far-future departure rejected, which
  /// reads as "no transit here" right beside a metro station. Timetables
  /// are weekly-periodic, so shift the requested moment back WHOLE WEEKS
  /// into the queryable window: same weekday + time of day = representative
  /// schedule. Past moments clamp to "soon".
  static DateTime _transitQueryTime(DateTime? requested) {
    final now = DateTime.now();
    final earliest = now.add(const Duration(minutes: 5));
    var t = requested ?? earliest;
    final latest = now.add(const Duration(days: 6));
    while (t.isAfter(latest)) {
      t = t.subtract(const Duration(days: 7));
    }
    if (t.isBefore(earliest)) return earliest;
    return t;
  }

  /// Routes API durations arrive as "1234s" strings.
  static Duration _parseDuration(dynamic raw) {
    if (raw is String && raw.endsWith('s')) {
      return Duration(
          seconds: int.tryParse(raw.substring(0, raw.length - 1)) ?? 0);
    }
    return Duration.zero;
  }

  /// Condenses a transit leg's steps into displayable ride segments: one map
  /// per transit vehicle ridden, carrying the line identity (name, official
  /// color), board/alight stops, scheduled times, headsign and stop count.
  /// Walking portions between rides are implicit (the sheet shows them as
  /// part of the leg, Google-style).
  static List<Map<String, dynamic>> _extractTransitSegments(
      Map<String, dynamic> leg) {
    final segments = <Map<String, dynamic>>[];
    for (final stepRaw in (leg['steps'] as List?) ?? const []) {
      final step = stepRaw as Map<String, dynamic>;
      final td = step['transitDetails'] as Map<String, dynamic>?;
      if (td == null) continue;
      final line = td['transitLine'] as Map<String, dynamic>? ?? const {};
      final stopDetails =
          td['stopDetails'] as Map<String, dynamic>? ?? const {};
      final vehicle = line['vehicle'] as Map<String, dynamic>? ?? const {};
      segments.add({
        'lineShort': line['nameShort'] ?? line['name'] ?? '',
        'lineName': line['name'] ?? '',
        'lineColor': line['color'],
        'lineTextColor': line['textColor'],
        'vehicleType': vehicle['type'] ?? 'BUS',
        'headsign': td['headsign'] ?? '',
        'stopCount': td['stopCount'] ?? 0,
        'boardStop': (stopDetails['departureStop'] as Map?)?['name'] ?? '',
        'alightStop': (stopDetails['arrivalStop'] as Map?)?['name'] ?? '',
        'departureTime': stopDetails['departureTime'],
        'arrivalTime': stopDetails['arrivalTime'],
      });
    }
    return segments;
  }

  /// Per-step DRAWABLE geometry for a transit leg, with consecutive
  /// same-mode steps merged into runs: [{mode: 'WALK'|'TRANSIT', points,
  /// durationSeconds, lineColor?, lineShort?, vehicleType?}]. The map
  /// styles each run (dotted walking approach, line-colored ride) and the
  /// plan-sheet rail renders the run chain — walk 4 min › [87] 30 min › …
  static List<Map<String, dynamic>> _extractStepGeometry(
      Map<String, dynamic> leg) {
    final runs = <Map<String, dynamic>>[];
    for (final stepRaw in (leg['steps'] as List?) ?? const []) {
      final step = stepRaw as Map<String, dynamic>;
      final encoded = (step['polyline'] as Map?)?['encodedPolyline'] as String?;
      if (encoded == null) continue;
      final points = _decodePolyline(encoded);
      if (points.isEmpty) continue;
      final isRide = step['transitDetails'] != null ||
          (step['travelMode'] as String?) == 'TRANSIT';
      String? color;
      String? lineShort;
      String? vehicleType;
      if (isRide) {
        final td = step['transitDetails'] as Map?;
        final line = td == null ? null : td['transitLine'] as Map?;
        color = line == null ? null : line['color'] as String?;
        lineShort = line == null
            ? null
            : (line['nameShort'] ?? line['name']) as String?;
        final vehicle = line == null ? null : line['vehicle'] as Map?;
        vehicleType = vehicle == null ? null : vehicle['type'] as String?;
      }
      final stepSeconds = _parseDuration(step['staticDuration']).inSeconds;
      final mode = isRide ? 'TRANSIT' : 'WALK';
      // Merge consecutive WALK steps only. TRANSIT runs must stay 1:1 with
      // the ride cards from [_extractTransitSegments]: two back-to-back
      // rides on same-colored lines (641 → 600, both Rapid KL blue, same
      // platform so no walk step between) used to merge here, which broke
      // the run↔ride pairing everywhere it's assumed — the leg sheet fell
      // back to rides-only (walk rows vanished) and per-run chips would
      // have shown the wrong stops.
      if (!isRide && runs.isNotEmpty && runs.last['mode'] == 'WALK') {
        (runs.last['points'] as List<LatLng>).addAll(points);
        runs.last['durationSeconds'] =
            (runs.last['durationSeconds'] as int) + stepSeconds;
      } else {
        runs.add({
          'mode': mode,
          'points': List<LatLng>.from(points),
          'durationSeconds': stepSeconds,
          if (color != null) 'lineColor': color,
          if (lineShort != null) 'lineShort': lineShort,
          if (vehicleType != null) 'vehicleType': vehicleType,
        });
      }
    }
    return runs;
  }

  static List<LatLng> _decodePolyline(String polyline) {
    final List<LatLng> points = [];
    int index = 0;
    final len = polyline.length;
    int lat = 0;
    int lng = 0;

    while (index < len) {
      int b;
      int shift = 0;
      int result = 0;
      do {
        b = polyline.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = polyline.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }

    return points;
  }
}
