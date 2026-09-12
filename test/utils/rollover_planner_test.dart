import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/utils/rollover_planner.dart';

SavedLocation row(
  String id, {
  required DateTime day,
  String trip = 't1',
  String name = 'Place',
  double lat = 13.75,
  double lng = 100.5,
  bool done = false,
  bool skipped = false,
  bool accommodation = false,
  DateTime? endDay,
  String? placeId,
}) =>
    SavedLocation(
      id: id,
      userId: 'u',
      fingerprint: 'f$id',
      name: name,
      lat: lat,
      lng: lng,
      createdAt: DateTime(2026, 9, 1),
      stayDuration: 1800,
      scheduledDate: day,
      scheduledEndDate: endDay,
      tripId: trip,
      isDone: done,
      isSkipped: skipped,
      isAccommodation: accommodation,
      placeId: placeId,
    );

void main() {
  final today = DateTime(2026, 9, 12);
  final yesterday = DateTime(2026, 9, 11);
  final twoDaysAgo = DateTime(2026, 9, 10);

  test('active stops on past days move; done/skipped stay', () {
    final ids = planRollover(tripId: 't1', today: today, rows: [
      row('a', day: yesterday, name: 'Temple', lat: 13.75, lng: 100.50),
      row('b',
          day: yesterday, name: 'Museum', lat: 13.76, lng: 100.51, done: true),
      row('c',
          day: twoDaysAgo,
          name: 'Market',
          lat: 13.77,
          lng: 100.52,
          skipped: true),
      row('d', day: twoDaysAgo, name: 'Park', lat: 13.78, lng: 100.53),
    ]);
    expect(ids, ['a', 'd']);
  });

  test('today and future rows never move', () {
    final ids = planRollover(tripId: 't1', today: today, rows: [
      row('a', day: today, name: 'Temple'),
      row('b', day: DateTime(2026, 9, 13), name: 'Museum', lat: 13.9),
    ]);
    expect(ids, isEmpty);
  });

  test('accommodations and multi-day stays are pinned', () {
    final ids = planRollover(tripId: 't1', today: today, rows: [
      row('hotel', day: twoDaysAgo, name: 'Hotel', accommodation: true),
      row('span',
          day: twoDaysAgo,
          endDay: DateTime(2026, 9, 14),
          name: 'Resort',
          lat: 13.9),
    ]);
    expect(ids, isEmpty);
  });

  test('a place already planned on today is skipped (stays on its day)', () {
    final ids = planRollover(tripId: 't1', today: today, rows: [
      row('old',
          day: yesterday, name: 'Chợ Bến Thành', lat: 10.7725, lng: 106.6980),
      row('now',
          day: today, name: 'Cho Ben Thanh', lat: 10.7728, lng: 106.6984),
      row('other',
          day: yesterday, name: 'Bitexco', lat: 10.7716, lng: 106.7043),
    ]);
    expect(ids, ['other']);
  });

  test('two leftovers of the same place move only once', () {
    final ids = planRollover(tripId: 't1', today: today, rows: [
      row('x1', day: twoDaysAgo, name: 'Wat Arun', placeId: 'p1'),
      row('x2', day: yesterday, name: 'Wat Arun', placeId: 'p1'),
    ]);
    expect(ids, ['x1']);
  });

  test('other trips are untouched', () {
    final ids = planRollover(tripId: 't1', today: today, rows: [
      row('a', day: yesterday, name: 'Temple', trip: 't2'),
    ]);
    expect(ids, isEmpty);
  });
}
