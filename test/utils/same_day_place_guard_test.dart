import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/same_day_place_guard.dart';

PlaceKey key(String name, double lat, double lng, {String? placeId}) =>
    (id: name, placeId: placeId, name: name, lat: lat, lng: lng);

void main() {
  group('isSamePlace (strict — reschedule paths)', () {
    test('matches on place id', () {
      expect(
        isSamePlace(
            key('A', 1, 1, placeId: 'p1'), key('B', 2, 2, placeId: 'p1')),
        isTrue,
      );
    });

    test('same name a few metres apart is NOT the same place', () {
      expect(
        isSamePlace(key('Golden Gate Bridge', 37.8199, -122.4783),
            key('Golden Gate Bridge', 37.8200, -122.4783)),
        isFalse,
      );
    });
  });

  group('isLikelySamePlace (loose — new adds)', () {
    test('still matches on place id', () {
      expect(
        isLikelySamePlace(
            key('A', 1, 1, placeId: 'p1'), key('B', 2, 2, placeId: 'p1')),
        isTrue,
      );
    });

    test('same name within a kilometre is the same place', () {
      // Two Google entries for one bridge, ~600 m apart.
      expect(
        isLikelySamePlace(key('Golden Gate Bridge', 37.8199, -122.4783),
            key('Golden Gate Bridge', 37.8253, -122.4783)),
        isTrue,
      );
    });

    test('name match is case- and accent-insensitive', () {
      expect(
        isLikelySamePlace(key('Chợ Bến Thành', 10.7725, 106.6980),
            key('cho ben thanh', 10.7728, 106.6984)),
        isTrue,
      );
    });

    test('same name far apart is a different place', () {
      // Two 7-Elevens 3 km apart.
      expect(
        isLikelySamePlace(key('7-Eleven', 13.7563, 100.5018),
            key('7-Eleven', 13.7833, 100.5018)),
        isFalse,
      );
    });

    test('different names right next to each other are different places', () {
      expect(
        isLikelySamePlace(key('Fairmont', 37.7924, -122.4104),
            key('Tonga Room', 37.7924, -122.4105)),
        isFalse,
      );
    });

    test('a blank name never fuzzy-matches', () {
      // ~110 m apart: the strict rule (identical coords) doesn't apply, and
      // an empty name must not make the loose rule match either.
      expect(isLikelySamePlace(key('', 1, 1), key('', 1.001, 1)), isFalse);
    });
  });

  group('filterSameDayDuplicates', () {
    test('uses the strict rule by default', () {
      final r = filterSameDayDuplicates(
        moving: [key('Golden Gate Bridge', 37.8253, -122.4783)],
        occupantsOnDay: [key('Golden Gate Bridge', 37.8199, -122.4783)],
      );
      expect(r.allowedIds, {'Golden Gate Bridge'});
    });

    test('blocks the likely duplicate when asked to', () {
      final r = filterSameDayDuplicates(
        moving: [key('Golden Gate Bridge', 37.8253, -122.4783)],
        occupantsOnDay: [key('Golden Gate Bridge', 37.8199, -122.4783)],
        samePlace: isLikelySamePlace,
      );
      expect(r.allowedIds, isEmpty);
      expect(r.blockedNames, ['Golden Gate Bridge']);
    });
  });
}
