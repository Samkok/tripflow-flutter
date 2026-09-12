import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/rollover_planner.dart';

void main() {
  final today = DateTime(2026, 9, 12);

  group('rolloverFromLabel', () {
    test('every moved stop came from the day before → "yesterday"', () {
      expect(
        rolloverFromLabel(
            [DateTime(2026, 9, 11, 15, 30), DateTime(2026, 9, 11)], today),
        'yesterday',
      );
    });

    test('all from one older day → that day\'s short date', () {
      expect(rolloverFromLabel([DateTime(2026, 9, 9)], today), 'Sep 9');
    });

    test('from several days → "earlier days"', () {
      expect(
        rolloverFromLabel([DateTime(2026, 9, 9), DateTime(2026, 9, 11)], today),
        'earlier days',
      );
    });

    test('no known days → "earlier days"', () {
      expect(rolloverFromLabel(const [], today), 'earlier days');
    });

    test('yesterday across a month boundary', () {
      expect(
        rolloverFromLabel([DateTime(2026, 8, 31)], DateTime(2026, 9, 1)),
        'yesterday',
      );
    });
  });

  group('rolloverMessage', () {
    test('singular', () {
      expect(
        rolloverMessage(moved: 1, fromLabel: 'yesterday', tripName: 'Vietnam'),
        '1 place from yesterday moved to today in "Vietnam"',
      );
    });

    test('plural with a dated label', () {
      expect(
        rolloverMessage(moved: 3, fromLabel: 'Sep 9', tripName: 'Vietnam'),
        '3 places from Sep 9 moved to today in "Vietnam"',
      );
    });
  });
}
