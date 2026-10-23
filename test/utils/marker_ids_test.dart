import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/marker_ids.dart';
import 'package:voyza/utils/transit_line_style.dart';

void main() {
  test('a marker id follows its bitmap, and the base id comes back out', () {
    final a = Object();
    final b = Object();
    final idA = versionedMarkerId('loc-1', a);
    expect(versionedMarkerId('loc-1', a), idA); // same bitmap, same marker
    expect(versionedMarkerId('loc-1', b), isNot(idA)); // new bitmap, new one
    expect(baseMarkerId(idA), 'loc-1');
    expect(baseMarkerId('current_location'), 'current_location');
    expect(baseMarkerId(versionedMarkerId('place_callout_x', a)),
        'place_callout_x');
  });

  group('transitScheduleLine', () {
    String hhmm(DateTime t) =>
        '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    final now = DateTime(2026, 10, 17, 11, 47);

    test('departure ahead: time, countdown and headway', () {
      final line = transitScheduleLine(
        departureTime: DateTime(2026, 10, 17, 11, 55).toIso8601String(),
        headwaySeconds: 600,
        now: now,
        formatTime: hhmm,
      );
      expect(line, 'Departs 11:55 · in 8 min · every 10 min');
    });

    test('a departure already gone keeps the time, drops the countdown', () {
      final line = transitScheduleLine(
        departureTime: DateTime(2026, 10, 17, 11, 30).toIso8601String(),
        headwaySeconds: 90,
        now: now,
        formatTime: hhmm,
      );
      expect(line, 'Departs 11:30 · every 2 min');
    });

    test('hours away, and nothing at all', () {
      expect(
          transitScheduleLine(
            departureTime: DateTime(2026, 10, 17, 14, 2).toIso8601String(),
            headwaySeconds: null,
            now: now,
            formatTime: hhmm,
          ),
          'Departs 14:02 · in 2h 15m');
      expect(
          transitScheduleLine(
              departureTime: null,
              headwaySeconds: null,
              now: now,
              formatTime: hhmm),
          isNull);
    });
  });
}
