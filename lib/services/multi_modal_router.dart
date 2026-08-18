import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/location_model.dart';
import 'google_maps_service.dart';

/// One routed leg of an itinerary, in whatever mode the ladder (or the user)
/// chose. `mode` ∈ drive | walk | bicycle | two_wheeler | transit | direct
/// ('direct' = no route found in any mode → straight-line fallback, so the
/// itinerary NEVER silently loses a leg — the Venice bug this replaces).
class LegRoute {
  const LegRoute({
    required this.points,
    required this.duration,
    required this.distance,
    required this.mode,
    this.transit,
    this.steps,
    this.departureTime,
    this.arrivalTime,
    this.description,
  });

  final List<LatLng> points;
  final Duration duration;
  final double distance;
  final String mode;
  final List<Map<String, dynamic>>? transit;

  /// Transit legs only: drawable geometry runs ({mode: WALK|TRANSIT, points,
  /// lineColor?}) so the map styles the walking approach apart from the ride.
  final List<Map<String, dynamic>>? steps;
  final String? departureTime;
  final String? arrivalTime;

  /// Route-options rows: Google's differentiator ("via Tai Po Rd").
  final String? description;
}

/// The routed itinerary in the exact shape trip_provider consumed from the
/// single-mode service — routePoints / legDetails / legPolylines — with the
/// legDetails maps carrying additive multi-modal keys:
///   mode, fromId, toId, transit (segment list), departureTime, arrivalTime.
class MultiModalRouter {
  MultiModalRouter._();

  // ── Ladder thresholds (meters) ──────────────────────────────────────────
  /// Straight-line shortcut below which walking always wins with no extra
  /// API call. DERIVED from the user's max-walk preference at ×0.8 (city
  /// routes run ~25% longer than the crow flies, so 0.8× straight ≈ the
  /// preferred routed maximum). This 800 is only the default-pref value.
  static const double walkAlwaysMeters = 800;

  /// In city (walk-anchored) trips, legs at/above this try transit.
  static const double transitFromMeters = 1200;

  /// A trip anchors to WALK when every consecutive hop is under this —
  /// the "walking city" signature (Venice, old towns).
  static const double cityHopMeters = 3000;

  /// Walking legs longer than this fall through to drive when transit
  /// found nothing — 45 min on foot is past most people's tolerance.
  static const Duration maxComfortableWalk = Duration(minutes: 45);

  /// In NON-walking styles a walk beyond this is "too long": the user
  /// picked transit/car precisely to avoid long walks. DEFAULT for the
  /// user-tunable "Max walk between stops" preference (LegModePrefs);
  /// the live value arrives via routeItinerary's [maxWalkMeters].
  static const double longWalkMeters = 1000;

  // ── Leg cache ───────────────────────────────────────────────────────────
  // Session-scoped: keyed by endpoints+mode (+30-min departure band for
  // transit, whose results are schedule-dependent). Re-optimizes and mode
  // experiments become free; capped LRU so memory stays bounded.
  static final LinkedHashMap<String, LegRoute> _cache = LinkedHashMap();
  static const int _maxCacheEntries = 300;

  static String _cacheKey(LatLng a, LatLng b, String mode, DateTime? dep) {
    final band = (mode == 'transit' && dep != null)
        ? (dep.millisecondsSinceEpoch ~/ (30 * 60 * 1000)).toString()
        : '-';
    String pt(LatLng p) =>
        '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}';
    return '${pt(a)}|${pt(b)}|$mode|$band';
  }

  static void _cachePut(String key, LegRoute leg) {
    _cache.remove(key);
    _cache[key] = leg;
    while (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  static double _meters(LatLng a, LatLng b) => Geolocator.distanceBetween(
      a.latitude, a.longitude, b.latitude, b.longitude);

  // ── Single leg (also used by the per-leg override flow) ─────────────────
  static Future<LegRoute?> routeSingleLeg({
    required LatLng from,
    required LatLng to,
    required String mode,
    DateTime? departureTime,
  }) async {
    final key = _cacheKey(from, to, mode, departureTime);
    final cached = _cache[key];
    if (cached != null) return cached;

    var leg = await _fetchSingle(from, to, mode, departureTime);

    // Transit schedule-miss retry: an itinerary whose clock has drifted
    // into the night (default stays add up) queries a REAL "no service at
    // 2 AM" answer — while the same pair rides fine at midday. In a
    // planner, a ride that exists beats "not found": retry once at a
    // neutral near-now departure. Whether the PLAN runs too late remains
    // the timing-warnings system's story to tell.
    if (leg == null && mode == 'transit' && departureTime != null) {
      final soon = DateTime.now().add(const Duration(minutes: 10));
      if (departureTime.difference(soon).abs() > const Duration(hours: 2)) {
        leg = await _fetchSingle(from, to, mode, soon);
      }
    }

    if (leg != null) _cachePut(key, leg);
    return leg;
  }

  static Future<LegRoute?> _fetchSingle(
    LatLng from,
    LatLng to,
    String mode,
    DateTime? departureTime,
  ) async {
    final res = await GoogleMapsService.getOptimizedRouteDetails(
      origin: from,
      destination: LocationModel(
        id: '_leg_dest',
        name: '',
        address: '',
        coordinates: to,
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
      optimizeWaypoints: false,
      mode: mode,
      departureTime: departureTime,
    );
    if (res['status'] != 'ok') return null;
    final details = res['legDetails'] as List<Map<String, dynamic>>;
    final polys = res['legPolylines'] as List<List<LatLng>>;
    if (details.isEmpty || polys.isEmpty || polys.first.isEmpty) return null;

    final transitLists = res['legTransit'] as List<List<Map<String, dynamic>>?>;
    final transit = transitLists.isEmpty ? null : transitLists.first;
    // A "transit" result with no ride is a walk in costume (even the
    // alternative-selection upstream found no vehicle). Returning null here
    // makes the ladder fall through honestly AND the leg sheet's
    // availability probe disable the Transit chip for this leg.
    if (mode == 'transit' && (transit == null || transit.isEmpty)) {
      return null;
    }
    final stepLists = res['legSteps'] as List<List<Map<String, dynamic>>?>?;
    final steps =
        (stepLists == null || stepLists.isEmpty) ? null : stepLists.first;
    final leg = LegRoute(
      points: polys.first,
      duration: details.first['duration'] as Duration,
      distance: (details.first['distance'] as num).toDouble(),
      mode: mode,
      transit: (transit == null || transit.isEmpty) ? null : transit,
      steps: (steps == null || steps.isEmpty) ? null : steps,
      departureTime:
          transit?.isNotEmpty == true ? transit!.first['departureTime'] : null,
      arrivalTime:
          transit?.isNotEmpty == true ? transit!.last['arrivalTime'] : null,
    );
    return leg;
  }

  // Route-options cache: the ranked alternatives list per (pair, mode,
  // departure band). Small — each entry is ≤4 routes; user-intent driven
  // (fetched only when the leg sheet opens).
  static final LinkedHashMap<String, List<LegRoute>> _altCache =
      LinkedHashMap();

  /// Ranked route OPTIONS for one leg in one mode: Google's default first
  /// (the recommended one), up to 3 alternates after. Transit keeps only
  /// vehicle-boarding options; the schedule-miss retry applies. Empty list
  /// = nothing routed (caller shows its quiet empty state).
  static Future<List<LegRoute>> fetchLegAlternatives({
    required LatLng from,
    required LatLng to,
    required String mode,
    DateTime? departureTime,
  }) async {
    final key = 'alt|${_cacheKey(from, to, mode, departureTime)}';
    final cached = _altCache[key];
    if (cached != null) return cached;

    Future<List<LegRoute>> fetch(DateTime? dep) async {
      final res = await GoogleMapsService.getOptimizedRouteDetails(
        origin: from,
        destination: LocationModel(
          id: '_leg_dest',
          name: '',
          address: '',
          coordinates: to,
          addedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
        optimizeWaypoints: false,
        mode: mode,
        departureTime: dep,
        includeAlternatives: true,
      );
      if (res['status'] != 'ok') return const [];
      final raw =
          (res['alternativeRoutes'] as List?)?.cast<Map<String, dynamic>>() ??
              const [];
      final out = <LegRoute>[];
      // Transit "alternatives" are often the SAME journey at successive
      // departures (metro every 5 min = 3 identical rows shifted by
      // headway). Dedupe by journey identity — line + board/alight stops
      // per ride — keeping the first (Google's rank, earliest departure).
      // Roads dedupe by via-description + rounded facts.
      final seenSignatures = <String>{};
      for (final r in raw) {
        final transit = (r['transit'] as List?)?.cast<Map<String, dynamic>>();
        // Same honesty rule as single fetches: a "transit" option with no
        // ride is a walk in costume — not an option in this list.
        if (mode == 'transit' && (transit == null || transit.isEmpty)) {
          continue;
        }
        final signature = (transit != null && transit.isNotEmpty)
            ? transit
                .map((s) =>
                    '${s['lineShort']}|${s['boardStop']}|${s['alightStop']}')
                .join('>')
            : '${r['description'] ?? ''}|'
                '${(r['duration'] as Duration).inMinutes}|'
                '${(((r['distance'] as num) / 100)).round()}';
        if (!seenSignatures.add(signature)) continue;
        final steps = (r['steps'] as List?)?.cast<Map<String, dynamic>>();
        out.add(LegRoute(
          points: (r['points'] as List).cast<LatLng>(),
          duration: r['duration'] as Duration,
          distance: (r['distance'] as num).toDouble(),
          mode: mode,
          transit: (transit == null || transit.isEmpty) ? null : transit,
          steps: (steps == null || steps.isEmpty) ? null : steps,
          departureTime: transit?.isNotEmpty == true
              ? transit!.first['departureTime'] as String?
              : null,
          arrivalTime: transit?.isNotEmpty == true
              ? transit!.last['arrivalTime'] as String?
              : null,
          description: r['description'] as String?,
        ));
        if (out.length >= 4) break;
      }
      return out;
    }

    var options = await fetch(departureTime);
    if (options.isEmpty && mode == 'transit' && departureTime != null) {
      final soon = DateTime.now().add(const Duration(minutes: 10));
      if (departureTime.difference(soon).abs() > const Duration(hours: 2)) {
        options = await fetch(soon);
      }
    }

    _altCache[key] = options;
    while (_altCache.length > 60) {
      _altCache.remove(_altCache.keys.first);
    }
    return options;
  }

  /// One A→B leg through the AUTO ladder — used by the From→To route
  /// preview so it stops defaulting to the car. Honors a stored per-leg
  /// override first, then: trivial hop → walk; walk within the user's
  /// max-walk preference → walk; else transit → drive → whatever routed.
  /// Returns null only when nothing routes in any mode.
  static Future<LegRoute?> routeLegSmart({
    required LatLng from,
    required LatLng to,
    String? overrideMode,
    double maxWalkMeters = longWalkMeters,
    DateTime? departureTime,
  }) async {
    Future<LegRoute?> f(String m) => routeSingleLeg(
                from: from, to: to, mode: m, departureTime: departureTime)
            .catchError((Object e) {
          debugPrint('routeLegSmart $m failed: $e');
          return null;
        });

    if (overrideMode != null) {
      // Same rule as the itinerary ladder: a REMEMBERED transit override
      // only replays while its station walks fit the CURRENT max-walk
      // tolerance; past that the car takes the leg (choice kept, not
      // deleted — raising the slider re-honors it).
      if (overrideMode == 'transit') {
        final t = await f('transit');
        if (t != null && _transitWalkOk(t, maxWalkMeters)) return t;
        return await f('drive') ?? t ?? await f('walk');
      }
      return await f(overrideMode) ?? await f('drive') ?? await f('walk');
    }

    final d = _meters(from, to);
    final derivedWalkAlways = maxWalkMeters * 0.8;
    final walkAlwaysStraight = derivedWalkAlways < walkAlwaysMeters
        ? derivedWalkAlways
        : walkAlwaysMeters;
    if (d < walkAlwaysStraight) {
      return await f('walk') ?? await f('drive');
    }
    final walk = await f('walk');
    if (walk != null &&
        walk.distance <= maxWalkMeters &&
        walk.duration <= maxComfortableWalk) {
      return walk;
    }
    // Same rule as the itinerary ladder: a transit itinerary only wins
    // when its station access/egress walking also fits the tolerance —
    // otherwise drive, keeping the over-walk ride as a fallback.
    final transit = await f('transit');
    if (transit != null && _transitWalkOk(transit, maxWalkMeters)) {
      return transit;
    }
    return await f('drive') ?? transit ?? walk;
  }

  static LegRoute _directFallback(LatLng from, LatLng to) => LegRoute(
        points: [from, to],
        duration: Duration.zero,
        distance: _meters(from, to),
        mode: 'direct',
      );

  /// The longest single WALKING run inside a transit leg, in meters —
  /// measured from the run's own geometry (steps carry points, not
  /// distance; a polyline sum tracks the routed length closely enough for
  /// a tolerance check).
  static double _longestTransitWalkMeters(LegRoute leg) {
    var longest = 0.0;
    for (final run in leg.steps ?? const <Map<String, dynamic>>[]) {
      if (run['mode'] != 'WALK') continue;
      final pts = (run['points'] as List?)?.cast<LatLng>() ?? const <LatLng>[];
      var m = 0.0;
      for (var i = 1; i < pts.length; i++) {
        m += _meters(pts[i - 1], pts[i]);
      }
      if (m > longest) longest = m;
    }
    return longest;
  }

  /// Whether a transit itinerary's internal walking (station access,
  /// egress, transfers) respects the user's max-walk tolerance. A "ride"
  /// that opens with a 1.5 km march to the stop is a walk in costume —
  /// the ladder must judge that walk by the same rule it applies to whole
  /// walking legs, and prefer the car instead when it fails.
  ///
  /// Legs without step data pass: old cache entries carry no runs, and a
  /// missing field must not read as "too far".
  static bool _transitWalkOk(LegRoute leg, double maxWalkMeters) =>
      _longestTransitWalkMeters(leg) <= maxWalkMeters;

  // ── The itinerary pipeline ──────────────────────────────────────────────
  /// Routes the (already ordered — ordering is VoyZa's own optimizer) stops:
  ///  1. ONE chain call in the anchor mode gives every leg a baseline.
  ///  2. The ladder picks each leg's target mode (overrides win).
  ///  3. Only ladder-divergent legs get individual calls, cache-first, with
  ///     failure cascades so a leg always ends with SOME geometry.
  /// Sequential on purpose: transit departure times chain off cumulative
  /// arrival + stay, and n≤~15 legs keeps worst-case latency acceptable.
  static Future<Map<String, dynamic>> routeItinerary({
    required LatLng origin,
    required String originId,
    required List<LocationModel> orderedStops,
    required String profile, // 'auto' | 'walk' | 'drive'
    required DateTime departureAnchor,
    Map<String, String> legModeOverrides = const {},
    bool transitEnabled = true,
    // The user's "Max walk between stops" preference, in ROUTED meters.
    // Governs every walking tolerance except the explicit walking style
    // (choosing to walk means walking) and per-leg manual overrides.
    double maxWalkMeters = longWalkMeters,
    // Loop home: when the day STARTS at the accommodation, it isn't in
    // [orderedStops] — this appends a final routed leg from the last stop
    // back to it. (An accommodation that IS a stop already gets pinned as
    // the destination by the scoring above — no return leg needed.)
    LocationModel? returnTo,
    void Function(int done, int total)? onLegProgress,
  }) async {
    // The walk-always shortcut LOWERS with a small max-walk preference but
    // never rises above its 800 m "trivial hop" meaning — a 3 km tolerance
    // must not make Road-trip mode walk 2.4 km hops (the preference is a
    // ceiling, not an eagerness to walk; long walking only extends through
    // the routed checks in the auto-city and transit ladders).
    final derivedWalkAlways = maxWalkMeters * 0.8;
    final walkAlwaysStraight = derivedWalkAlways < walkAlwaysMeters
        ? derivedWalkAlways
        : walkAlwaysMeters;
    if (orderedStops.isEmpty) {
      return {
        'routePoints': <LatLng>[],
        'waypointOrder': <int>[],
        'legDetails': <Map<String, dynamic>>[],
        'legPolylines': <List<LatLng>>[],
        'anchorMode': 'drive',
      };
    }

    // Anchor mode: explicit profile wins; auto sniffs the trip's scale.
    final probe = <LatLng>[origin, ...orderedStops.map((s) => s.coordinates)];
    final maxHop = [
      for (var i = 0; i < orderedStops.length; i++)
        _meters(probe[i], probe[i + 1])
    ].fold<double>(0, (m, d) => d > m ? d : m);
    final isCity = switch (profile) {
      'walk' => true,
      'drive' => false,
      _ => maxHop <= cityHopMeters,
    };
    final anchorMode = isCity ? 'walk' : 'drive';

    // 1) ORDER + route in one call: Google's optimizeWaypointOrder is a
    //    real travel-time TSP (roads, rivers, one-ways), replacing the old
    //    client heuristic whose within-cluster order was just the order the
    //    user ADDED places ("visit 2 then walk back to 3"). The day is
    //    open-ended, and the API needs a fixed destination — the stop
    //    farthest from the start plays that role (days naturally end at
    //    the far point). The client heuristic's order remains the input —
    //    and the fallback when this call fails.
    var stops = List<LocationModel>.from(orderedStops);
    var legCount = stops.length;
    List<LegRoute?> chain = List.filled(legCount, null);
    var chainMode = anchorMode;
    var chainReady = false;

    LegRoute legFrom(Map<String, dynamic> det, List<LatLng> pol, String m) =>
        LegRoute(
          points: pol,
          duration: det['duration'] as Duration,
          distance: (det['distance'] as num).toDouble(),
          mode: m,
        );

    // Fixed destination for the day: the ACCOMMODATION when there is one —
    // you end where you sleep — otherwise the stop farthest from the start
    // (open-ended days naturally end at the far point). On a hotel-change
    // day with two accommodations, the one farther from the start wins:
    // that's where the night is spent. Moving the chosen stop to the END of
    // the list makes every path honor it — the TSP call pins it as the
    // destination, and the fallback/2-stop chains simply route to it last.
    //
    // Skipped entirely on loop-home days (returnTo != null): the return
    // point IS the destination there, and pinning the far stop instead
    // froze the order into an open path with a stapled backtrack home
    // (Taiwan loop: …Kaohsiung → Taitung → Kenting → home instead of
    // …Kenting → Taitung → home up the other coast). The TSP below closes
    // the loop properly, with every stop free to move.
    final loopHome = returnTo != null;
    if (!loopHome && stops.length >= 2) {
      var destIdx = 0;
      var destScore = double.negativeInfinity;
      for (var i = 0; i < stops.length; i++) {
        final score = (stops[i].isAccommodation ? 1e9 : 0) +
            _meters(origin, stops[i].coordinates);
        if (score > destScore) {
          destScore = score;
          destIdx = i;
        }
      }
      final chosen = stops.removeAt(destIdx);
      stops.add(chosen);
    }

    if (stops.length > 2 || (loopHome && stops.length == 2)) {
      // Loop-home: destination = the accommodation and EVERY stop is a free
      // intermediate, so Google solves the closed tour. Open day: the last
      // stop (accommodation or far point) is the pinned destination.
      final dest = loopHome ? returnTo : stops.last;
      final inter = loopHome ? stops : stops.sublist(0, stops.length - 1);
      final res = await GoogleMapsService.getOptimizedRouteDetails(
        origin: origin,
        destination: dest,
        waypoints: inter,
        optimizeWaypoints: true,
        mode: anchorMode,
      );
      if (res['status'] == 'ok') {
        final det = res['legDetails'] as List<Map<String, dynamic>>;
        final pol = res['legPolylines'] as List<List<LatLng>>;
        final order = (res['waypointOrder'] as List).cast<int>();
        if (det.length == inter.length + 1 && order.length == inter.length) {
          stops = [for (final k in order) inter[k], if (!loopHome) dest];
          // Loop-home: the response's LAST leg (final stop → accommodation)
          // is deliberately not kept — the dedicated return-leg block below
          // re-routes it with the full ladder/override/clock treatment,
          // exactly as it did before. Only the ORDER (and the stop-to-stop
          // leg geometry) comes from this closed-tour call.
          chain = [
            for (var i = 0; i < stops.length; i++)
              legFrom(det[i], pol[i], anchorMode)
          ];
          chainReady = true;
        }
      }
    }

    // Fallback chain (and the ≤2-stop case, where order is trivial): route
    // along the given order; anchor fails wholesale (drive in Venice / walk
    // across a bay) → try the opposite base mode before going leg-by-leg.
    if (!chainReady) {
      Future<bool> tryChain(String m) async {
        final res = await GoogleMapsService.getOptimizedRouteDetails(
          origin: origin,
          destination: stops.last,
          waypoints: legCount > 1 ? stops.sublist(0, legCount - 1) : const [],
          optimizeWaypoints: false,
          mode: m,
        );
        if (res['status'] != 'ok') return false;
        final det = res['legDetails'] as List<Map<String, dynamic>>;
        final pol = res['legPolylines'] as List<List<LatLng>>;
        if (det.length != legCount) return false;
        chain = [for (var i = 0; i < legCount; i++) legFrom(det[i], pol[i], m)];
        return true;
      }

      chainMode = anchorMode;
      if (!await tryChain(anchorMode)) {
        chainMode = anchorMode == 'walk' ? 'drive' : 'walk';
        if (!await tryChain(chainMode)) {
          chain = List.filled(legCount, null); // full per-leg routing below
          chainMode = anchorMode;
        }
      }
    }

    // Leg endpoints reflect the FINAL order: origin → s0 → s1 → …
    final points = <LatLng>[origin, ...stops.map((s) => s.coordinates)];
    final ids = <String>[originId, ...stops.map((s) => s.id)];
    legCount = stops.length;

    // 2+3) Resolve each leg. Cumulative clock feeds transit departures.
    final resolved = <LegRoute>[];
    var clock = departureAnchor;
    for (var i = 0; i < legCount; i++) {
      final from = points[i];
      final to = points[i + 1];
      final d = _meters(from, to);
      final overrideMode = legModeOverrides['${ids[i]}>${ids[i + 1]}'];
      final base = chain[i];

      Future<LegRoute?> fetch(String m) =>
          routeSingleLeg(from: from, to: to, mode: m, departureTime: clock)
              .catchError((Object e) {
            debugPrint('leg $i $m failed: $e');
            return null;
          });

      LegRoute? leg;
      if (overrideMode == 'transit') {
        // A REMEMBERED transit choice replays on every re-optimize — but it
        // predates the user's CURRENT max-walk setting, and honoring it
        // blindly resurrects itineraries whose station walks the slider now
        // forbids (tap Transit once while testing, and 572 m marches ignore
        // a 200 m limit forever). Replay it only while its walking still
        // fits; otherwise the car takes the leg this run. The stored choice
        // is NOT deleted — raise the slider and it resumes. A fresh tap in
        // the leg sheet still applies immediately (overrideLegMode), so an
        // explicit in-the-moment pick keeps working.
        final t = transitEnabled ? await fetch('transit') : null;
        if (t != null && _transitWalkOk(t, maxWalkMeters)) {
          leg = t;
        } else {
          leg = (chainMode == 'drive' ? base : null) ??
              await fetch('drive') ??
              t ??
              base;
        }
      } else if (overrideMode != null) {
        // The user chose this leg's mode — honor it, cascade only on failure.
        leg = overrideMode == chainMode
            ? (base ?? await fetch(overrideMode))
            : await fetch(overrideMode);
        leg ??= base ?? await fetch(chainMode == 'walk' ? 'drive' : 'walk');
      } else if (d < walkAlwaysStraight) {
        leg = chainMode == 'walk' ? base : await fetch('walk');
        leg ??= base ?? await fetch('drive');
      } else if (profile == 'transit') {
        // Public-transport style: walk the short hops (handled above),
        // RIDE whenever a real ride exists — even when walking would be
        // quicker, riding is the point of this style — and fall back to
        // a reasonable walk, then car, only when no ride pans out.
        //
        // "Real ride" includes the walk TO it: an itinerary whose station
        // access/egress walk exceeds the user's max-walk tolerance is a
        // walk in costume (500 m tolerance, 1.5 km march to the stop) —
        // treat it like no ride and let the car cover the leg instead.
        final transitLeg = transitEnabled ? await fetch('transit') : null;
        if (transitLeg != null && _transitWalkOk(transitLeg, maxWalkMeters)) {
          leg = transitLeg;
        } else {
          // No acceptable ride. This is a non-walking style, so a walk
          // only stands in when it's short — otherwise the car covers it.
          // An over-walk ride survives as the very last resort: it still
          // beats a straight line.
          final walk =
              (chainMode == 'walk' ? base : null) ?? await fetch('walk');
          final walkAcceptable = walk != null &&
              walk.distance <= maxWalkMeters &&
              walk.duration <= maxComfortableWalk;
          leg = walkAcceptable
              ? walk
              : ((chainMode == 'drive' ? base : null) ??
                  await fetch('drive') ??
                  transitLeg ??
                  walk);
        }
      } else if (isCity || (profile == 'auto' && d <= maxWalkMeters)) {
        // City ladder — judged on the walk's REAL route distance, not the
        // straight line (which undersells city walks by ~25% and let a
        // "1.2 km · 17 min" walk sneak under a 1.2 km crow-flight gate).
        //
        // AUTO also enters here on a NON-city day (one long hop makes
        // [isCity] false for the whole day) whenever this particular leg is
        // still inside the user's max-walk tolerance: "auto" means decide
        // per leg, so a 1.2 km hop must not be driven just because another
        // leg of the day is 40 km away. The crow-flight pre-check is what
        // keeps it cheap — routed distance ≥ straight line, so a leg already
        // beyond the tolerance can never qualify and never costs a probe.
        final walkLeg =
            (chainMode == 'walk' ? base : null) ?? await fetch('walk');
        final walkIsShort = walkLeg != null &&
            walkLeg.distance <= maxWalkMeters &&
            walkLeg.duration <= maxComfortableWalk;
        if (profile == 'walk') {
          // EXPLICIT walking style: the user chose to walk — do, unless
          // transit clearly rescues an unreasonable slog.
          if (d < transitFromMeters) {
            leg = walkLeg ?? await fetch('drive');
          } else {
            final transitLeg = transitEnabled ? await fetch('transit') : null;
            if (transitLeg != null &&
                (walkLeg == null ||
                    walkLeg.duration > maxComfortableWalk ||
                    transitLeg.duration < walkLeg.duration)) {
              leg = transitLeg;
            } else {
              leg = walkLeg;
            }
            leg ??= await fetch('drive');
          }
        } else {
          // AUTO: a hop within the user's max-walk tolerance walks; past it
          // prefer a RIDE — transit first, car when there's none. A transit
          // itinerary only counts when its OWN walking (to/from stations)
          // also respects the tolerance; otherwise the car takes the leg
          // and the over-walk ride drops to a fallback. The long walk
          // survives only as the very last resort.
          if (walkIsShort) {
            leg = walkLeg;
          } else {
            final transitLeg = transitEnabled ? await fetch('transit') : null;
            final transitOk = transitLeg != null &&
                _transitWalkOk(transitLeg, maxWalkMeters);
            leg = transitOk
                ? transitLeg
                : ((chainMode == 'drive' ? base : null) ??
                    await fetch('drive') ??
                    transitLeg ??
                    walkLeg);
          }
        }
      } else {
        // Road-trip ladder: drive, with transit/walk as recovery only.
        leg = base ?? await fetch('drive');
        if (leg == null && transitEnabled) leg = await fetch('transit');
        leg ??= await fetch('walk');
      }

      leg ??= _directFallback(from, to);
      resolved.add(leg);

      // Advance the clock: travel + the stop's dwell time.
      final stay = stops[i].stayDuration;
      clock = clock
          .add(leg.duration)
          .add(stay > Duration.zero ? stay : const Duration(minutes: 60));
      onLegProgress?.call(i + 1, legCount);
    }

    // Loop home: one more routed leg from the day's last stop back to the
    // accommodation the day started from. Same brain as everything else
    // (override honored, auto ladder, max-walk preference), clock-chained
    // so a transit ride home gets evening schedules. Never silently lost:
    // worst case it's a straight-line 'direct' leg.
    if (returnTo != null && stops.isNotEmpty && stops.last.id != returnTo.id) {
      final from = points.last;
      final to = returnTo.coordinates;
      var homeLeg = await routeLegSmart(
        from: from,
        to: to,
        overrideMode: legModeOverrides['${ids.last}>${returnTo.id}'],
        maxWalkMeters: maxWalkMeters,
        departureTime: clock,
      ).catchError((Object e) {
        debugPrint('return leg failed: $e');
        return null;
      });
      homeLeg ??= _directFallback(from, to);
      resolved.add(homeLeg);
      ids.add(returnTo.id);
      onLegProgress?.call(resolved.length, resolved.length);
    }

    return {
      'routePoints': resolved.expand((l) => l.points).toList(growable: false),
      'waypointOrder':
          List<int>.generate(legCount > 1 ? legCount - 1 : legCount, (i) => i),
      'legDetails': [
        for (var i = 0; i < resolved.length; i++)
          {
            'duration': resolved[i].duration,
            'distance': resolved[i].distance,
            'mode': resolved[i].mode,
            'fromId': ids[i],
            'toId': ids[i + 1],
            if (resolved[i].transit != null) 'transit': resolved[i].transit,
            if (resolved[i].steps != null) 'transitSteps': resolved[i].steps,
            if (resolved[i].departureTime != null)
              'departureTime': resolved[i].departureTime,
            if (resolved[i].arrivalTime != null)
              'arrivalTime': resolved[i].arrivalTime,
          }
      ],
      'legPolylines': [for (final l in resolved) l.points],
      'hasReturnLeg': resolved.length == legCount + 1,
      'anchorMode': anchorMode,
      // The FINAL visit order (Google's TSP when it succeeded, the client
      // heuristic otherwise) — trip_provider must adopt it so numbering,
      // cards and travel-time attribution match the legs.
      'orderedStops': stops,
    };
  }
}
