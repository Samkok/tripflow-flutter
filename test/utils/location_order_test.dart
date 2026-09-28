import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/utils/location_order.dart';

SavedLocation place(String id, DateTime addedAt) => SavedLocation(
      id: id,
      userId: 'u1',
      fingerprint: id,
      name: 'Place $id',
      lat: 35.0,
      lng: 139.0,
      isSkipped: false,
      stayDuration: 1800,
      createdAt: addedAt,
      tripId: 'trip1',
    );

void main() {
  final monday = DateTime(2026, 9, 21, 9);

  test('the place added last comes first', () {
    final first = place('a', monday);
    final second = place('b', monday.add(const Duration(hours: 1)));
    final third = place('c', monday.add(const Duration(days: 2)));

    expect(
      sortedNewestAddedFirst([second, first, third]).map((l) => l.id),
      ['c', 'b', 'a'],
    );
  });

  test('the input list is left as it was', () {
    final input = [
      place('a', monday),
      place('b', monday.add(const Duration(hours: 1))),
    ];
    final sorted = sortedNewestAddedFirst(input);
    expect(input.map((l) => l.id), ['a', 'b']);
    expect(sorted.map((l) => l.id), ['b', 'a']);
  });

  test('places added in the same instant keep one fixed order', () {
    final batch = [
      place('m', monday),
      place('c', monday),
      place('x', monday),
    ];
    final once = sortedNewestAddedFirst(batch).map((l) => l.id).toList();
    final again =
        sortedNewestAddedFirst(batch.reversed).map((l) => l.id).toList();
    expect(once, ['c', 'm', 'x']);
    expect(again, once);
  });

  test('oldest first is the same list read backwards', () {
    final sorted = sortedNewestAddedFirst([
      place('a', monday),
      place('b', monday.add(const Duration(minutes: 5))),
      place('c', monday.add(const Duration(minutes: 9))),
    ]);
    expect(sorted.reversed.map((l) => l.id), ['a', 'b', 'c']);
  });
}
