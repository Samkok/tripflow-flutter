import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/saved_location.dart' show OpeningPeriod;
import 'package:voyza/services/day_distribution/day_distribution_engine.dart';
import 'package:voyza/services/day_distribution/day_window.dart';
import 'package:voyza/services/day_distribution/distribution_constants.dart';
import 'package:voyza/services/day_distribution/distribution_models.dart';
import 'package:voyza/services/day_distribution/model_bridge.dart';

const _taipei = (25.04, 121.51);
const _kaohsiung = (22.63, 120.30);

/// Open [open]–[close] every day of the week (minutes after midnight; a
/// close past 1440 is after midnight).
List<OpenSpan> _daily(int open, int close) => [
      for (var d = 0; d < 7; d++) OpenSpan(d * 1440 + open, d * 1440 + close),
    ];

int _hm(int h, [int m = 0]) => h * 60 + m;

int _n = 0;
EnginePlace _p(
  (double, double) around, {
  DateTime? day,
  DateTime? endDay,
  int stay = 90,
  bool done = false,
  bool accommodation = false,
  Set<int>? open,
  List<OpenSpan>? hours,
  double north = 0,
  bool jitter = true,
}) {
  final i = _n++;
  return EnginePlace(
    id: 'p${i.toString().padLeft(3, '0')}',
    name: 'Place $i',
    placeKey: 'k$i',
    lat: around.$1 + north + (jitter ? (i % 5) * 0.004 : 0),
    lng: around.$2 + (jitter ? (i % 7) * 0.004 : 0),
    stayMinutes: stay,
    scheduledDay: day,
    scheduledEndDay: endDay,
    isDone: done,
    isAccommodation: accommodation,
    openWeekdays: open,
    openSpans: hours,
  );
}

DateTime _d(int day) => DateTime(2026, 9, day);

DistributionPlan _plan(
  List<EnginePlace> places, {
  required int days,
  int? arrival,
  int? departure,
  int? cap,
  FillStyle fill = FillStyle.balanced,
  bool keep = true,
  bool weekdaysKnown = true,
  DateTime? start,
  DateTime? today,
}) {
  final s = start ?? _d(1);
  return computePlan(DistributionInput(
    places: places,
    tripStart: s,
    tripEnd: DateTime(s.year, s.month, s.day + days - 1),
    today: today ?? DateTime(2026, 8, 20),
    maxStopsPerDay: cap,
    fillStyle: fill,
    keepCurrentDays: keep,
    arrivalMinute: arrival,
    departureMinute: departure,
    weekdaysKnown: weekdaysKnown,
    fingerprint: 'fp',
  ));
}

PlannedDay _day(DistributionPlan plan, DateTime day) =>
    plan.perDay.firstWhere((d) => d.day == day);

void main() {
  setUp(() => _n = 0);

  group('what the times leave of a day', () {
    DayWindow? first(int arrival) => dayWindowFor(
        isFirstDay: true, isLastDay: false, arrivalMinute: arrival);
    DayWindow? last(int departure) => dayWindowFor(
        isFirstDay: false, isLastDay: true, departureMinute: departure);

    test('a day in the middle of the trip is never shortened', () {
      expect(
        dayWindowFor(
          isFirstDay: false,
          isLastDay: false,
          arrivalMinute: _hm(22),
          departureMinute: _hm(6),
        ),
        isNull,
      );
    });

    test('no times, no window', () {
      expect(dayWindowFor(isFirstDay: true, isLastDay: true), isNull);
    });

    test('an early arrival leaves the whole first day', () {
      expect(first(_hm(6)), isNull);
      // 08:00 + the hour to get into town = 09:00, when a day starts anyway.
      expect(first(_hm(8)), isNull);
      expect(first(_hm(8, 1)), isNotNull);
    });

    test('an afternoon arrival: visits start an hour later', () {
      final w = first(_hm(15))!;
      expect(w.start, _hm(16));
      expect(w.startsLate, isTrue);
      expect(w.endsEarly, isFalse);
      // 16:00 → 21:00 is five hours; the same share of it as of any day
      // goes to visits (510 of 570 minutes).
      expect(w.budget, (300 * 510 / 570).round());
      expect(w.usable, isTrue);
      // The evening itself is not cut: a night market may run late.
      expect(w.end, 24 * 60);
    });

    test('a late-morning arrival still makes a full day of visits', () {
      expect(first(_hm(10))!.budget, kDayBudgetMinutes);
    });

    test('arriving in the evening leaves nothing to plan', () {
      expect(first(_hm(19))!.usable, isTrue, reason: 'one short stop');
      expect(first(_hm(19, 30))!.usable, isFalse);
      expect(first(_hm(23, 30))!.budget, 0);
    });

    test('a departure ends the last day three hours earlier', () {
      final w = last(_hm(14))!;
      expect(w.start, kDayStartMinute);
      expect(w.end, _hm(11));
      expect(w.endsEarly, isTrue);
      expect(w.startsLate, isFalse);
      expect(w.budget, (120 * 510 / 570).round());
    });

    test('leaving in the morning leaves nothing to plan', () {
      expect(last(_hm(12))!.budget, 0);
      expect(last(_hm(7))!.usable, isFalse);
      expect(last(_hm(0))!.usable, isFalse);
    });

    test('a late-night departure keeps the day full but still ends it', () {
      final w = last(_hm(23, 59))!;
      expect(w.budget, kDayBudgetMinutes);
      expect(w.end, _hm(20, 59));
    });

    test('a one-day trip is cut at both ends', () {
      final w = dayWindowFor(
        isFirstDay: true,
        isLastDay: true,
        arrivalMinute: _hm(10),
        departureMinute: _hm(19),
      )!;
      expect(w.start, _hm(11));
      expect(w.end, _hm(16));
      expect(w.startsLate && w.endsEarly, isTrue);
      expect(w.budget, (300 * 510 / 570).round());
    });

    test('out-of-range times are clamped, never trusted', () {
      expect(first(5000)!.budget, 0);
      expect(last(-30)!.budget, 0);
    });
  });

  group('opening hours handed to the planner', () {
    OpeningPeriod period(int openDay, int open, int? closeDay, int? close) =>
        OpeningPeriod(
            openDay: openDay,
            openMinutes: open,
            closeDay: closeDay,
            closeMinutes: close);

    test('nothing to check: no hours, 24/7, or "never closes"', () {
      expect(engineOpenSpans(null), isNull);
      expect(engineOpenSpans(const []), isNull);
      expect(engineOpenSpans([period(0, 0, null, null)]), isNull);
      expect(
        engineOpenSpans([period(1, _hm(9), 1, _hm(17))], closingOverride: 1440),
        isNull,
      );
    });

    test('one span per period, in minutes from Sunday midnight', () {
      final spans = engineOpenSpans([
        period(1, _hm(9), 1, _hm(17)), // Monday
        period(2, _hm(10), 2, _hm(18)), // Tuesday
      ])!;
      expect(spans, hasLength(2));
      expect((spans[0].start, spans[0].end), (1440 + _hm(9), 1440 + _hm(17)));
      expect((spans[1].start, spans[1].end),
          (2 * 1440 + _hm(10), 2 * 1440 + _hm(18)));
    });

    test('a close after midnight runs into the next day', () {
      // Friday 18:00 → Saturday 02:00.
      final friday = engineOpenSpans([period(5, _hm(18), 6, _hm(2))])!.single;
      expect(friday.end - friday.start, 8 * 60);
      // Saturday 22:00 → Sunday 03:00 wraps the week.
      final saturday = engineOpenSpans([period(6, _hm(22), 0, _hm(3))])!.single;
      expect(saturday.start, 6 * 1440 + _hm(22));
      expect(saturday.end, 7 * 1440 + _hm(3));
    });

    test("the traveller's own closing time wins, every day", () {
      final spans = engineOpenSpans(
        [period(1, _hm(9), 1, _hm(17))],
        closingOverride: _hm(15),
      )!;
      expect(spans, hasLength(7));
      // Monday: from Google's opening to the chosen close.
      expect((spans[1].start, spans[1].end), (1440 + _hm(9), 1440 + _hm(15)));
      // A day Google lists nothing for: from midnight.
      expect((spans[3].start, spans[3].end), (3 * 1440, 3 * 1440 + _hm(15)));
    });

    test('a chosen close before the opening means after midnight', () {
      final spans = engineOpenSpans(
        [period(5, _hm(18), 6, _hm(2))],
        closingOverride: _hm(1),
      )!;
      expect((spans[5].start, spans[5].end),
          (5 * 1440 + _hm(18), 6 * 1440 + _hm(1)));
    });

    test('periods with no usable times are no information', () {
      expect(engineOpenSpans([period(1, _hm(9), 1, _hm(9))]), isNull);
    });
  });

  group('the arrival day', () {
    test('takes fewer places, in proportion to the time it has', () {
      final places = [for (var i = 0; i < 12; i++) _p(_taipei)];
      final plan = _plan(places, days: 3, arrival: _hm(15));
      expect(plan.gate, DistributionGate.ok);
      expect(plan.unscheduledIds, isEmpty);
      final first = _day(plan, _d(1));
      expect(first.fromMinute, _hm(16));
      expect(first.untilMinute, isNull);
      expect(first.stopIds.length, 2, reason: 'an evening, not a day');
      expect(_day(plan, _d(2)).stopIds.length, 5);
      expect(_day(plan, _d(3)).stopIds.length, 5);
      expect(_day(plan, _d(2)).fromMinute, isNull);
      expect(first.usedMinutes, lessThanOrEqualTo((300 * 510 / 570).round()));
      expect(plan.shapedByTripTimes, isTrue);
    });

    test('with no times set, every day is a full day', () {
      final places = [for (var i = 0; i < 12; i++) _p(_taipei)];
      final plan = _plan(places, days: 3);
      expect([for (final d in plan.perDay) d.stopIds.length], [4, 4, 4]);
      expect(plan.shapedByTripTimes, isFalse);
      expect(plan.noTimeDays, isEmpty);
    });

    test('never gets a place that closes before the traveller is there', () {
      final museums = [
        for (var i = 0; i < 4; i++)
          _p(_taipei, hours: _daily(_hm(9), _hm(17)), day: _d(1)),
      ];
      final late = [
        for (var i = 0; i < 2; i++)
          _p(_taipei, hours: _daily(_hm(16), _hm(23)), day: _d(2)),
      ];
      // Fresh arrangement, so nothing stays put just because it was there.
      final plan =
          _plan([...museums, ...late], days: 2, arrival: _hm(15), keep: false);
      final first = _day(plan, _d(1));
      final museumIds = {for (final m in museums) m.id};
      expect(first.stopIds.where(museumIds.contains), isEmpty,
          reason: 'they close at 17:00 and visits only start at 16:00');
      expect(first.stopIds.toSet(), {for (final l in late) l.id});
      expect(_day(plan, _d(2)).stopIds.toSet(), museumIds);
      expect(plan.unscheduledIds, isEmpty);
    });

    test('a visit has to END before closing, not just start', () {
      // Open until 17:15: there by 16:00, but a 90-minute visit overruns.
      final tight = _p(_taipei, hours: _daily(_hm(9), _hm(17, 15)), stay: 90);
      // Same hours, a 45-minute visit: fine.
      final quick = _p(_taipei, hours: _daily(_hm(9), _hm(17, 15)), stay: 45);
      final rest = [for (var i = 0; i < 6; i++) _p(_taipei)];
      final plan = _plan([tight, quick, ...rest],
          days: 2, arrival: _hm(15), keep: false);
      expect(_day(plan, _d(1)).stopIds, isNot(contains(tight.id)));
      expect(_day(plan, _d(2)).stopIds, contains(tight.id));
    });

    test('what already sits there and fits stays (keep mode)', () {
      final market =
          _p(_taipei, hours: _daily(_hm(17), _hm(24)), day: _d(1), stay: 60);
      final museum =
          _p(_taipei, hours: _daily(_hm(9), _hm(17)), day: _d(1), stay: 60);
      final rest = [
        for (var i = 0; i < 3; i++) _p(_taipei, day: _d(2)),
        for (var i = 0; i < 3; i++) _p(_taipei, day: _d(3)),
      ];
      final plan = _plan([market, museum, ...rest], days: 3, arrival: _hm(17));
      final moved = {for (final c in plan.changes) c.id: c.newDay};
      expect(moved.containsKey(market.id), isFalse,
          reason: 'open in the evening: it keeps its day');
      expect(moved[museum.id], isNot(_d(1)),
          reason: 'closed by the time the traveller is out: it has to move');
      expect(moved[museum.id], isNotNull);
      expect(_day(plan, _d(1)).stopIds, [market.id]);
    });

    test('the order of the evening follows closing times', () {
      // The hotel is next to B, so nearest-first would visit B then A — and
      // reach A too late. A closes at 18:00, B is open all evening.
      final hotel =
          _p(_taipei, day: _d(1), accommodation: true, stay: 0, jitter: false);
      final b =
          _p(_taipei, hours: _daily(_hm(16), _hm(23)), stay: 60, jitter: false);
      final a = _p(_taipei,
          hours: _daily(_hm(16), _hm(18)),
          stay: 60,
          north: 0.009,
          jitter: false);
      final plan = _plan([hotel, b, a], days: 1, arrival: _hm(15));
      expect(plan.gate, DistributionGate.ok);
      expect(_day(plan, _d(1)).stopIds, [a.id, b.id]);
      expect(plan.unscheduledIds, isEmpty);
    });

    test('is spent near where the day starts, not across town', () {
      final hotel = _p(_taipei,
          day: _d(1),
          endDay: _d(3),
          accommodation: true,
          stay: 0,
          jitter: false);
      // Two spots round the corner from the hotel…
      final near = [
        _p(_taipei, north: 0.003, jitter: false),
        _p(_taipei, north: -0.003, jitter: false),
      ];
      // …and ten on the far side of town (about 9 km north, same city).
      final far = [for (var i = 0; i < 10; i++) _p(_taipei, north: 0.08)];
      final plan = _plan([hotel, ...far, ...near],
          days: 3, arrival: _hm(16), keep: false);
      expect(_day(plan, _d(1)).stopIds.toSet(), {for (final n in near) n.id});
      expect(plan.unscheduledIds, isEmpty);
    });

    test('two places that both close early: only one fits the evening', () {
      final a = _p(_taipei, hours: _daily(_hm(9), _hm(17, 30)), stay: 60);
      final b = _p(_taipei, hours: _daily(_hm(9), _hm(17, 30)), stay: 60);
      final rest = [for (var i = 0; i < 4; i++) _p(_taipei)];
      final plan =
          _plan([a, b, ...rest], days: 2, arrival: _hm(15), keep: false);
      final first = _day(plan, _d(1)).stopIds;
      expect(first.where((id) => id == a.id || id == b.id).length,
          lessThanOrEqualTo(1));
      expect(plan.unscheduledIds, isEmpty);
    });

    test('a whole-day place never lands on it', () {
      final park = _p(_taipei, stay: 420, day: _d(1));
      final rest = [for (var i = 0; i < 6; i++) _p(_taipei)];
      final plan = _plan([park, ...rest], days: 3, arrival: _hm(14));
      expect(_day(plan, _d(1)).stopIds, isNot(contains(park.id)));
      expect(plan.unscheduledIds, isEmpty);
    });

    test('arriving at night: the day takes nothing', () {
      final places = [for (var i = 0; i < 6; i++) _p(_taipei, day: _d(1))];
      final plan = _plan(places, days: 3, arrival: _hm(21));
      expect(plan.gate, DistributionGate.ok);
      expect(plan.noTimeDays, [_d(1)]);
      expect(plan.perDay.map((d) => d.day), [_d(2), _d(3)]);
      expect(plan.freeDays, isEmpty, reason: 'no time is not a free day');
      expect(plan.unscheduledIds, isEmpty);
      expect(plan.changes, hasLength(6), reason: 'everything leaves day 1');
      expect([for (final d in plan.perDay) d.stopIds.length], [3, 3]);
    });

    test('the limit on places a day does not override the clock', () {
      final places = [for (var i = 0; i < 15; i++) _p(_taipei)];
      final plan = _plan(places, days: 3, arrival: _hm(17), cap: 5);
      // 18:00 → 21:00 holds one 90-minute visit, whatever the limit says.
      expect(_day(plan, _d(1)).stopIds.length, 1);
      expect(_day(plan, _d(2)).stopIds.length, 5);
      expect(_day(plan, _d(3)).stopIds.length, 5);
      expect(plan.unscheduledIds, hasLength(4));
    });

    test('fill-up style: the evening fills only as far as it can', () {
      final places = [for (var i = 0; i < 9; i++) _p(_taipei)];
      final plan = _plan(places,
          days: 3, arrival: _hm(15), cap: 6, fill: FillStyle.pack);
      expect(_day(plan, _d(1)).stopIds.length, lessThanOrEqualTo(2));
      expect(plan.unscheduledIds, isEmpty);
      final total = plan.perDay.fold<int>(0, (n, d) => n + d.stopIds.length);
      expect(total, 9);
    });
  });

  group('the departure day', () {
    test('ends in time to leave, and takes fewer places', () {
      final places = [for (var i = 0; i < 12; i++) _p(_taipei)];
      final plan = _plan(places, days: 3, departure: _hm(15));
      final last = _day(plan, _d(3));
      expect(last.untilMinute, _hm(12));
      expect(last.fromMinute, isNull);
      // 09:00 → 12:00.
      expect(last.stopIds.length, lessThanOrEqualTo(2));
      expect(last.stopIds, isNotEmpty);
      expect(plan.unscheduledIds, isEmpty);
      expect(
          _day(plan, _d(1)).stopIds.length, greaterThan(last.stopIds.length));
    });

    test('never gets a place that only opens later in the day', () {
      final markets = [
        for (var i = 0; i < 3; i++)
          _p(_taipei, hours: _daily(_hm(17), _hm(23)), day: _d(2)),
      ];
      final temples = [
        for (var i = 0; i < 3; i++)
          _p(_taipei, hours: _daily(_hm(6), _hm(17)), stay: 45, day: _d(1)),
      ];
      final plan = _plan([...markets, ...temples],
          days: 2, departure: _hm(14), keep: false);
      final last = _day(plan, _d(2)).stopIds;
      expect(last.where({for (final m in markets) m.id}.contains), isEmpty,
          reason: 'they open at 17:00; the day ends at 11:00');
      expect(plan.unscheduledIds, isEmpty);
    });

    test('a visit has to fit before the cut-off', () {
      // Opens 10:00; a 90-minute visit ends 11:30, the day ends at 11:00.
      final late = _p(_taipei, hours: _daily(_hm(10), _hm(18)), stay: 90);
      final rest = [for (var i = 0; i < 5; i++) _p(_taipei, stay: 45)];
      final plan =
          _plan([late, ...rest], days: 2, departure: _hm(14), keep: false);
      expect(_day(plan, _d(2)).stopIds, isNot(contains(late.id)));
      expect(_day(plan, _d(1)).stopIds, contains(late.id));
    });

    test('is spent near where the traveller wakes up', () {
      final hotel = _p(_taipei,
          day: _d(1),
          endDay: _d(3),
          accommodation: true,
          stay: 0,
          jitter: false);
      final near = _p(_taipei, north: 0.003, stay: 60, jitter: false);
      final far = [for (var i = 0; i < 9; i++) _p(_taipei, north: 0.08)];
      final plan = _plan([hotel, ...far, near],
          days: 3, departure: _hm(14), keep: false);
      // 09:00 → 11:00: one visit, and it is the one next door.
      expect(_day(plan, _d(3)).stopIds, [near.id]);
      expect(plan.unscheduledIds, isEmpty);
    });

    test('leaving first thing: the day takes nothing', () {
      final places = [for (var i = 0; i < 6; i++) _p(_taipei, day: _d(3))];
      final plan = _plan(places, days: 3, departure: _hm(10));
      expect(plan.noTimeDays, [_d(3)]);
      expect(plan.perDay.map((d) => d.day), [_d(1), _d(2)]);
      expect(plan.unscheduledIds, isEmpty);
    });

    test('still counts on an ongoing trip, when arrival is in the past', () {
      final places = [for (var i = 0; i < 8; i++) _p(_taipei)];
      final plan = _plan(places,
          days: 4, arrival: _hm(20), departure: _hm(13), today: _d(3));
      // Day 1 is lived: its late arrival no longer matters.
      expect(plan.noTimeDays, isEmpty);
      expect(plan.perDay.map((d) => d.day), [_d(3), _d(4)]);
      expect(_day(plan, _d(4)).untilMinute, _hm(10));
      expect(_day(plan, _d(3)).fromMinute, isNull);
    });
  });

  group('both ends', () {
    test('a one-day trip is planned between arriving and leaving', () {
      final places = [for (var i = 0; i < 6; i++) _p(_taipei, day: _d(1))];
      final plan = _plan(places, days: 1, arrival: _hm(9), departure: _hm(18));
      final day = _day(plan, _d(1));
      expect(day.fromMinute, _hm(10));
      expect(day.untilMinute, _hm(15));
      // Five hours hold two or three visits; the rest is honestly left out.
      expect(day.stopIds.length, inInclusiveRange(2, 3));
      expect(plan.unscheduledIds.length, 6 - day.stopIds.length);
      expect(plan.warnings.map((w) => w.kind),
          contains(DistributionWarningKind.overflow));
    });

    test('no time between arriving and leaving: nothing to plan', () {
      final plan = _plan([_p(_taipei), _p(_taipei)],
          days: 1, arrival: _hm(20), departure: _hm(22));
      expect(plan.gate, DistributionGate.noTimeToPlan);
      expect(plan.noTimeDays, [_d(1)]);
      expect(plan.changes, isEmpty);
    });

    test('a trip of one evening and one morning still gets planned', () {
      final evening = _p(_taipei, hours: _daily(_hm(17), _hm(23)), stay: 60);
      final morning = _p(_taipei, hours: _daily(_hm(6), _hm(12)), stay: 45);
      final plan = _plan([evening, morning],
          days: 2, arrival: _hm(17), departure: _hm(13, 30));
      expect(plan.gate, DistributionGate.ok);
      expect(_day(plan, _d(1)).stopIds, [evening.id]);
      expect(_day(plan, _d(2)).stopIds, [morning.id]);
    });

    test('a short evening and a short morning stay in the city next door', () {
      final places = [
        for (var i = 0; i < 8; i++) _p(_taipei),
        for (var i = 0; i < 8; i++) _p(_kaohsiung),
      ];
      final plan = _plan(places, days: 5, arrival: _hm(18), departure: _hm(13));
      expect(plan.gate, DistributionGate.ok);
      final byDay = {for (final d in plan.perDay) d.day: d};
      expect(byDay[_d(1)]!.clusterIndex, byDay[_d(2)]!.clusterIndex,
          reason: 'no change of city on the arrival evening');
      expect(byDay[_d(5)]!.clusterIndex, byDay[_d(4)]!.clusterIndex,
          reason: 'the last morning is where the traveller woke up');
      expect(byDay[_d(1)]!.hopMinutes, 0);
      expect(byDay[_d(5)]!.hopMinutes, 0);
      // Both cities still get full days.
      expect({for (final d in plan.perDay) d.clusterIndex}, hasLength(2));
      expect(plan.unscheduledIds, isEmpty);
    });

    test('the same input always gives the same plan', () {
      List<EnginePlace> build() {
        _n = 0;
        return [
          for (var i = 0; i < 10; i++)
            _p(_taipei,
                hours: i.isEven ? _daily(_hm(9), _hm(17)) : null,
                stay: 30 + 15 * (i % 4)),
        ];
      }

      final a = _plan(build(), days: 3, arrival: _hm(14), departure: _hm(16));
      final shuffled = build()..shuffle(Random(7));
      final b = _plan(shuffled, days: 3, arrival: _hm(14), departure: _hm(16));
      expect([for (final d in b.perDay) d.stopIds],
          [for (final d in a.perDay) d.stopIds]);
      expect(b.unscheduledIds, a.unscheduledIds);
    });
  });

  group('a trip with no dates yet', () {
    final anchor = DateTime(2100, 1, 1); // a Friday, were it a real date

    test('no weekday is guessed: nothing is "closed on that day"', () {
      // Open Mondays only — the anchor days are Fri/Sat/Sun.
      final places = [
        for (var i = 0; i < 6; i++) _p(_taipei, open: {1}),
      ];
      final known = _plan(places, days: 3, start: anchor);
      expect(known.warnings.map((w) => w.kind),
          contains(DistributionWarningKind.closedOnDay));
      _n = 0;
      final undated = _plan([
        for (var i = 0; i < 6; i++) _p(_taipei, open: {1}),
      ], days: 3, start: anchor, weekdaysKnown: false);
      expect(undated.warnings.map((w) => w.kind),
          isNot(contains(DistributionWarningKind.closedOnDay)));
    });

    test('times still count: hours that rule a place out on EVERY weekday', () {
      final museum = _p(_taipei, hours: _daily(_hm(9), _hm(17)));
      // Open late on Wednesdays only — it might be a Wednesday.
      final maybe = _p(_taipei, hours: [
        for (var d = 0; d < 7; d++)
          OpenSpan(d * 1440 + _hm(9), d * 1440 + (d == 3 ? _hm(22) : _hm(17))),
      ]);
      final rest = [for (var i = 0; i < 6; i++) _p(_taipei)];
      final plan = _plan([museum, maybe, ...rest],
          days: 2,
          start: anchor,
          arrival: _hm(15),
          weekdaysKnown: false,
          keep: false);
      final first = _day(plan, anchor);
      expect(first.fromMinute, _hm(16));
      expect(first.stopIds, isNot(contains(museum.id)));
      expect(plan.unscheduledIds, isEmpty);
    });
  });

  test('random trips: every plan respects the clock', () {
    final rnd = Random(4711);
    const hourSets = <List<int>?>[
      null,
      [9, 17],
      [10, 18],
      [6, 12],
      [16, 23],
      [17, 26],
      [11, 14],
    ];
    for (var iter = 0; iter < 400; iter++) {
      _n = 0;
      final days = 1 + rnd.nextInt(5);
      final places = <EnginePlace>[];
      final hoursOf = <String, List<int>?>{};
      final count = 1 + rnd.nextInt(14);
      for (var i = 0; i < count; i++) {
        final h = hourSets[rnd.nextInt(hourSets.length)];
        final p = _p(
          rnd.nextInt(4) == 0 ? _kaohsiung : _taipei,
          stay: const [0, 30, 45, 60, 90, 120, 300][rnd.nextInt(7)],
          day: rnd.nextBool() ? _d(1 + rnd.nextInt(days)) : null,
          hours: h == null ? null : _daily(h[0] * 60, h[1] * 60),
        );
        places.add(p);
        hoursOf[p.id] = h;
      }
      final arrival = rnd.nextInt(4) == 0 ? null : rnd.nextInt(1440);
      final departure = rnd.nextInt(4) == 0 ? null : rnd.nextInt(1440);
      final cap = rnd.nextInt(3) == 0 ? 1 + rnd.nextInt(6) : null;
      final plan = _plan(
        places,
        days: days,
        arrival: arrival,
        departure: departure,
        cap: cap,
        fill: rnd.nextBool() ? FillStyle.pack : FillStyle.balanced,
        keep: rnd.nextBool(),
        weekdaysKnown: rnd.nextInt(5) != 0,
      );
      final why = 'iteration $iter (arrival $arrival, departure $departure)';
      if (plan.gate == DistributionGate.noTimeToPlan) {
        expect(plan.perDay, isEmpty, reason: why);
        continue;
      }
      expect(plan.gate, DistributionGate.ok, reason: why);

      // Every place is on exactly one day, or left out — never both.
      final seen = <String>{};
      for (final d in plan.perDay) {
        for (final id in d.stopIds) {
          expect(seen.add(id), isTrue, reason: '$why: $id twice');
        }
        if (cap != null) {
          expect(d.stopIds.length, lessThanOrEqualTo(cap), reason: why);
        }
        expect(plan.noTimeDays, isNot(contains(d.day)), reason: why);
      }
      for (final id in plan.unscheduledIds) {
        expect(seen.add(id), isTrue, reason: '$why: $id seated and left out');
      }
      expect(seen, {for (final p in places) p.id}, reason: why);

      // A shortened day's visits, in the order given, each start no sooner
      // than the day does, sit inside the place's hours and end in time —
      // checked here with no travel at all, which can only be kinder.
      final byId = {for (final p in places) p.id: p};
      for (final d in plan.perDay) {
        if (d.fromMinute == null && d.untilMinute == null) continue;
        final w = dayWindowFor(
          isFirstDay: d.day == _d(1),
          isLastDay: d.day == _d(days),
          arrivalMinute: arrival,
          departureMinute: departure,
        )!;
        var t = w.start;
        var stays = 0;
        for (final id in d.stopIds) {
          final p = byId[id]!;
          final stay = p.stayMinutes <= 0 ? kDefaultStayMinutes : p.stayMinutes;
          stays += stay;
          final h = hoursOf[id];
          if (h != null) {
            // Same hours every day here, so yesterday's late close counts
            // as an early-morning opening too.
            final spans = [
              (h[0] * 60, h[1] * 60),
              (h[0] * 60 - 1440, h[1] * 60 - 1440),
            ];
            int? begin;
            for (final (o, c) in spans) {
              final b = max(t, o);
              if (b + stay <= c && (begin == null || b < begin)) begin = b;
            }
            expect(begin, isNotNull,
                reason: '$why: $id cannot be visited on ${d.day} '
                    'from $t within $h');
            t = begin!;
          }
          t += stay;
          expect(t, lessThanOrEqualTo(w.end), reason: '$why: $id ends late');
        }
        expect(stays, lessThanOrEqualTo(w.budget),
            reason: '$why: ${d.day} holds more than its time');
      }
    }
  });
}
