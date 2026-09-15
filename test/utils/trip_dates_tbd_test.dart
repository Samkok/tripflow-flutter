import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/trip_dates.dart';

void main() {
  test('day numbers count from the trip start, 1-based', () {
    final start = DateTime(2100, 1, 1);
    expect(tripDayNumber(start, DateTime(2100, 1, 1)), 1);
    expect(tripDayNumber(start, DateTime(2100, 1, 3, 15)), 3);
    expect(tripDayLabel(start, DateTime(2100, 1, 10)), 'Day 10');
  });

  test('the anchor is far enough ahead never to read as past', () {
    expect(tripDatesTbdAnchor.isAfter(DateTime(2090)), isTrue);
    expect(tripDayNumber(tripDatesTbdAnchor, tripDatesTbdAnchor), 1);
  });

  test('shiftTripDay lands on local midnight across month and DST edges', () {
    expect(shiftTripDay(DateTime(2026, 1, 30, 9), 3), DateTime(2026, 2, 2));
    expect(shiftTripDay(DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));
    // Undated → dated: Day 4 on the anchor moves with the same delta as
    // Day 1 and keeps its offset.
    final delta = daySpanDays(tripDatesTbdAnchor, DateTime(2026, 10, 5));
    final day4 = shiftTripDay(tripDatesTbdAnchor, 3);
    expect(shiftTripDay(day4, delta), DateTime(2026, 10, 8));
  });
}
