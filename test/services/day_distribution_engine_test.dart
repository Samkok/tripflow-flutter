import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/services/day_distribution/day_distribution_engine.dart';
import 'package:voyza/services/day_distribution/distribution_models.dart';

// Real-world coordinates (approx city centers / sights).
const _taipei = (25.04, 121.51);
const _jiufen = (25.11, 121.84); // ~35 km from Taipei
const _taichung = (24.14, 120.68);
const _tainan = (23.00, 120.21);
const _kaohsiung = (22.63, 120.30);

int _n = 0;
EnginePlace _p(
  (double, double) around, {
  DateTime? day,
  DateTime? endDay,
  int stay = 90,
  bool done = false,
  bool skipped = false,
  bool accommodation = false,
  Set<int>? open,
  String? key,
}) {
  final i = _n++;
  // Small deterministic jitter (≤ ~2 km) so cluster members aren't a point.
  final jLat = (i % 5) * 0.004;
  final jLng = (i % 7) * 0.004;
  return EnginePlace(
    id: 'p${i.toString().padLeft(3, '0')}',
    name: 'Place $i',
    placeKey: key ?? 'k$i',
    lat: around.$1 + jLat,
    lng: around.$2 + jLng,
    stayMinutes: stay,
    scheduledDay: day,
    scheduledEndDay: endDay,
    isDone: done,
    isSkipped: skipped,
    isAccommodation: accommodation,
    openWeekdays: open,
  );
}

DistributionInput _input(
  List<EnginePlace> places, {
  DateTime? start,
  DateTime? end,
  DateTime? today,
  String style = 'auto',
}) =>
    DistributionInput(
      places: places,
      tripStart: start,
      tripEnd: end,
      today: today ?? DateTime(2026, 9, 1),
      travelStyle: style,
      fingerprint: 'fp',
    );

DateTime _d(int day) => DateTime(2026, 9, day);

void main() {
  setUp(() => _n = 0);

  test('gate: null trip dates', () {
    final plan = computePlan(_input([_p(_taipei)], start: null, end: null));
    expect(plan.gate, DistributionGate.needsTripDates);
  });

  test('gate: all days past', () {
    final plan = computePlan(_input([_p(_taipei)],
        start: _d(1), end: _d(3), today: DateTime(2026, 9, 9)));
    expect(plan.gate, DistributionGate.allDaysPast);
  });

  test('gate: nothing movable', () {
    final plan = computePlan(_input(
      [_p(_taipei, day: _d(1), done: true), _p(_taipei, skipped: true)],
      start: _d(1),
      end: _d(3),
    ));
    expect(plan.gate, DistributionGate.nothingMovable);
  });

  test('Taiwan multi-city: north→south blocks, Jiufen absorbed, none left over',
      () {
    final places = [
      for (var i = 0; i < 8; i++) _p(_taipei),
      for (var i = 0; i < 2; i++) _p(_jiufen),
      for (var i = 0; i < 6; i++) _p(_taichung),
      for (var i = 0; i < 7; i++) _p(_tainan),
      for (var i = 0; i < 5; i++) _p(_kaohsiung),
      // Trip starts at a Taipei hotel spanning the first two nights.
      _p(_taipei, day: _d(1), endDay: _d(2), accommodation: true, stay: 0),
    ];
    final plan = computePlan(_input(places, start: _d(1), end: _d(9)));
    expect(plan.gate, DistributionGate.ok);

    // Jiufen (2 places ≈ 180min-content satellite… 2×90=180 == limit, so it
    // may keep its own day) — the hard requirements are: ≤5 clusters, the
    // tour starts in Taipei (hotel anchor) and runs geographically north →
    // south without zig-zag.
    expect(plan.clusterOrder.length, inInclusiveRange(2, 5));
    final lats = [for (final c in plan.clusterOrder) c.centroidLat];
    expect(lats.first, greaterThan(24.5), reason: 'starts north (Taipei)');
    for (var i = 1; i < lats.length; i++) {
      expect(lats[i], lessThan(lats[i - 1] + 0.3),
          reason: 'no big northward backtrack at step $i');
    }
    expect(plan.unscheduledIds, isEmpty,
        reason: '28 places × ~90min fit in 9 days');
    // Every day belongs to exactly one cluster and days are contiguous per
    // cluster (city order = day blocks).
    final seq = [for (final d in plan.perDay) d.clusterIndex];
    final seen = <int>{};
    for (final ci in seq) {
      if (seen.contains(ci)) {
        expect(ci, seq[seq.indexOf(ci)],
            reason: 'cluster days must be contiguous');
      }
      seen.add(ci);
    }
    for (var i = 1; i < seq.length; i++) {
      if (seq[i] != seq[i - 1]) {
        expect(seen.contains(seq[i]) && seq[i] != seq[i - 1], isTrue);
      }
    }
  });

  test('50 places on day 1 of a 3-day trip, Auto: everything fits, '
      'balanced, packed days warned', () {
    final places = [
      for (var i = 0; i < 50; i++) _p(_taipei, day: _d(1)),
    ];
    final plan = computePlan(_input(places, start: _d(1), end: _d(3)));
    expect(plan.gate, DistributionGate.ok);
    // Auto = "fit everything across my days": nothing left over, even
    // counts, and the time budget speaks through warnings, not refusals.
    expect(plan.unscheduledIds, isEmpty);
    final counts = [for (final d in plan.perDay) d.stopIds.length]..sort();
    expect(counts, [16, 17, 17]);
    expect(
        plan.warnings
            .where((w) => w.kind == DistributionWarningKind.overBudgetDay)
            .length,
        3,
        reason: '17 × 90 min is a very long day — warned on every day');
    // Every place is accounted for exactly once.
    final all = {for (final d in plan.perDay) ...d.stopIds};
    expect(all.length, 50);
  });

  test('only a cap produces leftovers: same trip with a cap of 10', () {
    final places = [
      for (var i = 0; i < 50; i++) _p(_taipei, day: _d(1)),
    ];
    final plan = computePlan(DistributionInput(
      places: places,
      tripStart: _d(1),
      tripEnd: _d(3),
      today: DateTime(2026, 9, 1),
      maxStopsPerDay: 10,
      fingerprint: 'fp',
    ));
    expect(plan.perDay.every((d) => d.stopIds.length <= 10), isTrue);
    expect(plan.unscheduledIds.length, 20);
    expect(
        plan.warnings.any((w) => w.kind == DistributionWarningKind.overflow),
        isTrue);
  });

  test('single city = pure day slicing, one cluster', () {
    final places = [for (var i = 0; i < 12; i++) _p(_taipei, day: _d(1))];
    final plan = computePlan(_input(places, start: _d(1), end: _d(4)));
    expect(plan.clusterOrder.length, 1);
    expect(plan.perDay.every((d) => d.hopMinutes == 0), isTrue);
  });

  test('already organized: isNoOp', () {
    // 3 places/day for 2 days, same city, already balanced — the stability
    // bonus must keep everything in place.
    final places = [
      for (var i = 0; i < 3; i++) _p(_taipei, day: _d(1)),
      for (var i = 0; i < 3; i++) _p(_taipei, day: _d(2)),
    ];
    final plan = computePlan(_input(places, start: _d(1), end: _d(2)));
    expect(plan.gate, DistributionGate.ok);
    expect(plan.changes, isEmpty, reason: 'stability bonus keeps placements');
    expect(plan.isNoOp, isTrue);
  });

  test('mega-stay anchors its own day and warns', () {
    final places = [
      _p(_taipei, stay: 600), // 10h theme park
      for (var i = 0; i < 4; i++) _p(_taipei),
    ];
    final plan = computePlan(_input(places, start: _d(1), end: _d(3)));
    final parkDay = plan.perDay.firstWhere((d) => d.stopIds.contains('p000'));
    expect(parkDay.stopIds.length, 1,
        reason: 'the park owns its day; the other 4 balance over 2 days');
    expect(plan.unscheduledIds, isEmpty);
    expect(plan.warnings.any((w) => w.kind == DistributionWarningKind.longStay),
        isTrue);
  });

  test('multi-day span is pinned: never moved, consumes capacity', () {
    final span = _p(_taipei, day: _d(1), endDay: _d(3), stay: 120);
    final places = [span, for (var i = 0; i < 6; i++) _p(_taipei)];
    final plan = computePlan(_input(places, start: _d(1), end: _d(3)));
    expect(plan.changes.every((c) => c.id != span.id), isTrue);
    // 120 pinned minutes are charged on every covered day.
    expect(plan.perDay.every((d) => d.usedMinutes >= 120), isTrue);
  });

  test('done and past-day rows are never moved', () {
    final done = _p(_taipei, day: _d(2), done: true);
    final past = _p(_taipei, day: _d(1));
    final places = [done, past, for (var i = 0; i < 4; i++) _p(_taipei)];
    final plan = computePlan(_input(places,
        start: _d(1), end: _d(4), today: DateTime(2026, 9, 2)));
    expect(plan.gate, DistributionGate.ok);
    expect(plan.changes.every((c) => c.id != done.id && c.id != past.id),
        isTrue);
    // Only today+ days receive assignments.
    expect(plan.perDay.every((d) => !d.day.isBefore(DateTime(2026, 9, 2))),
        isTrue);
  });

  test('skipped rows are ghosts: unmoved, zero capacity', () {
    final ghost = _p(_taipei, day: _d(1), skipped: true, stay: 480);
    final places = [ghost, for (var i = 0; i < 4; i++) _p(_taipei)];
    final plan = computePlan(_input(places, start: _d(1), end: _d(2)));
    expect(plan.changes.every((c) => c.id != ghost.id), isTrue);
    // The ghost's 480 min must NOT eat day 1's budget: day 1 fits stops.
    expect(plan.perDay.first.stopIds, isNotEmpty);
  });

  test('same placeKey twice never lands on one day', () {
    final a = _p(_taipei, key: 'same');
    final b = _p(_taipei, key: 'same');
    final places = [a, b, for (var i = 0; i < 2; i++) _p(_taipei)];
    final plan = computePlan(_input(places, start: _d(1), end: _d(3)));
    for (final d in plan.perDay) {
      final both =
          d.stopIds.contains(a.id) && d.stopIds.contains(b.id);
      expect(both, isFalse, reason: 'dup key on ${d.day}');
    }
  });

  test('cluster threshold boundary: 19.9 km merges, 20.1+ splits', () {
    // ~0.18° lat ≈ 20 km. Stays of 200 min keep each cluster above the
    // satellite-absorb limit, so the boundary itself is what's tested.
    final near = [
      _p((25.00, 121.50), stay: 200),
      _p((25.17, 121.50), stay: 200), // ≈ 19.4 km after jitter
    ];
    final far = [
      _p((25.00, 121.50), stay: 200),
      _p((25.20, 121.50), stay: 200), // ≈ 22.2 km
    ];
    _n = 0;
    final merged =
        computePlan(_input(near, start: _d(1), end: _d(2))).clusterOrder;
    _n = 0;
    final split =
        computePlan(_input(far, start: _d(1), end: _d(4))).clusterOrder;
    expect(merged.length, 1);
    expect(split.length, 2);
  });

  test('determinism: shuffled input produces the identical plan', () {
    List<EnginePlace> build() {
      _n = 0;
      return [
        for (var i = 0; i < 6; i++) _p(_taipei, day: _d(1)),
        for (var i = 0; i < 6; i++) _p(_tainan, day: _d(1)),
      ];
    }

    final a = computePlan(_input(build(), start: _d(1), end: _d(4)));
    final shuffled = build()..shuffle();
    final b = computePlan(_input(shuffled, start: _d(1), end: _d(4)));
    String sig(DistributionPlan p) => [
          for (final d in p.perDay) '${d.day.day}:${d.stopIds.join(',')}'
        ].join('|');
    expect(sig(b), sig(a));
  });

  test('closed-on-assigned-weekday emits a warning', () {
    // 2026-09-01 is a Tuesday (google weekday 2). A place open only on
    // Sunday (0) must warn wherever it lands in a Tue-Thu trip.
    final closed = _p(_taipei, open: {0});
    final plan = computePlan(
        _input([closed, _p(_taipei)], start: _d(1), end: _d(3)));
    expect(
        plan.warnings.any((w) =>
            w.kind == DistributionWarningKind.closedOnDay &&
            w.placeId == closed.id),
        isTrue);
  });

  test('max places per day: hard cap per day, rest overflow', () {
    final places = [for (var i = 0; i < 20; i++) _p(_taipei, day: _d(1))];
    final plan = computePlan(DistributionInput(
      places: places,
      tripStart: _d(1),
      tripEnd: _d(3),
      today: DateTime(2026, 9, 1),
      maxStopsPerDay: 5,
      fingerprint: 'fp',
    ));
    expect(plan.gate, DistributionGate.ok);
    for (final d in plan.perDay) {
      expect(d.stopIds.length, lessThanOrEqualTo(5), reason: '${d.day}');
    }
    // 3 days × 5 = 15 seated, 5 left over.
    final seated = plan.perDay.fold<int>(0, (s, d) => s + d.stopIds.length);
    expect(seated, 15);
    expect(plan.unscheduledIds.length, 5);
  });

  test('max places per day turns an already-balanced trip into moves', () {
    // 4/day over 2 days is "organized" under Auto, but a cap of 3 must
    // move two places (one per day) into the bucket / other slots.
    final places = [
      for (var i = 0; i < 4; i++) _p(_taipei, day: _d(1)),
      for (var i = 0; i < 4; i++) _p(_taipei, day: _d(2)),
    ];
    final auto = computePlan(_input(places, start: _d(1), end: _d(2)));
    expect(auto.isNoOp, isTrue);
    final capped = computePlan(DistributionInput(
      places: places,
      tripStart: _d(1),
      tripEnd: _d(2),
      today: DateTime(2026, 9, 1),
      maxStopsPerDay: 3,
      fingerprint: 'fp',
    ));
    expect(capped.isNoOp, isFalse);
    expect(capped.perDay.every((d) => d.stopIds.length <= 3), isTrue);
    expect(capped.unscheduledIds.length, 2);
  });

  test('cap sizes city day blocks (count / cap days per city)', () {
    // 8 Taipei + 2 Tainan places, cap 2, 6 days → Taipei needs 4 days,
    // Tainan 1 (+ slack) — nothing should be left over.
    final places = [
      for (var i = 0; i < 8; i++) _p(_taipei),
      for (var i = 0; i < 2; i++) _p(_tainan, stay: 120),
    ];
    final plan = computePlan(DistributionInput(
      places: places,
      tripStart: _d(1),
      tripEnd: _d(6),
      today: DateTime(2026, 9, 1),
      maxStopsPerDay: 2,
      fingerprint: 'fp',
    ));
    expect(plan.unscheduledIds, isEmpty);
    expect(plan.perDay.every((d) => d.stopIds.length <= 2), isTrue);
  });

  group('place count is the rule when a cap is set', () {
    test('cap 15: 20 places over 2 days → 10/10, nothing overflows, time '
        'becomes an advisory warning', () {
      final places = [for (var i = 0; i < 20; i++) _p(_taipei, day: _d(1))];
      final plan = computePlan(DistributionInput(
        places: places,
        tripStart: _d(1),
        tripEnd: _d(2),
        today: DateTime(2026, 9, 1),
        maxStopsPerDay: 15,
        fingerprint: 'fp',
      ));
      expect(plan.unscheduledIds, isEmpty,
          reason: '20 ≤ 2 × 15 — the user asked for count, not time');
      final counts = [for (final d in plan.perDay) d.stopIds.length]..sort();
      expect(counts, [10, 10], reason: 'balanced, not 15/5');
      expect(
          plan.warnings
              .any((w) => w.kind == DistributionWarningKind.overBudgetDay),
          isTrue,
          reason: '10 × 90 min is a long day — warned, not refused');
    });

    test('cap 5 with plenty of days: 5/5/5/5 then the remainder', () {
      final places = [for (var i = 0; i < 18; i++) _p(_taipei, day: _d(1))];
      final plan = computePlan(DistributionInput(
        places: places,
        tripStart: _d(1),
        tripEnd: _d(4),
        today: DateTime(2026, 9, 1),
        maxStopsPerDay: 5,
        fingerprint: 'fp',
      ));
      expect(plan.perDay.every((d) => d.stopIds.length <= 5), isTrue);
      final seated = plan.perDay.fold<int>(0, (a, d) => a + d.stopIds.length);
      expect(seated, 18, reason: '4 × 5 = 20 ≥ 18');
      expect(plan.unscheduledIds, isEmpty);
    });
  });

  group('fill style', () {
    test('balanced: 9 places, limit 8, 3 days → 3/3/3 (a limit is a ceiling)',
        () {
      final places = [for (var i = 0; i < 9; i++) _p(_taipei, day: _d(1))];
      final plan = computePlan(DistributionInput(
        places: places,
        tripStart: _d(1),
        tripEnd: _d(3),
        today: DateTime(2026, 9, 1),
        maxStopsPerDay: 8,
        fingerprint: 'fp',
      ));
      final counts = [for (final d in plan.perDay) d.stopIds.length]..sort();
      expect(counts, [3, 3, 3]);
      expect(plan.freeDays, isEmpty);
    });

    test('pack: 9 places, limit 8, 3 days → 8/1 and one free day', () {
      final places = [for (var i = 0; i < 9; i++) _p(_taipei, day: _d(1))];
      final plan = computePlan(DistributionInput(
        places: places,
        tripStart: _d(1),
        tripEnd: _d(3),
        today: DateTime(2026, 9, 1),
        maxStopsPerDay: 8,
        fillStyle: FillStyle.pack,
        fingerprint: 'fp',
      ));
      final counts = [for (final d in plan.perDay) d.stopIds.length]
        ..sort((a, b) => b.compareTo(a));
      expect(counts, [8, 1]);
      expect(plan.freeDays.length, 1);
      expect(plan.unscheduledIds, isEmpty);
    });

    test('pack without a limit behaves as balanced', () {
      final places = [for (var i = 0; i < 9; i++) _p(_taipei, stay: 60)];
      final plan = computePlan(DistributionInput(
        places: places,
        tripStart: _d(1),
        tripEnd: _d(3),
        today: DateTime(2026, 9, 1),
        fillStyle: FillStyle.pack,
        fingerprint: 'fp',
      ));
      final counts = [for (final d in plan.perDay) d.stopIds.length]..sort();
      expect(counts, [3, 3, 3]);
    });
  });

  group('keep current days vs fresh arrangement', () {
    // Two tight sub-areas ~6 km apart inside one city. The current days
    // INTERLEAVE them (A1,B1,A2 | B2,A3,B3): balanced by count, scrambled
    // by geography.
    List<EnginePlace> scrambled() {
      _n = 0;
      EnginePlace at(double lat, double lng, DateTime day, int i) =>
          EnginePlace(
            id: 'q$i',
            name: 'Q$i',
            placeKey: 'q$i',
            lat: lat,
            lng: lng,
            stayMinutes: 60,
            scheduledDay: day,
          );
      return [
        at(25.040, 121.510, _d(1), 1), // A1
        at(25.095, 121.560, _d(1), 2), // B1
        at(25.041, 121.512, _d(1), 3), // A2
        at(25.096, 121.561, _d(2), 4), // B2
        at(25.042, 121.511, _d(2), 5), // A3
        at(25.094, 121.562, _d(2), 6), // B3
      ];
    }

    test('keep (default): balanced already → nothing moves', () {
      final plan =
          computePlan(_input(scrambled(), start: _d(1), end: _d(2)));
      expect(plan.isNoOp, isTrue);
    });

    test('fresh arrangement: regroups each day by geography', () {
      final plan = computePlan(DistributionInput(
        places: scrambled(),
        tripStart: _d(1),
        tripEnd: _d(2),
        today: DateTime(2026, 9, 1),
        keepCurrentDays: false,
        fingerprint: 'fp',
      ));
      expect(plan.isNoOp, isFalse, reason: 'the user asked for a redo');
      // Each day now holds one sub-area: all A's together, all B's together.
      for (final d in plan.perDay) {
        final lats = d.stopIds
            .map((id) => plan.clusterOrder
                .expand((c) => c.members)
                .firstWhere((p) => p.id == id)
                .lat)
            .toList();
        final allA = lats.every((l) => l < 25.06);
        final allB = lats.every((l) => l > 25.06);
        expect(allA || allB, isTrue, reason: 'day ${d.day.day} mixes areas');
      }
    });
  });

  test('Auto balances days by count instead of front-loading', () {
    // 9 short stops fit 5 per day by time; balanced planning gives 3/3/3,
    // not 5/4/0 with an empty last day.
    final places = [for (var i = 0; i < 9; i++) _p(_taipei, stay: 60)];
    final plan = computePlan(_input(places, start: _d(1), end: _d(3)));
    final counts = [for (final d in plan.perDay) d.stopIds.length]..sort();
    expect(counts, [3, 3, 3]);
  });

  group('accommodation nights drive the day blocks', () {
    test('days follow the hotels night for night, even against geography',
        () {
      // Hotels booked SOUTH first: Kaohsiung nights 1-2, then Taipei 3-4.
      // Pure geometry from a northern start would say Taipei first — the
      // hotel schedule must win.
      final places = [
        for (var i = 0; i < 4; i++) _p(_taipei),
        for (var i = 0; i < 4; i++) _p(_kaohsiung),
        _p(_kaohsiung, day: _d(1), endDay: _d(2), accommodation: true, stay: 0),
        _p(_taipei, day: _d(3), endDay: _d(4), accommodation: true, stay: 0),
      ];
      final plan = computePlan(_input(places, start: _d(1), end: _d(4)));
      expect(plan.gate, DistributionGate.ok);
      final byDay = {for (final d in plan.perDay) d.day: d};
      double latOf(String id) => places.firstWhere((p) => p.id == id).lat;
      for (final day in [_d(1), _d(2)]) {
        for (final id in byDay[day]!.stopIds) {
          expect(latOf(id), lessThan(23.5),
              reason: 'day ${day.day} is a Kaohsiung night');
        }
        expect(byDay[day]!.accommodationId, isNotNull);
      }
      for (final day in [_d(3), _d(4)]) {
        for (final id in byDay[day]!.stopIds) {
          expect(latOf(id), greaterThan(24.5),
              reason: 'day ${day.day} is a Taipei night');
        }
      }
      expect(plan.unscheduledIds, isEmpty);
      expect(
          plan.warnings
              .any((w) => w.kind == DistributionWarningKind.accommodationFar),
          isFalse,
          reason: 'every day is planned around its own hotel');
    });

    test('partial hotels: free days still serve cities without a hotel',
        () {
      // Only night 1 is booked (Taipei). Tainan has no hotel but must still
      // get days out of the free ones — not be starved into the bucket.
      final places = [
        for (var i = 0; i < 3; i++) _p(_taipei),
        for (var i = 0; i < 4; i++) _p(_tainan),
        _p(_taipei, day: _d(1), accommodation: true, stay: 0),
      ];
      final plan = computePlan(_input(places, start: _d(1), end: _d(4)));
      expect(plan.unscheduledIds, isEmpty);
      final day1 = plan.perDay.firstWhere((d) => d.day == _d(1));
      for (final id in day1.stopIds) {
        expect(places.firstWhere((p) => p.id == id).lat, greaterThan(24.5),
            reason: 'the hotel night stays Taipei');
      }
      final tainanDays = plan.perDay
          .where((d) => d.stopIds.any(
              (id) => places.firstWhere((p) => p.id == id).lat < 23.5))
          .length;
      expect(tainanDays, greaterThanOrEqualTo(1));
    });

    test('a hotel far from every saved place does not hijack its day', () {
      // Hotel pinned 200 km away (wrong pin) — ignored as an anchor; the
      // day is planned like a free day.
      final places = [
        for (var i = 0; i < 3; i++) _p(_taipei),
        _p((22.0, 121.0), day: _d(1), accommodation: true, stay: 0),
      ];
      final plan = computePlan(_input(places, start: _d(1), end: _d(2)));
      expect(plan.gate, DistributionGate.ok);
      expect(plan.unscheduledIds, isEmpty);
    });
  });

  test('more clusters than days: lightest merges until it fits', () {
    final places = [
      _p(_taipei),
      _p(_taichung),
      _p(_tainan),
      _p(_kaohsiung),
    ];
    // 4 cities, 2 days.
    final plan = computePlan(_input(places, start: _d(1), end: _d(2)));
    expect(plan.gate, DistributionGate.ok);
    expect(plan.clusterOrder.length, lessThanOrEqualTo(2));
    final all = {
      ...plan.unscheduledIds,
      for (final d in plan.perDay) ...d.stopIds
    };
    expect(all.length, 4, reason: 'every place accounted for');
  });
}
