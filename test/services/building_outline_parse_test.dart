import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/services/building_outline_service.dart';

Map<String, dynamic> _square(double lat, double lng, {double size = 0.001}) => {
      'type': 'Polygon',
      'coordinates': [
        [
          [lng, lat],
          [lng + size, lat],
          [lng + size, lat + size],
          [lng, lat + size],
          [lng, lat],
        ],
      ],
    };

void main() {
  group('parseBuildingOutline', () {
    test('a place that is its own building: the primary footprint', () {
      final out = parseBuildingOutline('ChIJa', {
        'destinations': [
          {
            'primary': {
              'structureType': 'BUILDING',
              'displayPolygon': _square(35.0, 139.0),
            },
            'entrances': [
              {
                'location': {'latitude': 35.0005, 'longitude': 139.0},
                'tags': ['PREFERRED'],
              },
            ],
          },
        ],
      });
      expect(out, isNotNull);
      expect(out!.rings, hasLength(1));
      expect(out.rings.first.first, const LatLng(35.0, 139.0));
      expect(out.rings.first, hasLength(5));
      expect(out.entrances, [const LatLng(35.0005, 139.0)]);
    });

    test('a shop inside a mall: the containing building', () {
      final out = parseBuildingOutline('ChIJb', {
        'destinations': [
          {
            'primary': {'structureType': 'POINT'},
            'containingPlaces': [
              {
                'structureType': 'GROUNDS',
                'displayPolygon': _square(10.0, 10.0, size: 0.01),
              },
              {
                'structureType': 'BUILDING',
                'displayPolygon': _square(10.001, 10.001),
              },
            ],
          },
        ],
      });
      expect(out!.rings.first.first, const LatLng(10.001, 10.001),
          reason: 'the building wins over the grounds');
      expect(out.entrances, isEmpty);
    });

    test('a multi-building place keeps every outer ring', () {
      final out = parseBuildingOutline('ChIJc', {
        'destinations': [
          {
            'primary': {
              'structureType': 'BUILDING',
              'displayPolygon': {
                'type': 'MultiPolygon',
                'coordinates': [
                  _square(1.0, 1.0)['coordinates'],
                  _square(2.0, 2.0)['coordinates'],
                ],
              },
            },
          },
        ],
      });
      expect(out!.rings, hasLength(2));
    });

    test('nothing with a footprint: null', () {
      expect(
        parseBuildingOutline('ChIJd', {
          'destinations': [
            {
              'primary': {'structureType': 'POINT'},
              'containingPlaces': [
                {'structureType': 'SECTION'},
              ],
            },
          ],
        }),
        isNull,
      );
      expect(parseBuildingOutline('ChIJe', {'destinations': []}), isNull);
      expect(parseBuildingOutline('ChIJf', {}), isNull);
    });

    test('degenerate rings are dropped', () {
      final out = parseBuildingOutline('ChIJg', {
        'destinations': [
          {
            'primary': {
              'structureType': 'BUILDING',
              'displayPolygon': {
                'type': 'Polygon',
                'coordinates': [
                  [
                    [1.0, 1.0],
                    [1.0, 1.0],
                  ],
                ],
              },
            },
          },
        ],
      });
      expect(out, isNull);
    });
  });
}
