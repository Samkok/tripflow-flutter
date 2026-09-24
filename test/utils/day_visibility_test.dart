import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/day_visibility.dart';

void main() {
  final d1 = DateTime(2026, 10, 5);
  final d2 = DateTime(2026, 10, 6);
  final d3 = DateTime(2026, 10, 7);
  final days = [d1, d2, d3];

  group('effectiveHiddenDays', () {
    test('nothing hidden stays nothing', () {
      expect(effectiveHiddenDays({}, days), isEmpty);
    });

    test('a partial set applies as is', () {
      expect(effectiveHiddenDays({d2}, days), {d2});
    });

    test('a set that would blank the map applies as nothing', () {
      // The only visible day left the trip: its stale key must not leave
      // an empty map.
      expect(effectiveHiddenDays({d1, d2}, [d1, d2]), isEmpty);
      expect(effectiveHiddenDays({d1, d2, d3}, days), isEmpty);
    });

    test('a day added later is visible by default', () {
      final d4 = DateTime(2026, 10, 8);
      final hidden = effectiveHiddenDays({d1, d2, d3}, [...days, d4]);
      expect(hidden, {d1, d2, d3});
      expect(hidden.contains(d4), isFalse);
    });
  });

  group('toggleDayVisibility', () {
    test('tap hides a visible day', () {
      expect(toggleDayVisibility({}, d2, days), {d2});
    });

    test('tap shows a hidden day', () {
      expect(toggleDayVisibility({d2, d3}, d3, days), {d2});
    });

    test('tapping the last visible day shows all days', () {
      expect(toggleDayVisibility({d2, d3}, d1, days), isEmpty);
    });

    test('a single-day trip can never be hidden', () {
      expect(toggleDayVisibility({}, d1, [d1]), isEmpty);
    });

    test('does not mutate the previous set', () {
      final before = {d2};
      toggleDayVisibility(before, d3, days);
      toggleDayVisibility(before, d2, days);
      expect(before, {d2});
    });
  });

  group('soloDayVisibility', () {
    test('hold shows only that day', () {
      expect(soloDayVisibility({}, d2, days), {d1, d3});
    });

    test('hold on a hidden day shows only that day', () {
      expect(soloDayVisibility({d2}, d2, days), {d1, d3});
    });

    test('hold on the day already shown alone restores all days', () {
      expect(soloDayVisibility({d1, d3}, d2, days), isEmpty);
    });
  });
}
