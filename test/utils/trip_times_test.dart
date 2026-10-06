import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/utils/trip_times.dart';

Trip _trip({
  int? arrival,
  int? departure,
  DateTime? start,
  DateTime? end,
}) =>
    Trip(
      id: 't',
      userId: 'u',
      name: 'Taipei',
      startDate: start ?? DateTime(2026, 10, 12),
      endDate: end ?? DateTime(2026, 10, 16),
      arrivalMinute: arrival,
      departureMinute: departure,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

/// 24-hour clock, so the expectations read without a locale.
String _time(int m) =>
    '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

void main() {
  group('summary line', () {
    test('says whichever time is set', () {
      expect(tripTimesSummary(_trip(), _time), isNull);
      expect(tripTimesSummary(_trip(arrival: 900), _time), 'Arrive 15:00');
      expect(tripTimesSummary(_trip(departure: 840), _time), 'Leave 14:00');
      expect(tripTimesSummary(_trip(arrival: 900, departure: 840), _time),
          'Arrive 15:00 · Leave 14:00');
    });

    test('midnight is a time like any other', () {
      expect(tripTimesSummary(_trip(arrival: 0), _time), 'Arrive 00:00');
    });
  });

  group('what an arrival does to the first day', () {
    test('an afternoon arrival: the day starts an hour later', () {
      expect(arrivalEffect(900, _time),
          'Auto-plan starts this day at 16:00, 1 hour after you arrive.');
    });

    test('an early arrival changes nothing', () {
      expect(arrivalEffect(6 * 60, _time),
          'Early enough: you have the whole day.');
    });

    test('a night arrival leaves the day free', () {
      expect(arrivalEffect(22 * 60, _time),
          'Too late to plan visits that day. Auto-plan keeps it free.');
    });
  });

  group('what a departure does to the last day', () {
    test('the day ends three hours before', () {
      expect(departureEffect(14 * 60, _time),
          'Auto-plan ends this day at 11:00, 3 hours before you leave.');
    });

    test('a morning departure leaves the day free', () {
      expect(departureEffect(9 * 60, _time),
          'Too early to plan visits that day. Auto-plan keeps it free.');
      // Before 03:00 the cut-off would fall on the day before.
      expect(departureEffect(60, _time),
          'Too early to plan visits that day. Auto-plan keeps it free.');
    });
  });

  group('one-day trips', () {
    final day = DateTime(2026, 10, 12);

    test('are recognised by their dates, not their times', () {
      expect(tripIsOneDay(_trip(start: day, end: day)), isTrue);
      expect(
          tripIsOneDay(_trip(start: day, end: DateTime(2026, 10, 12, 23, 59))),
          isTrue);
      expect(tripIsOneDay(_trip()), isFalse);
    });

    test('two times with nothing in between leave no time', () {
      expect(oneDayTripHasNoTime(10 * 60, 19 * 60), isFalse);
      expect(oneDayTripHasNoTime(14 * 60, 17 * 60), isTrue);
      expect(oneDayTripHasNoTime(null, null), isFalse);
    });
  });
}
