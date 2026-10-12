import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/services/places_service.dart';

Map<String, dynamic> _c(String name, List<String> types) =>
    {'long_name': name, 'short_name': name, 'types': types};

void main() {
  group('placeFloorFromComponents', () {
    test('floor, then unit, then room, joined with a middle dot', () {
      expect(
        placeFloorFromComponents([
          _c('Shop 2301', ['subpremise']),
          _c('23/F', ['floor']),
          _c('1', ['street_number']),
          _c('Matheson Street', ['route']),
          _c('Hong Kong', ['country', 'political']),
        ]),
        '23/F · Shop 2301',
      );
      expect(
        placeFloorFromComponents([
          _c('Room 4', ['room']),
          _c('Unit 5', ['subpremise']),
        ]),
        'Unit 5 · Room 4',
      );
    });

    test('a bare number becomes "Floor N"', () {
      expect(
          placeFloorFromComponents([
            _c('2', ['floor'])
          ]),
          'Floor 2');
      expect(
          placeFloorFromComponents([
            _c('G/F', ['floor'])
          ]),
          'G/F');
      expect(
          placeFloorFromComponents([
            _c('B1', ['floor'])
          ]),
          'B1');
    });

    test('components without a floor give an empty string (checked, none)', () {
      expect(
        placeFloorFromComponents([
          _c('1', ['street_number']),
          _c('Nathan Road', ['route']),
        ]),
        '',
      );
      expect(placeFloorFromComponents(const []), '');
    });

    test('no components at all gives null (unknown)', () {
      expect(placeFloorFromComponents(null), isNull);
      expect(placeFloorFromComponents('nope'), isNull);
    });

    test('blank and malformed entries are skipped', () {
      expect(
        placeFloorFromComponents([
          {
            'long_name': '   ',
            'types': ['floor']
          },
          {
            'types': ['subpremise']
          },
          'junk',
          _c('Level 3', ['floor']),
        ]),
        'Level 3',
      );
    });
  });

  group('placeFloorFromAddress', () {
    test('reads the shop and floor out of Hong Kong address text', () {
      expect(
        placeFloorFromAddress(
            'Hong Kong, Kowloon, Tsim Sha Tsui, HK 九龍 SHOP NO.G29 ON GROUND '
            'FLOOR OF “K11.18 HANOI ROAD, TSIMSHA TSUL'),
        'Ground Floor · Shop No.g29',
      );
      expect(
        placeFloorFromAddress(
            'Shop 20, 4/F, Langham Place, 8 Argyle St, Mong Kok, Kowloon'),
        '4/F · Shop 20',
      );
      expect(placeFloorFromAddress('Level 2, Pacific Place, 88 Queensway'),
          'Level 2');
      expect(
          placeFloorFromAddress('怡和街68號地下3-11舖, 68號 Yee Wo St'), '地下 · 3-11舖');
    });

    test('a plain street address has none', () {
      expect(placeFloorFromAddress('500 Hennessy Rd, Causeway Bay, Hong Kong'),
          '');
      expect(placeFloorFromAddress('1 Floor Street, Springfield'), '');
    });
  });

  group('placeFloorOf', () {
    test('components first, then the address, then none, then unknown', () {
      expect(
        placeFloorOf(components: [
          _c('Shop 20, 4/F', ['subpremise'])
        ], address: 'Level 9, Somewhere'),
        'Shop 20, 4/F',
      );
      expect(
        placeFloorOf(components: const [], address: 'Level 9, Somewhere'),
        'Level 9',
      );
      expect(placeFloorOf(components: const [], address: '12 High St'), '');
      expect(placeFloorOf(components: null, address: null), isNull);
    });
  });
}
