import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/services/trip_dates_service.dart';
import 'package:voyza/utils/trip_dates.dart';

void main() {
  final origin = DateTime(2026, 10, 5);
  final now = DateTime(2026, 9, 15, 12);

  SavedLocation stop({
    DateTime? start,
    DateTime? end,
    bool done = false,
    bool skipped = false,
    bool accommodation = false,
  }) =>
      SavedLocation(
        id: 'src',
        userId: 'owner',
        name: 'Tim Ho Wan',
        lat: 22.3,
        lng: 114.1,
        createdAt: DateTime(2026, 8, 1),
        fingerprint: 'orig-fp',
        isSkipped: skipped,
        isDone: done,
        stayDuration: 5400,
        scheduledDate: start,
        scheduledEndDate: end,
        tripId: 'trip-src',
        tag: 'food',
        placeTypes: const ['restaurant', 'food'],
        placeId: 'ChIJ123',
        isAccommodation: accommodation,
        photoReferences: const ['p1', 'p2'],
      );

  SavedLocation copy(SavedLocation l, {DateTime? base, int days = 4}) =>
      TripDatesService.copyStop(
        l,
        id: 'new-id',
        tripId: 'trip-copy',
        userId: 'me',
        origin: origin,
        base: base ?? tripDatesTbdAnchor,
        days: days,
        now: now,
      );

  test('done and skipped are reset; the tag and place types follow', () {
    final c = copy(stop(start: origin, done: true, skipped: true));
    expect(c.isDone, isFalse);
    expect(c.isSkipped, isFalse);
    expect(c.tag, 'food');
    expect(c.placeTypes, ['restaurant', 'food']);
    expect(c.placeId, 'ChIJ123');
    expect(c.photoReferences, ['p1', 'p2']);
    expect(c.stayDuration, 5400);
  });

  test('the copy is a fresh row in the new trip', () {
    final c = copy(stop(start: origin));
    expect(c.id, 'new-id');
    expect(c.tripId, 'trip-copy');
    expect(c.userId, 'me');
    expect(c.createdAt, now);
    expect(c.isSynced, isFalse);
    expect(c.fingerprint, isNot('orig-fp'));
  });

  test('days keep their offset from the source start', () {
    final undated = copy(stop(
      start: shiftTripDay(origin, 2),
      end: shiftTripDay(origin, 3),
      accommodation: true,
    ));
    expect(undated.scheduledDate, shiftTripDay(tripDatesTbdAnchor, 2));
    expect(undated.scheduledEndDate, shiftTripDay(tripDatesTbdAnchor, 3));
    expect(undated.isAccommodation, isTrue);

    final dated =
        copy(stop(start: shiftTripDay(origin, 2)), base: DateTime(2027, 1, 10));
    expect(dated.scheduledDate, DateTime(2027, 1, 12));
    expect(dated.scheduledEndDate, isNull);
  });

  test('an unscheduled stop stays unscheduled; days are clamped', () {
    expect(copy(stop()).scheduledDate, isNull);
    final clamped = copy(stop(start: shiftTripDay(origin, 9)), days: 4);
    expect(clamped.scheduledDate, shiftTripDay(tripDatesTbdAnchor, 4));
  });
}
