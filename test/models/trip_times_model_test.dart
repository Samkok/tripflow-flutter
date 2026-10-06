import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/trip.dart';

Map<String, dynamic> _row([Map<String, dynamic> extra = const {}]) => {
      'id': 't1',
      'user_id': 'u1',
      'name': 'Taipei',
      'start_date': '2026-10-12T00:00:00.000',
      'end_date': '2026-10-16T00:00:00.000',
      'created_at': '2026-01-01T00:00:00.000',
      'updated_at': '2026-01-01T00:00:00.000',
      ...extra,
    };

void main() {
  test('a trip saved before the times existed simply has none', () {
    final trip = Trip.fromJson(_row());
    expect(trip.arrivalMinute, isNull);
    expect(trip.departureMinute, isNull);
  });

  test('the two times survive a round trip through JSON', () {
    final trip =
        Trip.fromJson(_row({'arrival_minute': 900, 'departure_minute': 840}));
    expect(trip.arrivalMinute, 900);
    expect(trip.departureMinute, 840);
    final again = Trip.fromJson(trip.toJson());
    expect(again.arrivalMinute, 900);
    expect(again.departureMinute, 840);
  });

  test('anything that is not a time of day reads as not set', () {
    for (final bad in [-1, 1440, 99999, 'noon', true]) {
      final trip =
          Trip.fromJson(_row({'arrival_minute': bad, 'departure_minute': bad}));
      expect(trip.arrivalMinute, isNull, reason: '$bad');
      expect(trip.departureMinute, isNull, reason: '$bad');
    }
    // A number that arrives as a double still counts.
    expect(Trip.fromJson(_row({'arrival_minute': 900.0})).arrivalMinute, 900);
    expect(Trip.fromJson(_row({'arrival_minute': 0})).arrivalMinute, 0);
    expect(
        Trip.fromJson(_row({'departure_minute': 1439})).departureMinute, 1439);
  });

  test('copyWith keeps, changes and CLEARS a time', () {
    final trip =
        Trip.fromJson(_row({'arrival_minute': 900, 'departure_minute': 840}));
    final renamed = trip.copyWith(name: 'Tainan');
    expect(renamed.arrivalMinute, 900);
    expect(renamed.departureMinute, 840);

    final later = trip.copyWith(arrivalMinute: 960);
    expect(later.arrivalMinute, 960);
    expect(later.departureMinute, 840);

    final cleared = trip.copyWith(arrivalMinute: null);
    expect(cleared.arrivalMinute, isNull);
    expect(cleared.departureMinute, 840, reason: 'the other one stays');
    expect(trip.copyWith(departureMinute: null).departureMinute, isNull);
  });

  test('a local update with an explicit null takes the time off', () {
    // How the guest store applies an update: the stored JSON plus the
    // changed keys, read back as a trip.
    final stored = Trip.fromJson(_row({'arrival_minute': 900}));
    final updated =
        Trip.fromJson(stored.toJson()..addAll({'arrival_minute': null}));
    expect(updated.arrivalMinute, isNull);
  });
}
