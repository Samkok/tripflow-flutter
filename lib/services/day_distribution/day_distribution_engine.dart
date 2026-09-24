/// The Auto-plan brain: clusters a trip's places into city-scale groups,
/// orders the groups into a visit sequence, slices the sequence into day
/// blocks by capacity, and assigns each movable place to a day — leftovers
/// go to the Unscheduled bucket.
///
/// PURE DART, ZERO API CALLS, NO CLOCK: everything (including `today`)
/// arrives via [DistributionInput], so the same input always produces the
/// same [DistributionPlan] (tie-breaks are by id). Top-level function so it
/// can run under `compute()` for big trips.
///
/// The output is a PROPOSAL — nothing is written here. The only durable
/// effect of applying a plan is per-location `scheduledDate` writes; city
/// order exists purely as the arrangement of day blocks.
library;

import 'dart:math' as math;

import 'distribution_constants.dart';
import 'distribution_models.dart';
import 'tsp.dart';

DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

double _metersBetween(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _metersPlace(EnginePlace a, EnginePlace b) =>
    _metersBetween(a.lat, a.lng, b.lat, b.lng);

int _effStay(EnginePlace p) =>
    p.stayMinutes <= 0 ? kDefaultStayMinutes : p.stayMinutes;

/// Minutes to cover [meters] intra-city under [style].
int _travelMinutes(double meters, String style) {
  final double kmh;
  switch (style) {
    case 'walk':
      kmh = kWalkKmh;
    case 'drive':
      kmh = kDriveKmh;
    default: // 'auto' | 'transit': short hops walk, longer ones ride.
      kmh = meters < kAutoWalkUnderMeters ? kWalkKmh : kTransitKmh;
  }
  final km = meters * kDetourFactor / 1000;
  return (km / kmh * 60).round();
}

/// Google's weekday convention (0=Sun..6=Sat) from a Dart DateTime.
int _googleWeekday(DateTime day) => day.weekday % 7;

/// Mutable per-day fill state shared by the seating passes.
class _DayState {
  final DateTime day;
  final int clusterIndex;
  final int hop;
  final EnginePlace? accommodation;

  /// Where the day begins: that night's hotel, else the city centroid.
  final double startLat;
  final double startLng;

  /// Fixed stops of this city already on the day (done, multi-day, past
  /// rows). They never move, but they pull nearby places onto the day.
  final List<EnginePlace> anchors;
  final int pinnedMinutes;
  final Set<String> keys;

  /// Movable stops seated so far; the visiting order is decided at the end.
  final List<EnginePlace> seated = [];

  /// Seated stops the improvement pass may never move: mega anchors and,
  /// in keep mode, places kept on their current day.
  final Set<String> locked = {};

  /// Place-count quota: this day's share of its city block (≤ the user's
  /// cap). The assignment stops at it so days come out even, not
  /// front-loaded; a final top-up pass may exceed it under a cap only.
  int target = 1 << 30;

  _DayState({
    required this.day,
    required this.clusterIndex,
    required this.hop,
    required this.accommodation,
    required this.startLat,
    required this.startLng,
    required this.anchors,
    required this.pinnedMinutes,
    required this.keys,
  });

  bool get hasRoom => seated.length < target;

  /// Mean of the day's fixed and seated stops; null while it has neither.
  (double, double)? get centroid {
    var n = 0;
    var lat = 0.0, lng = 0.0;
    for (final p in anchors) {
      lat += p.lat;
      lng += p.lng;
      n++;
    }
    for (final p in seated) {
      lat += p.lat;
      lng += p.lng;
      n++;
    }
    return n == 0 ? null : (lat / n, lng / n);
  }
}

/// Visiting order for one day: nearest neighbour from the day's start
/// (hotel or city centre — not itself a stop), then 2-opt with that start
/// fixed. Straight-line distances; the router refines the real route later.
List<EnginePlace> _routeFrom(double lat, double lng, List<EnginePlace> stops) {
  if (stops.length < 2) return [...stops];
  final rest = [...stops]..sort((a, b) => a.id.compareTo(b.id));
  var route = <EnginePlace>[];
  var cLat = lat, cLng = lng;
  while (rest.isNotEmpty) {
    rest.sort((a, b) {
      final c = _metersBetween(cLat, cLng, a.lat, a.lng)
          .compareTo(_metersBetween(cLat, cLng, b.lat, b.lng));
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    final next = rest.removeAt(0);
    route.add(next);
    cLat = next.lat;
    cLng = next.lng;
  }

  double length(List<EnginePlace> r) {
    var s = _metersBetween(lat, lng, r.first.lat, r.first.lng);
    for (var i = 1; i < r.length; i++) {
      s += _metersPlace(r[i - 1], r[i]);
    }
    return s;
  }

  var best = length(route);
  var improved = true;
  while (improved) {
    improved = false;
    for (var i = 0; i < route.length - 1; i++) {
      for (var k = i + 1; k < route.length; k++) {
        final candidate = [
          ...route.sublist(0, i),
          ...route.sublist(i, k + 1).reversed,
          ...route.sublist(k + 1),
        ];
        final l = length(candidate);
        if (l + 1e-6 < best) {
          route = candidate;
          best = l;
          improved = true;
        }
      }
    }
  }
  return route;
}

class _Cluster {
  final List<EnginePlace> movable = [];
  final List<EnginePlace> pinned = []; // non-accommodation pinned members
  double centroidLat = 0;
  double centroidLng = 0;

  List<EnginePlace> get all => [...movable, ...pinned];

  void computeCentroid() {
    final m = all;
    if (m.isEmpty) return;
    centroidLat = m.map((p) => p.lat).reduce((a, b) => a + b) / m.length;
    centroidLng = m.map((p) => p.lng).reduce((a, b) => a + b) / m.length;
  }

  /// Stay + rough internal travel (NN chain from the centroid) for the
  /// MOVABLE content — what day-slicing has to accommodate.
  int loadMinutes(String style) {
    var total = movable.fold<int>(0, (s, p) => s + _effStay(p));
    // NN chain over movable members approximates internal travel.
    if (movable.length > 1) {
      final remaining = [...movable];
      var lat = centroidLat;
      var lng = centroidLng;
      while (remaining.isNotEmpty) {
        remaining.sort((a, b) {
          final c = _metersBetween(lat, lng, a.lat, a.lng)
              .compareTo(_metersBetween(lat, lng, b.lat, b.lng));
          return c != 0 ? c : a.id.compareTo(b.id);
        });
        final next = remaining.removeAt(0);
        total +=
            _travelMinutes(_metersBetween(lat, lng, next.lat, next.lng), style);
        lat = next.lat;
        lng = next.lng;
      }
    }
    return total;
  }

  bool get hasPinnedDay => pinned.isNotEmpty;
}

DistributionPlan computePlan(DistributionInput input) {
  // ── Gates ───────────────────────────────────────────────────────────────
  if (input.tripStart == null || input.tripEnd == null) {
    return DistributionPlan(
        gate: DistributionGate.needsTripDates,
        inputFingerprint: input.fingerprint);
  }
  final today = _dayOf(input.today);
  final axis = <DateTime>[];
  for (var d = _dayOf(input.tripStart!);
      !d.isAfter(_dayOf(input.tripEnd!));
      d = DateTime(d.year, d.month, d.day + 1)) {
    axis.add(d);
  }
  final editableDays = axis.where((d) => !d.isBefore(today)).toList();
  if (editableDays.isEmpty) {
    return DistributionPlan(
        gate: DistributionGate.allDaysPast,
        inputFingerprint: input.fingerprint);
  }

  // ── Partition (determinism: sort first — clustering is order-sensitive) ─
  final places = [...input.places]..sort((a, b) {
      final ad = a.scheduledDay?.millisecondsSinceEpoch ?? 1 << 52;
      final bd = b.scheduledDay?.millisecondsSinceEpoch ?? 1 << 52;
      final c = ad.compareTo(bd);
      return c != 0 ? c : a.id.compareTo(b.id);
    });

  bool isPastPinned(EnginePlace p) =>
      p.scheduledDay != null && _dayOf(p.scheduledDay!).isBefore(today);

  /// Entirely in the past — its last day is before today. On an ongoing
  /// trip those days are lived: the place takes no part in planning what is
  /// left (not clustered, not an anchor, not counted), exactly as if it were
  /// not in the trip. A stay that still reaches today remains pinned for the
  /// days it has left.
  bool isGone(EnginePlace p) {
    final s = p.scheduledDay;
    if (s == null) return false;
    return _dayOf(p.scheduledEndDay ?? s).isBefore(today);
  }

  final ghosts = places.where((p) => p.isSkipped).toList();
  final accommodations = places
      .where((p) => !p.isSkipped && p.isAccommodation && !isGone(p))
      .toList();
  final pinned = places
      .where((p) =>
          !p.isSkipped &&
          !p.isAccommodation &&
          !isGone(p) &&
          (p.isDone || p.scheduledEndDay != null || isPastPinned(p)))
      .toList();
  final movable = places
      .where((p) =>
          !p.isSkipped &&
          !p.isAccommodation &&
          !p.isDone &&
          p.scheduledEndDay == null &&
          !isPastPinned(p))
      .toList();
  if (movable.isEmpty) {
    return DistributionPlan(
        gate: DistributionGate.nothingMovable,
        inputFingerprint: input.fingerprint);
  }

  // ── City clustering: single-link flood fill on straight-line distance ──
  // (Same algorithm as ZoneUtils.clusterLocations, re-implemented on plain
  // records so this file stays Flutter-free.)
  final clusterable = [...movable, ...pinned];
  final assigned = <String>{};
  final clusters = <_Cluster>[];
  for (final seed in clusterable) {
    if (assigned.contains(seed.id)) continue;
    final cluster = _Cluster();
    final queue = [seed];
    assigned.add(seed.id);
    while (queue.isNotEmpty) {
      final cur = queue.removeAt(0);
      (movable.contains(cur) ? cluster.movable : cluster.pinned).add(cur);
      for (final other in clusterable) {
        if (assigned.contains(other.id)) continue;
        if (_metersPlace(cur, other) <= kCityClusterThresholdMeters) {
          assigned.add(other.id);
          queue.add(other);
        }
      }
    }
    cluster.computeCentroid();
    clusters.add(cluster);
  }

  // ── Order clusters: exact shortest Hamiltonian path over centroids ─────
  _Cluster? nearestClusterTo(double lat, double lng) {
    _Cluster? best;
    var bestD = double.infinity;
    for (final c in clusters) {
      final d = _metersBetween(lat, lng, c.centroidLat, c.centroidLng);
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }

  bool covers(EnginePlace p, DateTime day) {
    final s = p.scheduledDay;
    if (s == null) return false;
    final e = p.scheduledEndDay ?? s;
    return !day.isBefore(_dayOf(s)) && !day.isAfter(_dayOf(e));
  }

  EnginePlace? accommodationOn(DateTime day) {
    for (final a in accommodations) {
      if (covers(a, day)) return a;
    }
    return null;
  }

  int? startIdx;
  int? endIdx;
  final firstAcc = accommodationOn(editableDays.first);
  if (firstAcc != null) {
    final c = nearestClusterTo(firstAcc.lat, firstAcc.lng);
    if (c != null) startIdx = clusters.indexOf(c);
  } else {
    // Cluster holding the earliest pinned day anchors the start.
    EnginePlace? earliest;
    for (final p in pinned) {
      if (p.scheduledDay == null) continue;
      if (earliest == null ||
          p.scheduledDay!.isBefore(earliest.scheduledDay!)) {
        earliest = p;
      }
    }
    if (earliest != null) {
      final c = clusters.firstWhere((c) => c.pinned.contains(earliest));
      startIdx = clusters.indexOf(c);
    }
  }
  final lastAcc = accommodationOn(editableDays.last);
  if (lastAcc != null) {
    final c = nearestClusterTo(lastAcc.lat, lastAcc.lng);
    if (c != null) {
      endIdx = clusters.indexOf(c);
      // A contradictory pin (same cluster both ends, more than one
      // cluster) frees the end instead of crashing the solver.
      if (endIdx == startIdx && clusters.length > 1) endIdx = null;
    }
  }

  final matrix = [
    for (final a in clusters)
      [
        for (final b in clusters)
          _metersBetween(
              a.centroidLat, a.centroidLng, b.centroidLat, b.centroidLng)
      ]
  ];
  var order = shortestHamiltonianPath(matrix, start: startIdx, end: endIdx)
      .map((i) => clusters[i])
      .toList();

  // ── Absorb day-trip satellites into their tour-order neighbor ──────────
  var absorbed = true;
  while (absorbed && order.length > 1) {
    absorbed = false;
    for (var i = 0; i < order.length; i++) {
      final c = order[i];
      if (c.hasPinnedDay) continue;
      if (c.loadMinutes(input.travelStyle) >= kSatelliteMaxLoadMinutes) {
        continue;
      }
      _Cluster? neighbor;
      var nd = double.infinity;
      for (final j in [i - 1, i + 1]) {
        if (j < 0 || j >= order.length) continue;
        final d = _metersBetween(c.centroidLat, c.centroidLng,
            order[j].centroidLat, order[j].centroidLng);
        if (d < nd) {
          nd = d;
          neighbor = order[j];
        }
      }
      if (neighbor != null && nd < kSatelliteAbsorbMaxMeters) {
        neighbor.movable.addAll(c.movable);
        neighbor.pinned.addAll(c.pinned);
        neighbor.computeCentroid();
        order.removeAt(i);
        absorbed = true;
        break;
      }
    }
  }

  // More clusters than days: merge the lightest into its nearest tour
  // neighbor until every surviving cluster can own at least one day.
  while (order.length > editableDays.length && order.length > 1) {
    var lightest = 0;
    var lightestLoad = double.infinity;
    for (var i = 0; i < order.length; i++) {
      final l = order[i].loadMinutes(input.travelStyle).toDouble();
      if (l < lightestLoad) {
        lightestLoad = l;
        lightest = i;
      }
    }
    final c = order[lightest];
    final j = lightest == 0 ? 1 : lightest - 1;
    order[j].movable.addAll(c.movable);
    order[j].pinned.addAll(c.pinned);
    order[j].computeCentroid();
    order.removeAt(lightest);
  }

  // ── Where you SLEEP drives where you ARE ──────────────────────────────
  // A night's accommodation fixes that day to the city around it: the
  // hotel schedule is the strongest signal of the trip's shape, stronger
  // than any geometric tour. Days without a hotel ("free days") are then
  // shared out by time/count quotas exactly as before, in tour order — so
  // a trip with no accommodations at all plans exactly as it always did,
  // and a fully-booked trip follows its hotels night for night.
  final homeClusterOfDay = <DateTime, _Cluster>{};
  for (final day in editableDays) {
    final acc = accommodationOn(day);
    if (acc == null) continue;
    _Cluster? best;
    var bestD = double.infinity;
    for (final c in order) {
      final d = _metersBetween(acc.lat, acc.lng, c.centroidLat, c.centroidLng);
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    // A hotel nowhere near any place the user saved can't anchor a city.
    if (best != null && bestD <= kAccommodationHomeMaxMeters) {
      homeClusterOfDay[day] = best;
    }
  }

  if (homeClusterOfDay.isNotEmpty) {
    // Tour order follows the hotel sequence (first night first); cities
    // with no hotel night slot in wherever they add the least distance.
    final hotelSeq = <_Cluster>[];
    for (final day in editableDays) {
      final c = homeClusterOfDay[day];
      if (c != null && !hotelSeq.contains(c)) hotelSeq.add(c);
    }
    final rest = order.where((c) => !hotelSeq.contains(c)).toList();
    final newOrder = [...hotelSeq];
    double dist(_Cluster a, _Cluster b) => _metersBetween(
        a.centroidLat, a.centroidLng, b.centroidLat, b.centroidLng);
    for (final c in rest) {
      var bestPos = newOrder.length;
      var bestDelta = double.infinity;
      for (var pos = 0; pos <= newOrder.length; pos++) {
        final prev = pos > 0 ? newOrder[pos - 1] : null;
        final next = pos < newOrder.length ? newOrder[pos] : null;
        var delta = 0.0;
        if (prev != null) delta += dist(prev, c);
        if (next != null) delta += dist(c, next);
        if (prev != null && next != null) delta -= dist(prev, next);
        if (delta < bestDelta) {
          bestDelta = delta;
          bestPos = pos;
        }
      }
      newOrder.insert(bestPos, c);
    }
    order = newOrder;
  }

  // ── Day quotas per cluster over the FREE days, in tour order ───────────
  final loads = [for (final c in order) c.loadMinutes(input.travelStyle)];
  final cap = input.maxStopsPerDay;
  final fixedCount = [
    for (final c in order)
      homeClusterOfDay.values.where((h) => identical(h, c)).length
  ];
  final freeDays =
      editableDays.where((d) => !homeClusterOfDay.containsKey(d)).toList();
  // Days a city asks for: with a user cap, PLACE COUNT is the rule
  // (ceil(count / cap)); in Auto, the time budget is (ceil(load / day)).
  int askFor(int i) => cap != null
      ? (order[i].movable.length / cap).ceil()
      : (loads[i] / kDayBudgetMinutes).ceil();
  final need = [
    for (var i = 0; i < order.length; i++)
      math.max(
        // Cities with no hotel night must still get a day if any is free;
        // cities with hotel nights only ask for what those nights don't
        // already cover.
        fixedCount[i] == 0 ? 1 : 0,
        askFor(i) - fixedCount[i],
      )
  ];
  int needTotal() => need.fold(0, (a, b) => a + b);
  while (needTotal() > freeDays.length) {
    // Squeeze the biggest allocation first; a hotel-less city's last day
    // goes only when nothing else can give.
    var big = -1;
    for (var i = 0; i < need.length; i++) {
      final floor = fixedCount[i] == 0 ? 1 : 0;
      if (need[i] > floor && (big == -1 || need[i] > need[big])) big = i;
    }
    if (big == -1) {
      // Every cluster is at its floor and free days still don't suffice:
      // hotel-less cities lose their day (their places overflow, honestly).
      var any = false;
      for (var i = 0; i < need.length; i++) {
        if (need[i] > 0) {
          need[i] -= 1;
          any = true;
          break;
        }
      }
      if (!any) break;
      continue;
    }
    need[big] -= 1;
  }
  // Pack style: days beyond what the limit requires stay FREE instead of
  // being spread — the user wants full days and spare ones, not even ones.
  final pack = cap != null && input.fillStyle == FillStyle.pack;
  while (!pack && needTotal() < freeDays.length) {
    // Spread slack to the most-pressured cluster: load per day it will
    // actually have (hotel nights included; the sum is never 0 — hotel-less
    // clusters keep a floor of 1, the others hold ≥1 hotel night).
    var busiest = 0;
    var pressure = -1.0;
    for (var i = 0; i < need.length; i++) {
      final days = math.max(1, need[i] + fixedCount[i]);
      // Pressure in the unit that rules: places/day under a cap, minutes/day
      // in Auto.
      final p = (cap != null ? order[i].movable.length : loads[i]) / days;
      if (p > pressure) {
        pressure = p;
        busiest = i;
      }
    }
    need[busiest] += 1;
  }

  final clusterOfDay = <DateTime, int>{
    for (final e in homeClusterOfDay.entries) e.key: order.indexOf(e.value),
  };
  final owed = [...need];

  // A free day that already holds a fixed stop (done, multi-day) belongs
  // to that stop's city first: the stop cannot move, so giving the day to
  // another city would only produce a pinnedMismatch.
  for (final day in freeDays) {
    for (var ci = 0; ci < order.length && clusterOfDay[day] == null; ci++) {
      if (owed[ci] > 0 && order[ci].pinned.any((p) => covers(p, day))) {
        clusterOfDay[day] = ci;
        owed[ci] -= 1;
      }
    }
  }

  // The other free days go where they cost the least travel ALONG THE
  // TIMELINE: for each one, in date order, the city still owed a day that
  // adds the least distance between the previous day's city and the next
  // fixed day's city. Staying put costs nothing, so a city's extra days sit
  // beside its hotel nights and a hotel-less city is visited on the way.
  // (Dealing free days out in tour order regardless of where the traveller
  // wakes up — the old rule — zig-zagged whenever a hotel schedule went
  // back to a city, or a free day came after the last hotel night.)
  double centreDist(int a, int b) => _metersBetween(order[a].centroidLat,
      order[a].centroidLng, order[b].centroidLat, order[b].centroidLng);
  int? prevIdx;
  for (var di = 0; di < editableDays.length; di++) {
    final day = editableDays[di];
    final fixed = clusterOfDay[day];
    if (fixed != null) {
      prevIdx = fixed;
      continue;
    }
    int? nextIdx;
    for (var k = di + 1; k < editableDays.length && nextIdx == null; k++) {
      nextIdx = clusterOfDay[editableDays[k]];
    }
    int? best;
    var bestCost = double.infinity;
    for (var ci = 0; ci < order.length; ci++) {
      if (owed[ci] <= 0) continue;
      var cost = 0.0;
      if (prevIdx != null) cost += centreDist(prevIdx, ci);
      if (nextIdx != null) cost += centreDist(ci, nextIdx);
      if (cost < bestCost) {
        bestCost = cost;
        best = ci;
      }
    }
    // No city owed a day → the day stays free (pack style spares them).
    if (best == null) continue;
    clusterOfDay[day] = best;
    owed[best] -= 1;
    prevIdx = best;
  }

  // ── Fill days ──────────────────────────────────────────────────────────
  // Two questions, answered in this order:
  //   1. WHICH day a place gets. Every day of a city block is a compact
  //      neighbourhood: days are seeded farthest-first, each place joins the
  //      day whose centre is nearest (closest pairs first, so a day can't
  //      fill with far places before its near ones), and a swap pass
  //      tightens the result. The greedy walk from the hotel this replaces
  //      left the last day with whatever was skipped on every side of
  //      town. Fixed stops (done, multi-day, past) pull their neighbours
  //      onto their day; a weekday the place is closed on is avoided while
  //      an open day has room; when a city has several hotels, each hotel's
  //      nights take the places nearest that hotel.
  //   2. In WHAT order: a nearest-neighbour route from the hotel, 2-opted.
  final warnings = <DistributionWarning>[];
  final perDay = <PlannedDay>[];
  final assignedDay = <String, DateTime>{};

  // Pinned occupancy per day (capacity + same-day duplicate keys).
  int pinnedMinutesOn(DateTime day) {
    var m = 0;
    for (final p in pinned) {
      if (covers(p, day)) m += math.min(_effStay(p), kDayBudgetMinutes);
    }
    return m;
  }

  Set<String> keysOn(DateTime day) => {
        for (final p in [...pinned, ...accommodations, ...ghosts])
          if (covers(p, day)) p.placeKey,
      };

  final remaining = [...movable];
  int byId(EnginePlace a, EnginePlace b) => a.id.compareTo(b.id);

  // Per-day mutable fill state, prepared up front so every pass below
  // shares it. Hop is charged to each city block's first day (never the
  // trip's very first block — you wake up there).
  final dayStates = <_DayState>[];
  var prevClusterIdx = -1;
  for (final day in editableDays) {
    final ci = clusterOfDay[day] ?? -1;
    if (ci == -1) continue;
    final cluster = order[ci];
    var hop = 0;
    if (ci != prevClusterIdx && prevClusterIdx != -1) {
      final prev = order[prevClusterIdx];
      final km = _metersBetween(prev.centroidLat, prev.centroidLng,
              cluster.centroidLat, cluster.centroidLng) *
          kIntercityDetourFactor /
          1000;
      hop = (km / kIntercityKmh * 60)
          .round()
          .clamp(kIntercityHopMinMinutes, kIntercityHopMaxMinutes);
    }
    prevClusterIdx = ci;
    final acc = accommodationOn(day);
    dayStates.add(_DayState(
      day: day,
      clusterIndex: ci,
      hop: hop,
      accommodation: acc,
      startLat: acc?.lat ?? cluster.centroidLat,
      startLng: acc?.lng ?? cluster.centroidLng,
      anchors: [
        for (final p in cluster.pinned)
          if (covers(p, day)) p,
      ],
      pinnedMinutes: pinnedMinutesOn(day),
      keys: keysOn(day),
    ));
  }

  /// Seats [p] on day [s] if the rules allow:
  ///  • place count: ≤ the day's quota, or the user's cap when
  ///    [enforceTarget] is false (no cap = no count limit then);
  ///  • never a same-day duplicate of a place already on the day.
  /// Time is ADVISORY in every mode: Auto means "fit everything across my
  /// days" and a cap means "this many a day" — neither asks the engine to
  /// drop places for being slow. Packed days are reported as overBudgetDay
  /// warnings once the days are filled. The only thing that ever leaves a
  /// place unseated is a user cap smaller than the trip needs (or a
  /// same-day duplicate).
  bool seat(_DayState s, EnginePlace p,
      {bool enforceTarget = true, bool lock = false}) {
    final limit = enforceTarget ? s.target : (cap ?? (1 << 30));
    if (s.seated.length >= limit || s.keys.contains(p.placeKey)) return false;
    remaining.remove(p);
    assignedDay[p.id] = s.day;
    s.seated.add(p);
    s.keys.add(p.placeKey);
    if (lock) s.locked.add(p.id);
    return true;
  }

  void unseat(_DayState s, EnginePlace p) {
    s.seated.remove(p);
    s.keys.remove(p.placeKey);
    assignedDay.remove(p.id);
  }

  bool openOn(EnginePlace p, _DayState s) {
    final open = p.openWeekdays;
    return open == null || open.isEmpty || open.contains(_googleWeekday(s.day));
  }

  double toCentre(EnginePlace p, (double, double) c) =>
      _metersBetween(p.lat, p.lng, c.$1, c.$2);

  (double, double) meanOf(Iterable<EnginePlace> pts) {
    var n = 0;
    var lat = 0.0, lng = 0.0;
    for (final p in pts) {
      lat += p.lat;
      lng += p.lng;
      n++;
    }
    return (lat / n, lng / n);
  }

  // ── Pass 0: mega-stops claim an empty day of their city first. A theme
  // park (stay ≥ half a day) anchors its own day; if the small stops were
  // balanced out first there'd be no empty day left for it and it would
  // overflow. Prefer the day it's already on; seated days stay mega-only
  // for the assignment (the top-up may still add to them under a cap).
  final megaDays = <_DayState>{};
  final megas =
      movable.where((p) => _effStay(p) >= kDayBudgetMinutes ~/ 2).toList()
        ..sort((a, b) {
          final c = _effStay(b).compareTo(_effStay(a));
          return c != 0 ? c : a.id.compareTo(b.id);
        });
  for (final p in megas) {
    final ci = order.indexWhere((c) => c.movable.contains(p));
    if (ci == -1) continue;
    final blockDays = dayStates
        .where((s) => s.clusterIndex == ci && s.seated.isEmpty)
        .toList();
    if (blockDays.isEmpty) continue;
    _DayState? chosen;
    if (input.keepCurrentDays) {
      for (final s in blockDays) {
        if (p.scheduledDay != null && _dayOf(p.scheduledDay!) == s.day) {
          chosen = s;
          break;
        }
      }
    }
    chosen ??= blockDays.first;
    if (seat(chosen, p, enforceTarget: false, lock: true)) {
      megaDays.add(chosen);
    }
  }

  // Quotas over the days that aren't mega-anchored: a city with 14 places
  // over 3 days aims for 5/5/4, not 7/7/0. Balanced: an exact even split
  // (the odd extra places go to the days that already hold the most of
  // their own places, so an organised trip keeps its shape). Pack: days
  // fill to the limit in date order and the remainder lands on the last.
  // The quota is hard for the assignment; the top-up pass afterwards may
  // exceed it only under a cap, so a place never overflows while a day
  // has room the user allowed.
  {
    final blockDays = <int, List<_DayState>>{};
    for (final s in dayStates) {
      if (megaDays.contains(s)) {
        s.target = s.seated.length; // mega-only
        continue;
      }
      (blockDays[s.clusterIndex] ??= []).add(s);
    }
    for (final e in blockDays.entries) {
      final days = e.value;
      final pool = order[e.key].movable.where(remaining.contains).toList();
      if (pack) {
        var left = pool.length;
        for (final s in days) {
          final t = math.min(cap, left);
          s.target = math.max(1, t);
          left -= t;
        }
        continue;
      }
      final base = pool.length ~/ days.length;
      final extra = pool.length % days.length;
      int ownCount(_DayState s) => !input.keepCurrentDays
          ? 0
          : pool
              .where((p) =>
                  p.scheduledDay != null && _dayOf(p.scheduledDay!) == s.day)
              .length;
      final byOwn = [...days]..sort((a, b) {
          final c = ownCount(b).compareTo(ownCount(a));
          return c != 0 ? c : a.day.compareTo(b.day);
        });
      for (var i = 0; i < byOwn.length; i++) {
        var t = base + (i < extra ? 1 : 0);
        if (cap != null && t > cap) t = cap;
        byOwn[i].target = math.max(1, t);
      }
    }
  }

  // ── Pass 1: minimal disruption — keep every place on its CURRENT day
  // when that day belongs to the place's own city block and its quota
  // allows. An already-well-organised trip therefore round-trips unchanged
  // (isNoOp) instead of being "consolidated". Kept places are locked: the
  // improvement pass below never trades them away. Skipped when the user
  // asks for a fresh arrangement (keepCurrentDays = false).
  for (final s in input.keepCurrentDays ? dayStates : const <_DayState>[]) {
    final cluster = order[s.clusterIndex];
    final own = remaining
        .where((p) =>
            cluster.movable.contains(p) &&
            p.scheduledDay != null &&
            _dayOf(p.scheduledDay!) == s.day)
        .toList()
      ..sort((a, b) {
        // When more want to stay than fit, the ones nearest the day's
        // start (hotel / city centre) keep their place.
        final c = _metersBetween(s.startLat, s.startLng, a.lat, a.lng)
            .compareTo(_metersBetween(s.startLat, s.startLng, b.lat, b.lng));
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    for (final p in own) {
      if (!s.hasRoom) break;
      seat(s, p, lock: true);
    }
  }

  // ── Pass 2: neighbourhoods. [days] share one anchor (one hotel, or
  // none); [pool] is what they have to divide between them.
  void partition(List<_DayState> days, List<EnginePlace> pool) {
    if (days.isEmpty || pool.isEmpty) return;
    bool canTake(_DayState s, EnginePlace p) =>
        s.hasRoom && !s.keys.contains(p.placeKey);

    // Seeds. A day with no fixed or kept stop yet starts from the place
    // farthest from every day that already has a centre (farthest from the
    // pool's own centre for the very first) — the classic farthest-first
    // spread, so the days begin in different parts of town. A place that
    // is open on the day beats any that is closed.
    final poolCentre = meanOf(pool);
    for (final s in days) {
      if (s.centroid != null || !s.hasRoom) continue;
      final centres = [
        for (final o in days)
          if (o.centroid case final c?) c,
      ];
      EnginePlace? best;
      var bestScore = double.negativeInfinity;
      for (final p in pool) {
        if (!canTake(s, p)) continue;
        var score = centres.isEmpty
            ? toCentre(p, poolCentre)
            : centres.map((c) => toCentre(p, c)).reduce(math.min);
        if (!openOn(p, s)) score -= 1e9;
        if (score > bestScore) {
          bestScore = score;
          best = p;
        }
      }
      if (best != null && seat(s, best)) pool.remove(best);
    }

    // Assignment: the closest (place, day-centre) pair goes first, until
    // every quota is met or the pool is empty. A weekday the place is
    // closed on costs kClosedDayPenaltyMeters extra while another day here
    // is open and has room.
    while (true) {
      EnginePlace? bestP;
      _DayState? bestS;
      var bestCost = double.infinity;
      for (final p in pool) {
        final openElsewhere = days.any((o) => canTake(o, p) && openOn(p, o));
        for (final s in days) {
          if (!canTake(s, p)) continue;
          var cost = toCentre(p, s.centroid ?? (s.startLat, s.startLng));
          if (!openOn(p, s) && openElsewhere) cost += kClosedDayPenaltyMeters;
          if (cost < bestCost) {
            bestCost = cost;
            bestP = p;
            bestS = s;
          }
        }
      }
      if (bestP == null) break;
      seat(bestS!, bestP);
      pool.remove(bestP);
    }

    // Tighten: move a stop into a day with room, or swap two stops between
    // days, whenever that brings them closer to their day centres. Locked
    // stops never move; a stop never trades an open day for a closed one.
    bool keyFree(_DayState s, EnginePlace p, EnginePlace leaving) =>
        p.placeKey == leaving.placeKey || !s.keys.contains(p.placeKey);
    for (var pass = 0; pass < kMaxSwapPasses; pass++) {
      var improved = false;
      for (final x in days) {
        for (final y in days) {
          if (identical(x, y)) continue;
          for (final a in [...x.seated]) {
            if (x.locked.contains(a.id)) continue;
            final cx = x.centroid;
            final cy = y.centroid;
            if (cx == null || cy == null) continue;
            if (x.seated.length > 1 &&
                canTake(y, a) &&
                !(openOn(a, x) && !openOn(a, y)) &&
                toCentre(a, cx) - toCentre(a, cy) > kSwapMinGainMeters) {
              unseat(x, a);
              seat(y, a);
              improved = true;
              continue;
            }
            EnginePlace? partner;
            var bestGain = kSwapMinGainMeters;
            for (final b in y.seated) {
              if (y.locked.contains(b.id)) continue;
              if (!keyFree(y, a, b) || !keyFree(x, b, a)) continue;
              if ((openOn(a, x) && !openOn(a, y)) ||
                  (openOn(b, y) && !openOn(b, x))) {
                continue;
              }
              final gain = (toCentre(a, cx) + toCentre(b, cy)) -
                  (toCentre(a, cy) + toCentre(b, cx));
              if (gain > bestGain) {
                bestGain = gain;
                partner = b;
              }
            }
            if (partner != null) {
              unseat(x, a);
              unseat(y, partner);
              seat(y, a);
              seat(x, partner);
              improved = true;
            }
          }
        }
      }
      if (!improved) break;
    }
  }

  for (var ci = 0; ci < order.length; ci++) {
    final blockDays = dayStates
        .where((s) => s.clusterIndex == ci && !megaDays.contains(s))
        .toList();
    final pool = order[ci].movable.where(remaining.contains).toList()
      ..sort(byId);
    if (blockDays.isEmpty || pool.isEmpty) continue;

    final hotelIds = {
      for (final s in blockDays)
        if (s.accommodation case final a?) a.id,
    };
    if (hotelIds.length < 2) {
      partition(blockDays, pool);
      continue;
    }

    // Several hotels in one city: each hotel's nights take the places
    // nearest that hotel (closest pairs first, up to the nights' quotas);
    // hotel-less days of the block are anchored on the city centre.
    final groups = <String?, List<_DayState>>{};
    for (final s in blockDays) {
      (groups[s.accommodation?.id] ??= []).add(s);
    }
    final anchor = <String?, (double, double)>{
      for (final e in groups.entries)
        e.key: e.value.first.accommodation == null
            ? (order[ci].centroidLat, order[ci].centroidLng)
            : (
                e.value.first.accommodation!.lat,
                e.value.first.accommodation!.lng
              ),
    };
    final room = <String?, int>{
      for (final e in groups.entries)
        e.key: e.value
            .fold(0, (n, s) => n + math.max(0, s.target - s.seated.length)),
    };
    final poolFor = <String?, List<EnginePlace>>{
      for (final k in groups.keys) k: <EnginePlace>[],
    };
    final unplaced = [...pool];
    while (unplaced.isNotEmpty) {
      EnginePlace? bestP;
      String? bestG;
      var found = false;
      var bestCost = double.infinity;
      for (final p in unplaced) {
        for (final g in groups.keys) {
          if (room[g]! <= 0) continue;
          final cost = toCentre(p, anchor[g]!);
          if (cost < bestCost) {
            bestCost = cost;
            bestP = p;
            bestG = g;
            found = true;
          }
        }
      }
      if (!found) break;
      poolFor[bestG]!.add(bestP!);
      room[bestG] = room[bestG]! - 1;
      unplaced.remove(bestP);
    }
    for (final e in groups.entries) {
      partition(e.value, poolFor[e.key]!);
    }
  }

  // ── Pass 3: top-up. Whatever is still unseated takes any room its own
  // city's days have left under the user's cap (Auto quotas already cover
  // every place, so only same-day duplicates reach here in Auto), nearest
  // day centre first, open days preferred.
  for (var ci = 0; ci < order.length; ci++) {
    final blockDays = dayStates.where((s) => s.clusterIndex == ci).toList();
    final pool = order[ci].movable.where(remaining.contains).toList()
      ..sort(byId);
    for (final p in pool) {
      _DayState? best;
      var bestCost = double.infinity;
      for (final s in blockDays) {
        if (s.seated.length >= (cap ?? (1 << 30)) ||
            s.keys.contains(p.placeKey)) {
          continue;
        }
        var cost = toCentre(p, s.centroid ?? (s.startLat, s.startLng));
        if (!openOn(p, s)) cost += kClosedDayPenaltyMeters;
        if (cost < bestCost) {
          bestCost = cost;
          best = s;
        }
      }
      if (best != null) seat(best, p, enforceTarget: false);
    }
  }

  // ── Visiting order, time and warnings per day ──────────────────────────
  for (final s in dayStates) {
    final route = _routeFrom(s.startLat, s.startLng, s.seated);
    var used = s.hop + s.pinnedMinutes;
    var lat = s.startLat, lng = s.startLng;
    for (final p in route) {
      used += _travelMinutes(
              _metersBetween(lat, lng, p.lat, p.lng), input.travelStyle) +
          math.min(_effStay(p), kDayBudgetMinutes);
      lat = p.lat;
      lng = p.lng;
      if (_effStay(p) > kDayBudgetMinutes) {
        warnings.add(DistributionWarning(DistributionWarningKind.longStay,
            placeId: p.id, amount: _effStay(p)));
      }
      if (!openOn(p, s)) {
        warnings.add(DistributionWarning(DistributionWarningKind.closedOnDay,
            placeId: p.id, day: s.day));
      }
    }
    if (route.isNotEmpty &&
        used > kDayBudgetMinutes + kOverBudgetToleranceMinutes) {
      warnings.add(DistributionWarning(DistributionWarningKind.overBudgetDay,
          day: s.day, amount: used));
    }
    if (route.isNotEmpty && used < kLightDayMinutes) {
      warnings.add(DistributionWarning(DistributionWarningKind.lightDay,
          day: s.day, amount: used));
    }
    final acc = s.accommodation;
    if (acc != null && route.isNotEmpty) {
      final (mLat, mLng) = meanOf(route);
      final dist = _metersBetween(acc.lat, acc.lng, mLat, mLng);
      if (dist > kAccommodationFarMeters) {
        warnings.add(DistributionWarning(
            DistributionWarningKind.accommodationFar,
            day: s.day,
            amount: dist.round()));
      }
    }
    perDay.add(PlannedDay(
      day: s.day,
      clusterIndex: s.clusterIndex,
      stopIds: [for (final p in route) p.id],
      usedMinutes: used,
      hopMinutes: s.hop,
      accommodationId: s.accommodation?.id,
    ));
  }

  // ── Leftovers → Unscheduled ────────────────────────────────────────────
  final unscheduledIds = [for (final p in remaining) p.id];
  if (remaining.isNotEmpty) {
    final deficit = remaining.fold<int>(0, (s, p) => s + _effStay(p));
    warnings.add(
        DistributionWarning(DistributionWarningKind.overflow, amount: deficit));
  }

  // Pinned rows on a day owned by a different city.
  for (final p in pinned) {
    final s = p.scheduledDay;
    if (s == null) continue;
    final day = _dayOf(s);
    final ci = clusterOfDay[day];
    if (ci == null) continue;
    final own = order.indexWhere((c) => c.pinned.contains(p));
    if (own != -1 && own != ci) {
      warnings.add(DistributionWarning(DistributionWarningKind.pinnedMismatch,
          placeId: p.id, day: day));
    }
  }

  // ── Changes ────────────────────────────────────────────────────────────
  final changes = <PlannedChange>[];
  for (final p in movable) {
    final oldDay = p.scheduledDay == null ? null : _dayOf(p.scheduledDay!);
    final newDay = assignedDay[p.id];
    if (oldDay != newDay) changes.add(PlannedChange(p.id, oldDay, newDay));
  }

  final plannedDays = {for (final d in perDay) d.day};
  return DistributionPlan(
    gate: DistributionGate.ok,
    perDay: perDay,
    changes: changes,
    unscheduledIds: unscheduledIds,
    freeDays: [
      for (final d in editableDays)
        if (!plannedDays.contains(d)) d
    ],
    clusterOrder: [
      for (final c in order)
        CityCluster(
          members: c.all,
          centroidLat: c.centroidLat,
          centroidLng: c.centroidLng,
        )
    ],
    warnings: warnings,
    inputFingerprint: input.fingerprint,
  );
}
