import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/utils/transit_line_style.dart';

void main() {
  group('transit line colour', () {
    test('the feed colour wins, junk and absence fall back to the one blue',
        () {
      expect(
          transitLineFill({'lineColor': '#266b5c'}), const Color(0xFF266B5C));
      expect(transitLineFill({'lineColor': ''}), defaultTransitLineColor);
      expect(transitLineFill({'lineColor': '#26'}), defaultTransitLineColor);
      expect(transitLineFill({}), defaultTransitLineColor);
      expect(transitLineFill(null), defaultTransitLineColor);
      expect(transitLineTextColor({'lineTextColor': '#ffffff'}),
          const Color(0xFFFFFFFF));
      expect(transitLineTextColor({}), isNull);
    });
  });

  group('transitStopDotPositions', () {
    const a = LatLng(22.2800, 114.1600);
    const b = LatLng(22.2800, 114.1700); // ~1 km east
    const c = LatLng(22.2900, 114.1700); // ~1.1 km north

    test('one dot per intermediate stop, spread by distance', () {
      // stopCount counts the arrival stop → 3 stops = 2 intermediate dots.
      final dots = transitStopDotPositions([a, b, c], 3);
      expect(dots, hasLength(2));
      // Total ≈ 2.1 km: the first third lands on the eastward segment, the
      // second on the northward one — neither at a vertex.
      expect(dots[0].latitude, closeTo(22.2800, 1e-6));
      expect(dots[0].longitude, greaterThan(114.1600));
      expect(dots[0].longitude, lessThan(114.1700));
      expect(dots[1].longitude, closeTo(114.1700, 1e-6));
      expect(dots[1].latitude, greaterThan(22.2800));
      expect(dots[1].latitude, lessThan(22.2900));
    });

    test('a direct ride, an unknown count or no geometry gives none', () {
      expect(transitStopDotPositions([a, b], 1), isEmpty);
      expect(transitStopDotPositions([a, b], 0), isEmpty);
      expect(transitStopDotPositions([a], 5), isEmpty);
      expect(transitStopDotPositions([a, a], 5), isEmpty);
    });
  });

  group('alternativeLinesFor', () {
    final ride = {
      'lineShort': '15',
      'boardStop': 'Central (Exchange Square)',
      'alightStop': 'The Peak',
    };
    final options = <List<Map<String, dynamic>>?>[
      // The applied itinerary itself: its own line must not be listed.
      [ride],
      [
        {
          'lineShort': '15B',
          'boardStop': 'Central (Exchange Square) ',
          'alightStop': 'the peak',
        }
      ],
      // Same line, different hop: not this ride's alternative.
      [
        {'lineShort': '1', 'boardStop': 'Admiralty', 'alightStop': 'The Peak'}
      ],
      // A tram ride with no number: nothing to print.
      [
        {
          'lineShort': '',
          'boardStop': 'Central (Exchange Square)',
          'alightStop': 'The Peak',
        }
      ],
      null,
      [
        {
          'lineShort': 'X15',
          'boardStop': 'Central (Exchange Square)',
          'alightStop': 'The Peak',
        },
        {
          'lineShort': '15b',
          'boardStop': 'Central (Exchange Square)',
          'alightStop': 'The Peak',
        },
      ],
    ];

    test('lists the other lines on the same hop, once each, in rank order', () {
      final others = alternativeLinesFor(ride, options);
      expect(others.map((o) => o['lineShort']), ['15B', 'X15']);
    });

    test('is capped and needs a hop to match', () {
      expect(alternativeLinesFor(ride, options, max: 1), hasLength(1));
      expect(alternativeLinesFor({'lineShort': '15'}, options), isEmpty);
    });
  });
}
