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
    final plan = planRollover(tripId: 't1', today: today, rows: [
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
    expect(plan.move, ['a', 'd']);
  });

  test('today and future rows never move', () {
    final plan = planRollover(tripId: 't1', today: today, rows: [
      row('a', day: today, name: 'Temple'),
      row('b', day: DateTime(2026, 9, 13), name: 'Museum', lat: 13.9),
    ]);
    expect(plan.move, isEmpty);
  });

  test('accommodations and multi-day stays are pinned', () {
    final plan = planRollover(tripId: 't1', today: today, rows: [
      row('hotel', day: twoDaysAgo, name: 'Hotel', accommodation: true),
      row('span',
          day: twoDaysAgo,
          endDay: DateTime(2026, 9, 14),
          name: 'Resort',
          lat: 13.9),
    ]);
    expect(plan.move, isEmpty);
  });

  test('a leftover always moves; an open copy already on today is replaced',
      () {
    final plan = planRollover(tripId: 't1', today: today, rows: [
      row('old',
          day: yesterday, name: 'Chợ Bến Thành', lat: 10.7725, lng: 106.6980),
      row('now',
          day: today, name: 'Cho Ben Thanh', lat: 10.7728, lng: 106.6984),
      row('other',
          day: yesterday, name: 'Bitexco', lat: 10.7716, lng: 106.7043),
    ]);
    expect(plan.move, ['old', 'other']);
    expect(plan.delete, ['now']);
  });

  test(
      'a copy already visited, skipped or staying today wins; the leftover goes',
      () {
    final visited = planRollover(tripId: 't1', today: today, rows: [
      row('old', day: yesterday, name: 'Wat Pho', placeId: 'p1'),
      row('now', day: today, name: 'Wat Pho', placeId: 'p1', done: true),
    ]);
    expect(visited.move, isEmpty);
    expect(visited.delete, ['old']);

    final skipped = planRollover(tripId: 't1', today: today, rows: [
      row('old', day: yesterday, name: 'Wat Pho', placeId: 'p1'),
      row('now', day: today, name: 'Wat Pho', placeId: 'p1', skipped: true),
    ]);
    expect(skipped.move, isEmpty);
    expect(skipped.delete, ['old']);

    final staying = planRollover(tripId: 't1', today: today, rows: [
      row('old', day: yesterday, name: 'Riverside Hotel', placeId: 'h1'),
      row('stay',
          day: yesterday,
          endDay: today,
          name: 'Riverside Hotel',
          placeId: 'h1',
          accommodation: true),
    ]);
    expect(staying.move, isEmpty);
    expect(staying.delete, ['old']);
  });

  test('two leftovers of the same place: the newer replaces the older', () {
    final plan = planRollover(tripId: 't1', today: today, rows: [
      row('x1', day: twoDaysAgo, name: 'Wat Arun', placeId: 'p1'),
      row('x2', day: yesterday, name: 'Wat Arun', placeId: 'p1'),
    ]);
    expect(plan.move, ['x2']);
    expect(plan.delete, ['x1']);
  });

  test('a plan with nothing to move or remove is empty', () {
    final plan = planRollover(tripId: 't1', today: today, rows: [
      row('t', day: today, name: 'Temple'),
    ]);
    expect(plan.isEmpty, isTrue);
  });

  test('other trips are untouched', () {
    final plan = planRollover(tripId: 't1', today: today, rows: [
      row('a', day: yesterday, name: 'Temple', trip: 't2'),
    ]);
    expect(plan.move, isEmpty);
  });
}
