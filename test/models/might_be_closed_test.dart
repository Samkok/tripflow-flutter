import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/saved_location.dart';

LocationModel _loc(List<OpeningPeriod>? hours) => LocationModel(
      id: 'x',
      name: 'Museum',
      address: '',
      coordinates: const LatLng(25, 121),
      addedAt: DateTime(2026),
      googleOpeningHours: hours,
    );

void main() {
  // 2026-09-01 is a Tuesday (Google weekday 2); 2026-09-06 a Sunday (0).
  final tuesday = DateTime(2026, 9, 1);
  final sunday = DateTime(2026, 9, 6);

  test('unknown hours never flag — absence of data is not a closure', () {
    expect(_loc(null).mightBeClosedOn(tuesday), isFalse);
    expect(_loc(const []).mightBeClosedOn(tuesday), isFalse);
  });

  test('24/7 never flags', () {
    final h = [const OpeningPeriod(openDay: 0, openMinutes: 0)];
    expect(h.first.isAlwaysOpen, isTrue);
    expect(_loc(h).mightBeClosedOn(sunday), isFalse);
  });

  test('a weekday with no period flags; one with a period does not', () {
    // Open Mon–Sat 09:00–17:00, nothing on Sunday.
    final h = [
      for (var d = 1; d <= 6; d++)
        OpeningPeriod(
            openDay: d, openMinutes: 9 * 60, closeDay: d, closeMinutes: 17 * 60),
    ];
    expect(_loc(h).mightBeClosedOn(tuesday), isFalse);
    expect(_loc(h).mightBeClosedOn(sunday), isTrue);
  });
}
