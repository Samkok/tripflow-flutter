import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/services/trip_dates_service.dart';
import 'package:voyza/utils/trip_day_labels.dart';
import 'package:voyza/utils/trip_dates.dart';

Trip _trip({required bool datesTbd, DateTime? start, DateTime? end}) => Trip(
      id: 't',
      userId: 'u',
      name: 'Hong Kong',
      startDate: start,
      endDate: end,
      datesTbd: datesTbd,
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
    );

void main() {
  group('DayLabeler', () {
    test('dated trips print calendar dates', () {
      final lab = DayLabeler.forTrip(
          _trip(datesTbd: false, start: DateTime(2026, 10, 5)));
      expect(lab.tbd, isFalse);
      expect(lab(DateTime(2026, 10, 7)), 'Oct 7');
      expect(lab.range(DateTime(2026, 10, 5), DateTime(2026, 10, 7)),
          'Oct 5 – Oct 7');
      expect(lab.dayNumber(DateTime(2026, 10, 7)), 0);
    });

    test('undated trips print day numbers from the anchor', () {
      final anchor = tripDatesTbdAnchor;
      final lab = DayLabeler.forTrip(
          _trip(datesTbd: true, start: anchor, end: shiftTripDay(anchor, 4)));
      expect(lab.tbd, isTrue);
      expect(lab(anchor), 'Day 1');
      expect(lab(shiftTripDay(anchor, 2)), 'Day 3');
      expect(lab.range(anchor, shiftTripDay(anchor, 4)), 'Day 1 – Day 5');
      expect(lab.dayNumber(shiftTripDay(anchor, 4)), 5);
      expect(lab.isToday(DateTime.now()), isFalse);
    });

    test('a trip saved without the flag but on the anchor year is undated', () {
      // Rows written while the server lacked the dates_tbd column.
      final t = _trip(
          datesTbd: false,
          start: tripDatesTbdAnchor,
          end: shiftTripDay(tripDatesTbdAnchor, 2));
      expect(t.isUndated, isTrue);
      expect(DayLabeler.forTrip(t).tbd, isTrue);
      expect(
          DayLabeler.forTrip(t)(shiftTripDay(tripDatesTbdAnchor, 1)), 'Day 2');
    });

    test('a trip flagged undated but without a start falls back to dates', () {
      expect(DayLabeler.forTrip(_trip(datesTbd: true)).tbd, isFalse);
      expect(DayLabeler.forTrip(null), DayLabeler.dated);
    });
  });

  group('Trip.datesTbd', () {
    test('round-trips through JSON and defaults to false', () {
      final t = _trip(datesTbd: true, start: tripDatesTbdAnchor);
      expect(Trip.fromJson(t.toJson()).datesTbd, isTrue);
      final legacy = t.toJson()..remove('dates_tbd');
      expect(Trip.fromJson(legacy).datesTbd, isFalse);
    });
  });

  group('TripDatesService.copyName', () {
    test('picks the first free "(copy N)" name', () {
      expect(TripDatesService.copyName('Hong Kong', ['Hong Kong']),
          'Hong Kong (copy)');
      expect(
          TripDatesService.copyName(
              'Hong Kong', ['Hong Kong', 'Hong Kong (copy)']),
          'Hong Kong (copy 2)');
      expect(
          TripDatesService.copyName('Hong Kong',
              ['Hong Kong (copy)', 'Hong Kong (copy 2)', 'Hong Kong (copy 3)']),
          'Hong Kong (copy 4)');
    });
  });

  test('isOnTbdAnchor only fires for the reserved anchor year', () {
    expect(isOnTbdAnchor(tripDatesTbdAnchor), isTrue);
    expect(isOnTbdAnchor(shiftTripDay(tripDatesTbdAnchor, 30)), isTrue);
    expect(isOnTbdAnchor(DateTime(2026, 9, 15)), isFalse);
  });
}
