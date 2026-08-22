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

/// Mutable per-day fill state shared by the two seating passes.
class _DayState {
  final DateTime day;
  final int clusterIndex;
  final int hop;
  final EnginePlace? accommodation;
  int budget;
  int used;
  double cursorLat;
  double cursorLng;
  final Set<String> keys;
  final List<String> stopIds = [];

  /// Balanced per-day place count for this day's city block
  /// (ceil(places / days in block), ≤ the user's cap). Seating passes 1–2
  /// stop at it so days come out even instead of front-loaded.
  int target = 1 << 30;

  _DayState({
    required this.day,
    required this.clusterIndex,
    required this.hop,
    required this.accommodation,
    required this.budget,
    required this.used,
    required this.cursorLat,
    required this.cursorLng,
    required this.keys,
  });
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
        total += _travelMinutes(
            _metersBetween(lat, lng, next.lat, next.lng), style);
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

  final ghosts = places.where((p) => p.isSkipped).toList();
  final accommodations =
      places.where((p) => !p.isSkipped && p.isAccommodation).toList();
  final pinned = places
      .where((p) =>
          !p.isSkipped &&
          !p.isAccommodation &&
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

  EnginePlace? accommodationOn(DateTime day) {
    for (final a in accommodations) {
      final s = a.scheduledDay;
      if (s == null) continue;
      final e = a.scheduledEndDay ?? s;
      if (!day.isBefore(_dayOf(s)) && !day.isAfter(_dayOf(e))) return a;
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
  var freeCursor = 0;
  for (var ci = 0; ci < order.length; ci++) {
    for (var k = 0; k < need[ci] && freeCursor < freeDays.length; k++) {
      clusterOfDay[freeDays[freeCursor++]] = ci;
    }
  }

  // ── Fill days: greedy nearest-neighbor with a stability bonus ──────────
  final warnings = <DistributionWarning>[];
  final perDay = <PlannedDay>[];
  final assignedDay = <String, DateTime>{};

  // Pinned occupancy per day (capacity + same-day duplicate keys).
  int pinnedMinutesOn(DateTime day) {
    var m = 0;
    for (final p in pinned) {
      final s = p.scheduledDay;
      if (s == null) continue;
      final e = p.scheduledEndDay ?? s;
      if (!day.isBefore(_dayOf(s)) && !day.isAfter(_dayOf(e))) {
        m += math.min(_effStay(p), kDayBudgetMinutes);
      }
    }
    return m;
  }

  Set<String> keysOn(DateTime day) {
    final keys = <String>{};
    for (final p in [...pinned, ...accommodations, ...ghosts]) {
      final s = p.scheduledDay;
      if (s == null) continue;
      final e = p.scheduledEndDay ?? s;
      if (!day.isBefore(_dayOf(s)) && !day.isAfter(_dayOf(e))) {
        keys.add(p.placeKey);
      }
    }
    return keys;
  }

  final remaining = [...movable];

  // Per-day mutable fill state, prepared up front so the two passes below
  // share it. Hop is charged to each city block's first day (never the
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
    final pinnedMin = pinnedMinutesOn(day);
    dayStates.add(_DayState(
      day: day,
      clusterIndex: ci,
      hop: hop,
      accommodation: acc,
      budget: kDayBudgetMinutes - hop - pinnedMin,
      used: hop + pinnedMin,
      cursorLat: acc?.lat ?? cluster.centroidLat,
      cursorLng: acc?.lng ?? cluster.centroidLng,
      keys: keysOn(day),
    ));
  }


  /// Seats [p] on day [s] if it fits the rules:
  ///  • place count: ≤ the day's balanced target (passes 1–2) or the user's
  ///    cap (pass 3, [enforceTarget] false). No cap = no count limit in
  ///    pass 3.
  ///  • time is ADVISORY in every mode: Auto means "fit everything across
  ///    my days" and a cap means "this many a day" — neither asks the
  ///    engine to drop places for being slow. Packed days are reported as
  ///    overBudgetDay warnings after filling instead.
  /// The only thing that ever leaves a place unseated is a user cap that
  /// is smaller than the trip needs (or a same-day duplicate).
  bool seat(_DayState s, EnginePlace p, {bool enforceTarget = true}) {
    final limit = enforceTarget ? s.target : (cap ?? (1 << 30));
    if (s.stopIds.length >= limit) return false;
    final travel = _travelMinutes(
        _metersBetween(s.cursorLat, s.cursorLng, p.lat, p.lng),
        input.travelStyle);
    final stay = math.min(_effStay(p), kDayBudgetMinutes);
    final cost = travel + stay;
    remaining.remove(p);
    assignedDay[p.id] = s.day;
    s.stopIds.add(p.id);
    s.keys.add(p.placeKey);
    s.budget -= cost;
    s.used += cost;
    s.cursorLat = p.lat;
    s.cursorLng = p.lng;
    if (_effStay(p) > kDayBudgetMinutes) {
      warnings.add(DistributionWarning(DistributionWarningKind.longStay,
          placeId: p.id, amount: _effStay(p)));
    }
    final open = p.openWeekdays;
    if (open != null &&
        open.isNotEmpty &&
        !open.contains(_googleWeekday(s.day))) {
      warnings.add(DistributionWarning(DistributionWarningKind.closedOnDay,
          placeId: p.id, day: s.day));
    }
    return true;
  }

  // ── Pass 0: mega-stops claim an empty day of their city first. A theme
  // park (stay ≥ half a day) anchors its own day; if the small stops were
  // balanced out first there'd be no empty day left for it and it would
  // overflow. Prefer the day it's already on; seated days stay mega-only
  // for the balancing passes (pass 3 may still top them up under a cap).
  final megaDays = <_DayState>{};
  final megas = movable
      .where((p) => _effStay(p) >= kDayBudgetMinutes ~/ 2)
      .toList()
    ..sort((a, b) {
      final c = _effStay(b).compareTo(_effStay(a));
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  for (final p in megas) {
    final ci = order.indexWhere((c) => c.movable.contains(p));
    if (ci == -1) continue;
    final blockDays = dayStates
        .where((s) => s.clusterIndex == ci && s.stopIds.isEmpty)
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
    if (seat(chosen, p, enforceTarget: false)) megaDays.add(chosen);
  }

  // Balanced targets over the days that aren't mega-anchored: a city with
  // 14 places over 3 days aims for 5/5/4, not 7/7/0. The target is a soft
  // ceiling for passes 1–2; pass 3 fills any remaining room so a place
  // never overflows while a day has space.
  {
    final daysPerCluster = <int, int>{};
    for (final s in dayStates) {
      if (megaDays.contains(s)) continue;
      daysPerCluster[s.clusterIndex] =
          (daysPerCluster[s.clusterIndex] ?? 0) + 1;
    }
    for (final s in dayStates) {
      if (megaDays.contains(s)) {
        s.target = s.stopIds.length; // mega-only
        continue;
      }
      final count = order[s.clusterIndex]
          .movable
          .where((p) => remaining.contains(p))
          .length;
      final days = daysPerCluster[s.clusterIndex] ?? 1;
      // Pack: every day aims for the limit itself; balanced: even split.
      var t = pack ? cap : (count / days).ceil();
      if (cap != null && t > cap) t = cap;
      s.target = math.max(1, t);
    }
  }

  // ── Pass 1: minimal disruption — keep every place on its CURRENT day
  // when that day belongs to the place's own city block and it fits. An
  // already-well-organized trip therefore round-trips unchanged (isNoOp)
  // instead of being "consolidated" into front-loaded days. Skipped when
  // the user asks for a fresh arrangement (keepCurrentDays = false).
  for (final s in input.keepCurrentDays ? dayStates : const <_DayState>[]) {
    final cluster = order[s.clusterIndex];
    while (true) {
      final own = remaining
          .where((p) =>
              cluster.movable.contains(p) &&
              p.scheduledDay != null &&
              _dayOf(p.scheduledDay!) == s.day &&
              !s.keys.contains(p.placeKey))
          .toList();
      if (own.isEmpty) break;
      own.sort((a, b) {
        final c = _metersBetween(s.cursorLat, s.cursorLng, a.lat, a.lng)
            .compareTo(
                _metersBetween(s.cursorLat, s.cursorLng, b.lat, b.lng));
        return c != 0 ? c : a.id.compareTo(b.id);
      });
      if (!seat(s, own.first)) break;
    }
  }

  // ── Pass 2: greedy nearest-neighbor fill of the leftovers (wrong-day
  // rows, bucket rows, overflow from pass 1) into remaining capacity.
  for (final s in dayStates) {
    final cluster = order[s.clusterIndex];
    while (true) {
      final candidates = remaining
          .where((p) =>
              cluster.movable.contains(p) && !s.keys.contains(p.placeKey))
          .toList();
      if (candidates.isEmpty) break;
      candidates.sort((a, b) {
        final c = _metersBetween(s.cursorLat, s.cursorLng, a.lat, a.lng)
            .compareTo(
                _metersBetween(s.cursorLat, s.cursorLng, b.lat, b.lng));
        return c != 0 ? c : a.id.compareTo(b.id);
      });
      if (!seat(s, candidates.first)) break;
    }
  }

  // ── Pass 3: anything still unseated takes any room left in its own
  // city's days (cap still binding; Auto's time budget still binding).
  for (final s in dayStates) {
    final cluster = order[s.clusterIndex];
    while (true) {
      final candidates = remaining
          .where((p) =>
              cluster.movable.contains(p) && !s.keys.contains(p.placeKey))
          .toList();
      if (candidates.isEmpty) break;
      candidates.sort((a, b) {
        final c = _metersBetween(s.cursorLat, s.cursorLng, a.lat, a.lng)
            .compareTo(
                _metersBetween(s.cursorLat, s.cursorLng, b.lat, b.lng));
        return c != 0 ? c : a.id.compareTo(b.id);
      });
      if (!seat(s, candidates.first, enforceTarget: false)) break;
    }
  }

  for (final s in dayStates) {
    if (s.stopIds.isNotEmpty &&
        s.used > kDayBudgetMinutes + kOverBudgetToleranceMinutes) {
      warnings.add(DistributionWarning(DistributionWarningKind.overBudgetDay,
          day: s.day, amount: s.used));
    }
    if (s.stopIds.isNotEmpty && s.used < kLightDayMinutes) {
      warnings.add(DistributionWarning(DistributionWarningKind.lightDay,
          day: s.day, amount: s.used));
    }
    final acc = s.accommodation;
    if (acc != null && s.stopIds.isNotEmpty) {
      var mLat = 0.0, mLng = 0.0;
      for (final id in s.stopIds) {
        final p = movable.firstWhere((p) => p.id == id);
        mLat += p.lat;
        mLng += p.lng;
      }
      mLat /= s.stopIds.length;
      mLng /= s.stopIds.length;
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
      stopIds: s.stopIds,
      usedMinutes: s.used,
      hopMinutes: s.hop,
      accommodationId: s.accommodation?.id,
    ));
  }

  // ── Leftovers → Unscheduled ────────────────────────────────────────────
  final unscheduledIds = [for (final p in remaining) p.id];
  if (remaining.isNotEmpty) {
    final deficit = remaining.fold<int>(0, (s, p) => s + _effStay(p));
    warnings.add(DistributionWarning(DistributionWarningKind.overflow,
        amount: deficit));
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
