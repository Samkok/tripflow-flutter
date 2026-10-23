import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/utils/trip_dates.dart';
import 'package:voyza/utils/unvisited_places.dart';

LocationModel place(
  String id, {
  String? name,
  DateTime? day,
  bool done = false,
  bool skipped = false,
  bool hotel = false,
}) =>
    LocationModel(
      id: id,
      name: name ?? 'Place $id',
      address: '',
      coordinates: const LatLng(22.3, 114.17),
      addedAt: DateTime(2026),
      scheduledDate: day,
      isDone: done,
      isSkipped: skipped,
      isAccommodation: hotel,
    );

Trip trip({DateTime? start, DateTime? end, bool tbd = false}) => Trip(
      id: 't',
      userId: 'u',
      name: 'Macau',
      startDate: start,
      endDate: end,
      datesTbd: tbd,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  final d17 = DateTime(2026, 10, 17);
  final d18 = DateTime(2026, 10, 18);
  final d19 = DateTime(2026, 10, 19);

  group('unvisitedPlaces', () {
    test('keeps only what was never done, skipped or slept in', () {
      final rows = [
        place('a', day: d18),
        place('done', day: d17, done: true),
        place('skip', day: d17, skipped: true),
        place('hotel', day: d17, hotel: true),
        place('b', day: d17),
      ];
      expect(unvisitedPlaces(rows).map((p) => p.id).toList(), ['b', 'a']);
    });

    test('orders by day, then name, with the Unscheduled bucket last', () {
      final rows = [
        place('u2', name: 'Zoo'),
        place('c', name: 'Casino', day: d19),
        place('u1', name: 'Arcade'),
        place('b', name: 'Bakery', day: d18),
        place('a', name: 'Aquarium', day: d18),
      ];
      expect(
        unvisitedPlaces(rows).map((p) => p.id).toList(),
        ['a', 'b', 'c', 'u1', 'u2'],
      );
    });
  });

  group('tripNeedsUnvisitedReview', () {
    final today = DateTime(2026, 10, 21);
    final ended = trip(start: d17, end: d19);

    test('an ended trip with leftovers needs it', () {
      expect(
          tripNeedsUnvisitedReview(ended, [place('a', day: d19)], today: today),
          isTrue);
    });

    test('an ended trip with everything done or skipped does not', () {
      expect(
        tripNeedsUnvisitedReview(
          ended,
          [place('a', day: d19, done: true), place('b', skipped: true)],
          today: today,
        ),
        isFalse,
      );
    });

    test('a trip still running, or on its last day, does not', () {
      expect(
          tripNeedsUnvisitedReview(ended, [place('a')], today: d19), isFalse);
      expect(
          tripNeedsUnvisitedReview(
              trip(start: d19, end: DateTime(2026, 10, 25)), [place('a')],
              today: today),
          isFalse);
    });

    test('a trip without real dates, or no trip, never does', () {
      final undated = trip(
          start: tripDatesTbdAnchor,
          end: tripDatesTbdAnchor.add(const Duration(days: 2)),
          tbd: true);
      expect(tripNeedsUnvisitedReview(undated, [place('a')], today: today),
          isFalse);
      expect(
          tripNeedsUnvisitedReview(null, [place('a')], today: today), isFalse);
    });
  });
}
