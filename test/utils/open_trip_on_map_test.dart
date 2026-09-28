import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/utils/open_trip_on_map.dart';

Trip trip({DateTime? start, DateTime? end}) => Trip(
      id: 'trip1',
      userId: 'u1',
      name: 'Tokyo',
      startDate: start,
      endDate: end,
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
    );

void main() {
  final start = DateTime(2026, 10, 5, 14, 30);
  final end = DateTime(2026, 10, 12, 9);

  test('a trip underway opens on today', () {
    final now = DateTime(2026, 10, 8, 18, 45);
    expect(
      mapLandingDayFor(trip(start: start, end: end), now: now),
      DateTime(2026, 10, 8),
    );
  });

  test('the first and last day of the trip count as underway', () {
    expect(
      mapLandingDayFor(trip(start: start, end: end),
          now: DateTime(2026, 10, 5, 0, 1)),
      DateTime(2026, 10, 5),
    );
    expect(
      mapLandingDayFor(trip(start: start, end: end),
          now: DateTime(2026, 10, 12, 23, 59)),
      DateTime(2026, 10, 12),
    );
  });

  test('a trip that has not started opens on day one', () {
    expect(
      mapLandingDayFor(trip(start: start, end: end),
          now: DateTime(2026, 9, 28)),
      DateTime(2026, 10, 5),
    );
  });

  test('a trip that has ended opens on day one', () {
    expect(
      mapLandingDayFor(trip(start: start, end: end),
          now: DateTime(2026, 10, 13)),
      DateTime(2026, 10, 5),
    );
  });

  test('without an end date the trip opens on day one', () {
    expect(
      mapLandingDayFor(trip(start: start), now: DateTime(2026, 10, 8)),
      DateTime(2026, 10, 5),
    );
  });

  test('without a start date the map keeps its day', () {
    expect(mapLandingDayFor(trip(), now: DateTime(2026, 10, 8)), isNull);
  });
}
