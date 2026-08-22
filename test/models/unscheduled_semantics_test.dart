import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/utils/trip_dates.dart';

SavedLocation _saved({DateTime? scheduled, DateTime? end}) => SavedLocation(
      id: 'x',
      userId: 'u',
      name: 'Cafe',
      lat: 25.0,
      lng: 121.5,
      createdAt: DateTime(2026, 3, 10, 21, 30),
      fingerprint: 'fp-x',
      scheduledDate: scheduled,
      scheduledEndDate: end,
    );

LocationModel _model({DateTime? scheduled}) => LocationModel(
      id: 'x',
      name: 'Cafe',
      address: '',
      coordinates: const LatLng(25.0, 121.5),
      addedAt: DateTime(2026, 3, 10, 21, 30),
      scheduledDate: scheduled,
    );

void main() {
  group('unscheduled = active on NO day (the semantics flip)', () {
    test('SavedLocation with null scheduledDate is active nowhere', () {
      final loc = _saved(scheduled: null);
      expect(loc.isActiveOnDate(DateTime(2026, 3, 10)), isFalse,
          reason: 'must NOT fall back to createdAt (the old phantom day)');
      expect(loc.isActiveOnDate(DateTime.now()), isFalse);
    });

    test('LocationModel with null scheduledDate is active nowhere', () {
      final loc = _model(scheduled: null);
      expect(loc.isActiveOnDate(DateTime(2026, 3, 10)), isFalse);
    });

    test('dated rows behave exactly as before', () {
      final loc = _saved(
          scheduled: DateTime(2026, 4, 1), end: DateTime(2026, 4, 3));
      expect(loc.isActiveOnDate(DateTime(2026, 3, 31)), isFalse);
      expect(loc.isActiveOnDate(DateTime(2026, 4, 1)), isTrue);
      expect(loc.isActiveOnDate(DateTime(2026, 4, 3)), isTrue);
      expect(loc.isActiveOnDate(DateTime(2026, 4, 4)), isFalse);
    });
  });

  group('copyWith sentinel: null really clears', () {
    test('SavedLocation.copyWith(scheduledDate: null) clears the date', () {
      final dated = _saved(scheduled: DateTime(2026, 4, 1));
      final cleared = dated.copyWith(scheduledDate: null);
      expect(cleared.scheduledDate, isNull);
    });

    test('SavedLocation.copyWith omitting scheduledDate keeps it', () {
      final dated = _saved(scheduled: DateTime(2026, 4, 1));
      final kept = dated.copyWith(name: 'Renamed');
      expect(kept.scheduledDate, DateTime(2026, 4, 1));
    });

    test('LocationModel.copyWith(scheduledDate: null) clears the date', () {
      final dated = _model(scheduled: DateTime(2026, 4, 1));
      expect(dated.copyWith(scheduledDate: null).scheduledDate, isNull);
      expect(dated.copyWith(name: 'Renamed').scheduledDate,
          DateTime(2026, 4, 1));
    });
  });

  group('day axis ignores unscheduled rows', () {
    test('contiguousTripDates skips nulls entirely', () {
      final axis = contiguousTripDates([
        DateTime(2026, 4, 1),
        null, // an unscheduled row contributes nothing
        DateTime(2026, 4, 3),
      ]);
      expect(axis, [
        DateTime(2026, 4, 1),
        DateTime(2026, 4, 2),
        DateTime(2026, 4, 3),
      ]);
    });

    test('all-null marks produce an empty axis', () {
      expect(contiguousTripDates([null, null]), isEmpty);
    });
  });
}
