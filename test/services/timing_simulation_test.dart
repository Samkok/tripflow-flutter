import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/saved_location.dart' show OpeningPeriod;
import 'package:voyza/services/timing_simulation.dart';

/// 2026-05-06 is a Wednesday. Anchoring tests to a known weekday makes the
/// Google-day translation (0=Sun..6=Sat) intent obvious in the assertions.
final _wedNoon = DateTime(2026, 5, 6, 12, 0);
const _wedGoogleDay = 3;

LocationModel _stop({
  required String id,
  Duration stay = const Duration(minutes: 30),
  List<OpeningPeriod>? hours,
  int? override,
}) =>
    LocationModel(
      id: id,
      name: id,
      address: '',
      coordinates: const LatLng(0, 0),
      addedAt: DateTime(2026, 1, 1),
      stayDuration: stay,
      googleOpeningHours: hours,
      userClosingMinuteOverride: override,
    );

OpeningPeriod _period(int day, int openMin, int closeDay, int closeMin) =>
    OpeningPeriod(
      openDay: day,
      openMinutes: openMin,
      closeDay: closeDay,
      closeMinutes: closeMin,
    );

Map<String, dynamic> _leg(Duration travel) => {'duration': travel};

void main() {
  group('simulateTrip — empty / single', () {
    test('empty stops returns empty result', () {
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: const [],
        legDetails: const [],
      );
      expect(r.stops, isEmpty);
      expect(r.fullyFeasible, isTrue);
    });

    test('single stop: arrival = startWallTime, no leg consulted', () {
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [_stop(id: 'a')],
        legDetails: const [],
      );
      expect(r.stops, hasLength(1));
      expect(r.stops.first.arrival, _wedNoon);
      expect(r.stops.first.departure,
          _wedNoon.add(const Duration(minutes: 30)));
      expect(r.stops.first.warnings, isEmpty);
    });
  });

  group('simulateTrip — chain of stops', () {
    test('arrival = previous departure + travel', () {
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [
          _stop(id: 'a', stay: const Duration(minutes: 60)),
          _stop(id: 'b', stay: const Duration(minutes: 45)),
          _stop(id: 'c'),
        ],
        legDetails: [
          _leg(const Duration(minutes: 15)),
          _leg(const Duration(minutes: 20)),
        ],
      );
      expect(r.stops[0].arrival, _wedNoon);
      expect(r.stops[0].departure,
          _wedNoon.add(const Duration(minutes: 60)));
      // 12:00 + 60m stay + 15m travel = 13:15
      expect(
        r.stops[1].arrival,
        _wedNoon.add(const Duration(minutes: 75)),
      );
      // 13:15 + 45m + 20m = 14:20
      expect(
        r.stops[2].arrival,
        _wedNoon.add(const Duration(minutes: 140)),
      );
    });

    test('missing leg entries are treated as zero travel', () {
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [_stop(id: 'a'), _stop(id: 'b')],
        legDetails: const [], // intentionally empty
      );
      expect(r.stops[1].arrival, r.stops[0].departure);
    });
  });

  group('simulateTrip — hours coverage', () {
    test('no hours data → no warnings (treated as 24/7)', () {
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [_stop(id: 'a')],
        legDetails: const [],
      );
      expect(r.stops.first.warnings, isEmpty);
      expect(r.fullyFeasible, isTrue);
    });

    test('always-open marker → no warnings', () {
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [
          _stop(id: 'a', hours: const [
            OpeningPeriod(openDay: 0, openMinutes: 0)
          ])
        ],
        legDetails: const [],
      );
      expect(r.stops.first.warnings, isEmpty);
    });

    test('open at arrival, stay fits → no warnings', () {
      // Wed 09:00–22:00; arrives 12:00, 30m stay → fine.
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [
          _stop(id: 'a', hours: [
            _period(_wedGoogleDay, 9 * 60, _wedGoogleDay, 22 * 60),
          ])
        ],
        legDetails: const [],
      );
      expect(r.stops.first.warnings, isEmpty);
    });

    test('willOverrunClose: stay extends past closing', () {
      // Wed 09:00–13:00; arrives 12:00 with 90m stay → overrun 30m.
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [
          _stop(id: 'a',
              stay: const Duration(minutes: 90),
              hours: [_period(_wedGoogleDay, 9 * 60, _wedGoogleDay, 13 * 60)])
        ],
        legDetails: const [],
      );
      expect(r.stops.first.warnings, hasLength(1));
      final w = r.stops.first.warnings.first;
      expect(w.kind, WarningKind.willOverrunClose);
      expect(w.overrun, const Duration(minutes: 30));
    });

    test('notOpenYet: arrives before opening today', () {
      // Wed opens at 14:00; arrives 12:00 → wait 2h.
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [
          _stop(id: 'a',
              hours: [_period(_wedGoogleDay, 14 * 60, _wedGoogleDay, 20 * 60)])
        ],
        legDetails: const [],
      );
      final w = r.stops.first.warnings.single;
      expect(w.kind, WarningKind.notOpenYet);
      expect(w.wait, const Duration(hours: 2));
    });

    test('closedOnArrival: arrives after the last close today', () {
      // Wed 08:00–10:00; arrives 12:00 → past last close today.
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [
          _stop(id: 'a',
              hours: [_period(_wedGoogleDay, 8 * 60, _wedGoogleDay, 10 * 60)])
        ],
        legDetails: const [],
      );
      expect(r.stops.first.warnings.single.kind,
          WarningKind.closedOnArrival);
    });

    test('closedAllDay: no period covers this weekday', () {
      // Place open Mon only; planning Wed → closed all day.
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [
          _stop(id: 'a', hours: [_period(1, 9 * 60, 1, 17 * 60)])
        ],
        legDetails: const [],
      );
      expect(r.stops.first.warnings.single.kind,
          WarningKind.closedAllDay);
    });

    test('split hours (lunch break): in first half is fine', () {
      // 09–13, 14–22. Arrives 12:00, 30m stay → in first period, no warning.
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [
          _stop(id: 'a', hours: [
            _period(_wedGoogleDay, 9 * 60, _wedGoogleDay, 13 * 60),
            _period(_wedGoogleDay, 14 * 60, _wedGoogleDay, 22 * 60),
          ])
        ],
        legDetails: const [],
      );
      expect(r.stops.first.warnings, isEmpty);
    });

    test('split hours (lunch break): arrives during the gap → notOpenYet',
        () {
      // 09–13, 14–22. Arrives 13:30 → not in any → next opens 14:00.
      final r = simulateTrip(
        startWallTime: DateTime(2026, 5, 6, 13, 30),
        orderedStops: [
          _stop(id: 'a', hours: [
            _period(_wedGoogleDay, 9 * 60, _wedGoogleDay, 13 * 60),
            _period(_wedGoogleDay, 14 * 60, _wedGoogleDay, 22 * 60),
          ])
        ],
        legDetails: const [],
      );
      final w = r.stops.first.warnings.single;
      expect(w.kind, WarningKind.notOpenYet);
      expect(w.wait, const Duration(minutes: 30));
    });

    test('after-midnight close: bar opens Sat 18:00, closes Sun 02:00, '
        'arrives Sun 01:00 → still inside the previous-day period', () {
      // Sun 01:00 = inside Sat 18:00 → Sun 02:00 period.
      final sun0100 = DateTime(2026, 5, 10, 1, 0); // 2026-05-10 is a Sunday
      final r = simulateTrip(
        startWallTime: sun0100,
        orderedStops: [
          _stop(id: 'a', hours: [
            // openDay=6 (Sat), closeDay=0 (Sun)
            _period(6, 18 * 60, 0, 2 * 60),
          ])
        ],
        legDetails: const [],
      );
      expect(r.stops.first.warnings, isEmpty);
    });
  });

  group('simulateTrip — user override', () {
    test('override beats Google: in window → no warning', () {
      // Google says 09–22; user overrides close at 21:00. Arrives 20:00,
      // 30m stay → ends 20:30 → fits.
      final r = simulateTrip(
        startWallTime: DateTime(2026, 5, 6, 20, 0),
        orderedStops: [
          _stop(id: 'a',
              stay: const Duration(minutes: 30),
              override: 21 * 60,
              hours: [_period(_wedGoogleDay, 9 * 60, _wedGoogleDay, 22 * 60)])
        ],
        legDetails: const [],
      );
      expect(r.stops.first.warnings, isEmpty);
    });

    test('override tighter than Google: stay overruns the override', () {
      // Google says 09–22; user overrides 21:00. Arrives 20:00 with 90m stay
      // → ends 21:30 → overrun 30m vs the override.
      final r = simulateTrip(
        startWallTime: DateTime(2026, 5, 6, 20, 0),
        orderedStops: [
          _stop(id: 'a',
              stay: const Duration(minutes: 90),
              override: 21 * 60,
              hours: [_period(_wedGoogleDay, 9 * 60, _wedGoogleDay, 22 * 60)])
        ],
        legDetails: const [],
      );
      final w = r.stops.first.warnings.single;
      expect(w.kind, WarningKind.willOverrunClose);
      expect(w.overrun, const Duration(minutes: 30));
    });

    test('override-only (no Google data): after override → closedOnArrival',
        () {
      // No Google hours; override at 22:00. Arrives 23:00 → closed.
      final r = simulateTrip(
        startWallTime: DateTime(2026, 5, 6, 23, 0),
        orderedStops: [_stop(id: 'a', override: 22 * 60)],
        legDetails: const [],
      );
      expect(r.stops.first.warnings.single.kind,
          WarningKind.closedOnArrival);
    });

    test('override-only: before override → no warning', () {
      // Override 22:00; arrives 12:00 → fine.
      final r = simulateTrip(
        startWallTime: _wedNoon,
        orderedStops: [_stop(id: 'a', override: 22 * 60)],
        legDetails: const [],
      );
      expect(r.stops.first.warnings, isEmpty);
    });
  });
}
