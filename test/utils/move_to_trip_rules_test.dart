import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/utils/move_to_trip_rules.dart';
import 'package:voyza/utils/trip_day_labels.dart';
import 'package:voyza/utils/trip_dates.dart';

Trip trip(
  String id, {
  String name = 'Trip',
  String? country,
  DateTime? start,
  DateTime? end,
  bool tbd = false,
}) =>
    Trip(
      id: id,
      userId: 'u',
      name: name,
      countryCode: country,
      startDate: start,
      endDate: end,
      datesTbd: tbd,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  group('moveCountryMismatch', () {
    test('an untagged target takes places from anywhere', () {
      expect(
        moveCountryMismatch(
            targetCode: null, sourceCode: 'HK', locationCodes: ['MO', 'JP']),
        isNull,
      );
    });

    test('a tagged source trip decides for every place in it', () {
      expect(
        moveCountryMismatch(
            targetCode: 'hk', sourceCode: ' HK ', locationCodes: ['MO']),
        isNull,
        reason: 'same tag, whatever the places say',
      );
      expect(
        moveCountryMismatch(
            targetCode: 'HK', sourceCode: 'MO', locationCodes: const []),
        'MO',
        reason: 'different tag names the offending country',
      );
    });

    test('an untagged source asks the places; unknown ones pass', () {
      expect(
        moveCountryMismatch(
            targetCode: 'HK',
            sourceCode: null,
            locationCodes: [null, 'hk', '', 'MO', 'JP']),
        'MO',
      );
      expect(
        moveCountryMismatch(
            targetCode: 'HK', sourceCode: null, locationCodes: [null, 'HK']),
        isNull,
      );
    });

    test('tags settle the check only when they can', () {
      expect(
          moveCountrySettledByTags(targetCode: null, sourceCode: null), isTrue);
      expect(
          moveCountrySettledByTags(targetCode: 'HK', sourceCode: 'MO'), isTrue);
      expect(moveCountrySettledByTags(targetCode: 'HK', sourceCode: null),
          isFalse);
    });
  });

  group('moveTargetTrips', () {
    final today = DateTime(2026, 10, 21);
    test('drops the current trip and duplicates, upcoming first', () {
      final current = trip('cur', name: 'Current');
      final over = trip('over',
          name: 'Over',
          start: DateTime(2026, 10, 1),
          end: DateTime(2026, 10, 3));
      final soon = trip('soon',
          name: 'Soon',
          start: DateTime(2026, 11, 5),
          end: DateTime(2026, 11, 9));
      final later = trip('later',
          name: 'Later',
          start: DateTime(2026, 12, 1),
          end: DateTime(2026, 12, 2));
      final undated = trip('tbd',
          name: 'Someday',
          start: tripDatesTbdAnchor,
          end: tripDatesTbdAnchor.add(const Duration(days: 2)),
          tbd: true);
      final out = moveTargetTrips(
        [current, later, undated, over, soon, soon],
        exceptTripId: 'cur',
        today: today,
      );
      expect(out.map((t) => t.id).toList(), ['soon', 'later', 'tbd', 'over']);
    });

    test('within a group, undated trips sort by name after dated ones', () {
      final b = trip('b',
          name: 'Beta',
          start: tripDatesTbdAnchor,
          end: tripDatesTbdAnchor,
          tbd: true);
      final a = trip('a',
          name: 'alpha',
          start: tripDatesTbdAnchor,
          end: tripDatesTbdAnchor,
          tbd: true);
      final dated = trip('d',
          name: 'Zed', start: DateTime(2027, 1, 1), end: DateTime(2027, 1, 2));
      final out =
          moveTargetTrips([b, a, dated], exceptTripId: null, today: today);
      expect(out.map((t) => t.id).toList(), ['d', 'a', 'b']);
    });
  });

  group('moveTargetDays', () {
    test('a dated trip offers each day of its range', () {
      final t =
          trip('t', start: DateTime(2026, 11, 5), end: DateTime(2026, 11, 7));
      expect(moveTargetDays(t), [
        DateTime(2026, 11, 5),
        DateTime(2026, 11, 6),
        DateTime(2026, 11, 7),
      ]);
    });

    test('a trip without dates offers none', () {
      expect(moveTargetDays(trip('t')), isEmpty);
    });

    test('an undated trip offers numbered days', () {
      final t = trip('t',
          start: tripDatesTbdAnchor,
          end: tripDatesTbdAnchor.add(const Duration(days: 1)),
          tbd: true);
      final days = moveTargetDays(t);
      final label = DayLabeler.forTrip(t);
      expect(days.map((d) => label(d)).toList(), ['Day 1', 'Day 2']);
    });
  });
}
