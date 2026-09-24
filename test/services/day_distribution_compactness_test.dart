import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/services/day_distribution/day_distribution_engine.dart';
import 'package:voyza/services/day_distribution/distribution_models.dart';

/// Within one city, every planned day must be a compact neighbourhood —
/// places that are near each other, near that day's fixed stops, and near
/// the hotel that owns the day — never "whatever was left".
///
/// Coordinates: around (25.04, 121.51); 0.01° lng ≈ 1.0 km, 0.01° lat ≈
/// 1.1 km at this latitude.
void main() {
  const lat0 = 25.04;
  const lng0 = 121.51;
  DateTime d(int day) => DateTime(2026, 9, day); // 2026-09-01 is a Tuesday

  EnginePlace at(
    String id,
    double dxKm,
    double dyKm, {
    DateTime? day,
    DateTime? endDay,
    bool done = false,
    bool accommodation = false,
    Set<int>? open,
    int stay = 90,
  }) =>
      EnginePlace(
        id: id,
        name: id,
        placeKey: id,
        lat: lat0 + dyKm / 111.0,
        lng: lng0 + dxKm / 100.6,
        stayMinutes: stay,
        scheduledDay: day,
        scheduledEndDay: endDay,
        isDone: done,
        isAccommodation: accommodation,
        openWeekdays: open,
      );

  DistributionInput input(List<EnginePlace> places,
          {required int days, bool keep = true}) =>
      DistributionInput(
        places: places,
        tripStart: d(1),
        tripEnd: d(days),
        today: d(1),
        keepCurrentDays: keep,
        fingerprint: 'fp',
      );

  Map<DateTime, Set<String>> byDay(DistributionPlan plan) =>
      {for (final p in plan.perDay) p.day: p.stopIds.toSet()};

  test('a day is a neighbourhood, not the leftovers of earlier days', () {
    // Nine places on an east-west line, 1.2 km apart, hotel in the middle,
    // three days. A greedy walk from the hotel gives {x5,x4,x3}, {x6,x7,x8}
    // and then {x1,x2,x9} — a last day spanning the whole city. Each day
    // must be three CONSECUTIVE places.
    final places = [
      for (var i = 1; i <= 9; i++) at('x$i', (i - 5) * 1.2, 0),
      at('hotel', 0, 0.3,
          day: d(1), endDay: d(3), accommodation: true, stay: 0),
    ];
    final plan = computePlan(input(places, days: 3));
    expect(plan.gate, DistributionGate.ok);
    expect(plan.unscheduledIds, isEmpty);
    for (final entry in byDay(plan).entries) {
      final xs = entry.value.map((id) => int.parse(id.substring(1))).toList()
        ..sort();
      expect(xs.length, 3, reason: '${entry.key}: $xs');
      expect(xs.last - xs.first, 2,
          reason: '${entry.key} holds $xs — not a contiguous stretch');
    }
  });

  test('a grid of places splits into compact areas', () {
    // 3 columns × 4 rows, 1.5 km apart, no hotel, three days. Ideal: one
    // column per day — total distance from each stop to its day's centroid
    // is 18 km. Interleaved days score far higher.
    final places = [
      for (var c = 0; c < 3; c++)
        for (var r = 0; r < 4; r++) at('g$c$r', c * 1.5, r * 1.5),
    ];
    final plan = computePlan(input(places, days: 3));
    expect(plan.unscheduledIds, isEmpty);
    var totalKm = 0.0;
    for (final day in plan.perDay) {
      final pts = [
        for (final id in day.stopIds) places.firstWhere((p) => p.id == id),
      ];
      expect(pts.length, 4);
      final cLat = pts.map((p) => p.lat).reduce((a, b) => a + b) / pts.length;
      final cLng = pts.map((p) => p.lng).reduce((a, b) => a + b) / pts.length;
      for (final p in pts) {
        final dy = (p.lat - cLat) * 111.0;
        final dx = (p.lng - cLng) * 100.6;
        totalKm += (dx * dx + dy * dy) == 0 ? 0 : _sqrt(dx * dx + dy * dy);
      }
    }
    expect(totalKm, lessThan(20), reason: 'days are not compact');
  });

  test('a closed day is avoided when another day of the city is open', () {
    // Tue–Wed trip. One place is closed on Tuesday (open Wed = weekday 3
    // only); the other five are open every day. It must land on Wednesday
    // without a closed-on-day warning.
    final places = [
      for (var i = 0; i < 5; i++) at('o$i', i * 0.8, (i % 2) * 0.8),
      at('wedOnly', 1.6, 0.4, open: {3}),
    ];
    final plan = computePlan(input(places, days: 2));
    expect(plan.unscheduledIds, isEmpty);
    final wed = byDay(plan)[d(2)]!;
    expect(wed, contains('wedOnly'));
    expect(
        plan.warnings.any((w) =>
            w.kind == DistributionWarningKind.closedOnDay &&
            w.placeId == 'wedOnly'),
        isFalse);
  });

  test('a fixed stop pulls its neighbours onto its day', () {
    // A museum already DONE on day 2 sits in the east. Fresh plan of four
    // west places and four east places over two days: the east ones join
    // the museum's day, the west ones take the other.
    final places = [
      at('museum', 6.0, 0, day: d(2), done: true),
      for (var i = 0; i < 4; i++) at('w$i', i * 0.5, (i % 2) * 0.5),
      for (var i = 0; i < 4; i++) at('e$i', 6.0 + i * 0.5, (i % 2) * 0.5),
    ];
    final plan = computePlan(input(places, days: 2, keep: false));
    expect(plan.unscheduledIds, isEmpty);
    final days = byDay(plan);
    expect(days[d(2)], {'e0', 'e1', 'e2', 'e3'});
    expect(days[d(1)], {'w0', 'w1', 'w2', 'w3'});
  });

  test('two hotels in one city split its days by hotel', () {
    // Nights 1–2 at a western hotel, nights 3–4 at an eastern one, 9 km
    // apart — same city cluster. Places near each hotel belong to that
    // hotel's days.
    final places = [
      at('hotelW', 0, 0, day: d(1), endDay: d(2), accommodation: true, stay: 0),
      at('hotelE', 9, 0, day: d(3), endDay: d(4), accommodation: true, stay: 0),
      for (var i = 0; i < 4; i++) at('w$i', i * 0.6, (i % 2) * 0.6),
      for (var i = 0; i < 4; i++) at('e$i', 9 + i * 0.6, (i % 2) * 0.6),
    ];
    final plan = computePlan(input(places, days: 4));
    expect(plan.unscheduledIds, isEmpty);
    final days = byDay(plan);
    for (final day in [d(1), d(2)]) {
      for (final id in days[day]!) {
        expect(id, startsWith('w'), reason: 'day ${day.day} is a west night');
      }
    }
    for (final day in [d(3), d(4)]) {
      for (final id in days[day]!) {
        expect(id, startsWith('e'), reason: 'day ${day.day} is an east night');
      }
    }
  });

  test('ongoing trip: places on days already lived play no part', () {
    // Trip Sep 1–6, today is Sep 4. Days 1–3 were spent in Kaohsiung (far
    // south, all visited); four Taipei places remain for days 4–6. The past
    // places must not form a city that claims one of the remaining days,
    // shift any centre, or anchor the tour — they are simply not planned.
    // A stay spanning Sep 2–5 is still pinned for Sep 4 and 5.
    const kaohsiung = (22.63, 120.30);
    final places = [
      for (var i = 0; i < 5; i++)
        EnginePlace(
          id: 'past$i',
          name: 'past$i',
          placeKey: 'past$i',
          lat: kaohsiung.$1 + i * 0.004,
          lng: kaohsiung.$2 + i * 0.004,
          stayMinutes: 90,
          scheduledDay: d(1 + i % 3),
          isDone: i.isEven,
        ),
      at('stay', 0.5, 0.5, day: d(2), endDay: d(5), stay: 120),
      for (var i = 0; i < 4; i++) at('t$i', i * 0.8, (i % 2) * 0.8),
    ];
    final plan = computePlan(DistributionInput(
      places: places,
      tripStart: d(1),
      tripEnd: d(6),
      today: d(4),
      fingerprint: 'fp',
    ));
    expect(plan.gate, DistributionGate.ok);
    expect(plan.unscheduledIds, isEmpty);
    // Only Taipei survives as a city; no remaining day is given to the past.
    expect(plan.clusterOrder.length, 1);
    expect(plan.clusterOrder.single.centroidLat, greaterThan(24.5));
    expect(plan.perDay.map((p) => p.day), [d(4), d(5), d(6)]);
    expect(plan.perDay.every((p) => p.stopIds.isNotEmpty), isTrue,
        reason: 'no remaining day may be left to a city that is all past');
    expect(plan.changes.every((c) => c.id.startsWith('t')), isTrue,
        reason: 'past places are never touched');
    // The multi-day stay still occupies the days it has left.
    final byDate = {for (final p in plan.perDay) p.day: p};
    expect(byDate[d(4)]!.usedMinutes, greaterThanOrEqualTo(120));
    expect(byDate[d(5)]!.usedMinutes, greaterThanOrEqualTo(120));
  });

  group('days without a hotel', () {
    const kaohsiung = (22.63, 120.30);
    EnginePlace far(String id, int i,
            {DateTime? day, DateTime? endDay, bool done = false}) =>
        EnginePlace(
          id: id,
          name: id,
          placeKey: id,
          lat: kaohsiung.$1 + (i % 4) * 0.008,
          lng: kaohsiung.$2 + (i ~/ 4) * 0.008,
          stayMinutes: 90,
          scheduledDay: day,
          scheduledEndDay: endDay,
          isDone: done,
        );
    EnginePlace hotel(String id, (double, double) at, int from, int to) =>
        EnginePlace(
          id: id,
          name: id,
          placeKey: id,
          lat: at.$1,
          lng: at.$2,
          stayMinutes: 0,
          scheduledDay: d(from),
          scheduledEndDay: d(to),
          isAccommodation: true,
        );
    double latOf(List<EnginePlace> places, String id) =>
        places.firstWhere((p) => p.id == id).lat;

    test('follow the timeline: stay where you wake up, then move on', () {
      // Taipei hotel nights 1–2, Kaohsiung nights 3–4, no hotel on days 5
      // and 6. Both cities have three days of places, so each is owed one
      // free day. Day 5 must stay in Kaohsiung — that is where the
      // traveller is — and day 6 goes back north; not Taipei on day 5 and
      // Kaohsiung on day 6 (two needless 300 km hops).
      final places = [
        for (var i = 0; i < 12; i++) at('t$i', (i % 4) * 0.9, (i ~/ 4) * 0.9),
        for (var i = 0; i < 12; i++) far('k$i', i),
        hotel('hT', (lat0, lng0), 1, 2),
        hotel('hK', kaohsiung, 3, 4),
      ];
      final plan = computePlan(input(places, days: 6));
      expect(plan.unscheduledIds, isEmpty);
      final days = byDay(plan);
      for (final id in days[d(5)]!) {
        expect(latOf(places, id), lessThan(23.5),
            reason: 'day 5 should stay in Kaohsiung');
      }
      for (final id in days[d(6)]!) {
        expect(latOf(places, id), greaterThan(24.5),
            reason: 'day 6 is the way back to Taipei');
      }
    });

    test('a free day holding a fixed stop belongs to that stop\'s city', () {
      // Taipei hotel nights 1–2; a Kaohsiung stop already DONE on day 3.
      // Kaohsiung's remaining places must land on day 3 (the fixed stop
      // cannot move), not on another free day with a mismatch warning.
      final places = [
        for (var i = 0; i < 4; i++) at('t$i', i * 0.8, (i % 2) * 0.8),
        far('kDone', 0, day: d(3), done: true),
        for (var i = 1; i < 4; i++) far('k$i', i),
        hotel('hT', (lat0, lng0), 1, 2),
      ];
      final plan = computePlan(input(places, days: 5));
      expect(plan.unscheduledIds, isEmpty);
      final day3 = byDay(plan)[d(3)]!;
      expect(day3, isNotEmpty);
      for (final id in day3) {
        expect(latOf(places, id), lessThan(23.5),
            reason: 'day 3 belongs to the done Kaohsiung stop');
      }
      expect(
          plan.warnings
              .any((w) => w.kind == DistributionWarningKind.pinnedMismatch),
          isFalse);
    });
  });

  test('stops within a day are in a sensible visiting order from the hotel',
      () {
    // Hotel at the west end, five places east of it in a line: the proposed
    // order must walk east, not zig-zag.
    final places = [
      at('hotel', 0, 0, day: d(1), accommodation: true, stay: 0),
      for (var i = 1; i <= 5; i++) at('s$i', i * 1.0, 0),
    ];
    final plan = computePlan(input(places, days: 1));
    expect(plan.perDay.single.stopIds, ['s1', 's2', 's3', 's4', 's5']);
  });
}

double _sqrt(double v) {
  // Newton's method is enough here and keeps dart:math out of the test.
  var x = v;
  for (var i = 0; i < 30; i++) {
    x = (x + v / x) / 2;
  }
  return x;
}
