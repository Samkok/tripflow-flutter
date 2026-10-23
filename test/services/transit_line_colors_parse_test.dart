import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/services/google_maps_service.dart';

/// A transit leg the way the Routes API returns it: walk, one bus, walk.
/// Three points per step; the geometry itself does not matter here.
Map<String, dynamic> _leg(String transitLine) => jsonDecode('''
{
  "steps": [
    {"travelMode": "WALK", "staticDuration": "180s",
     "polyline": {"encodedPolyline": "_p~iF~ps|U_ulLnnqC_mqNvxq`@"}},
    {"travelMode": "TRANSIT", "staticDuration": "660s",
     "polyline": {"encodedPolyline": "_p~iF~ps|U_ulLnnqC_mqNvxq`@"},
     "transitDetails": {
       "headsign": "Central (Macau Ferry)",
       "stopCount": 8,
       "stopDetails": {
         "departureStop": {"name": "Hysan Place; Hennessy Road"},
         "arrivalStop": {"name": "Central Market; Des Voeux Road Central"},
         "departureTime": "2026-10-10T18:37:00Z",
         "arrivalTime": "2026-10-10T18:48:00Z"
       },
       "transitLine": $transitLine
     }},
    {"travelMode": "WALK", "staticDuration": "240s",
     "polyline": {"encodedPolyline": "_p~iF~ps|U_ulLnnqC_mqNvxq`@"}}
  ]
}
''') as Map<String, dynamic>;

void main() {
  // The line badge picks its text colour from these two keys, on the ride
  // card (segments) and on the plan list and map pill (runs) alike.
  test("a line's colour and text colour reach the ride card and the runs", () {
    final leg = _leg('{"nameShort": "N11", "name": "N11", '
        '"color": "#e9f10c", "textColor": "#000000", '
        '"vehicle": {"type": "BUS"}}');

    final ride = GoogleMapsService.extractTransitSegments(leg).single;
    expect(ride['lineShort'], 'N11');
    expect(ride['lineColor'], '#e9f10c');
    expect(ride['lineTextColor'], '#000000');

    final runs = GoogleMapsService.extractStepGeometry(leg);
    expect(runs.map((r) => r['mode']), ['WALK', 'TRANSIT', 'WALK']);
    expect(runs[1]['lineShort'], 'N11');
    expect(runs[1]['lineColor'], '#e9f10c');
    expect(runs[1]['lineTextColor'], '#000000');
    // Walks carry no line identity at all.
    expect(runs[0].containsKey('lineColor'), isFalse);
    expect(runs[0].containsKey('lineTextColor'), isFalse);
  });

  test('a line with no text colour simply leaves the key out', () {
    final leg = _leg('{"nameShort": "N619", "color": "#e60012", '
        '"vehicle": {"type": "BUS"}}');

    expect(
        GoogleMapsService.extractTransitSegments(leg).single['lineTextColor'],
        isNull);
    final ride = GoogleMapsService.extractStepGeometry(leg)[1];
    expect(ride['lineColor'], '#e60012');
    expect(ride.containsKey('lineTextColor'), isFalse);
  });

  test('the line\'s headway reaches the ride card; absent stays absent', () {
    final leg = _leg('{"nameShort": "N11", "color": "#e9f10c", '
        '"vehicle": {"type": "BUS"}}');
    expect(
        GoogleMapsService.extractTransitSegments(leg)
            .single
            .containsKey('headwaySeconds'),
        isFalse);

    final steps = leg['steps'] as List;
    ((steps[1] as Map)['transitDetails'] as Map)['headway'] = '600s';
    expect(
        GoogleMapsService.extractTransitSegments(leg).single['headwaySeconds'],
        600);
  });

  gateTests();
}

/// Kowloon → Disneyland as the Routes API returns it: street walk, "Take
/// entrance C1" into Kowloon, the ride, "Take exit A" out of Disneyland
/// Resort, then the walk on from in front of the exit. Real coordinates,
/// so the gate maths can be checked against the known layout.
Map<String, dynamic> _gatedLeg() {
  String enc(List<List<double>> pts) {
    final sb = StringBuffer();
    var lat = 0, lng = 0;
    void e(int v) {
      v = v < 0 ? ~(v << 1) : (v << 1);
      while (v >= 0x20) {
        sb.writeCharCode((0x20 | (v & 0x1f)) + 63);
        v >>= 5;
      }
      sb.writeCharCode(v + 63);
    }

    for (final p in pts) {
      final la = (p[0] * 1e5).round(), ln = (p[1] * 1e5).round();
      e(la - lat);
      e(ln - lng);
      lat = la;
      lng = ln;
    }
    return sb.toString();
  }

  Map<String, dynamic> walk(String instr, List<List<double>> pts) => {
        'travelMode': 'WALK',
        'staticDuration': '60s',
        'navigationInstruction': {'instructions': instr},
        'polyline': {'encodedPolyline': enc(pts)},
      };
  return {
    'steps': [
      walk('Head west', [
        [22.30464, 114.16310],
        [22.30478, 114.16191]
      ]),
      walk('Take entrance C1', [
        [22.30478, 114.16191],
        [22.30431, 114.16148]
      ]),
      {
        'travelMode': 'TRANSIT',
        'staticDuration': '1500s',
        'polyline': {
          'encodedPolyline': enc([
            [22.30431, 114.16148],
            [22.33207, 114.02907],
            [22.31547, 114.04492]
          ])
        },
        'transitDetails': {
          'headsign': 'Disneyland Resort',
          'stopCount': 2,
          'stopDetails': {
            'departureStop': {'name': 'Kowloon'},
            'arrivalStop': {'name': 'Disneyland Resort Station'},
          },
          'transitLine': {
            'name': 'Disneyland Resort Line',
            'color': '#f173ac',
            'vehicle': {'type': 'SUBWAY'}
          },
        },
      },
      walk('Take exit A', [
        [22.31547, 114.04492],
        [22.31526, 114.04536]
      ]),
      walk('Head south on Park Promenade', [
        [22.31527, 114.04565],
        [22.31357, 114.04571]
      ]),
    ],
  };
}

void gateTests() {
  test('the ride card names the gates it is boarded and left through', () {
    final ride = GoogleMapsService.extractTransitSegments(_gatedLeg()).single;
    final board = ride['boardGate'] as Map;
    final alight = ride['alightGate'] as Map;
    expect(board['kind'], 'entrance');
    expect(board['label'], 'C1');
    expect((board['lat'] as double), closeTo(22.30478, 1e-5));
    expect(alight['kind'], 'exit');
    expect(alight['label'], 'A');
    expect((alight['lat'] as double), closeTo(22.31526, 1e-5));
    expect((alight['lng'] as double), closeTo(114.04536, 1e-5));
    // Out of exit A is east, towards Park Promenade.
    expect(alight['headingDeg'] as double, closeTo(88, 6));
  });

  test(
      'gate steps become runs of their own and the street walk starts at the exit',
      () {
    final runs = GoogleMapsService.extractStepGeometry(_gatedLeg());
    expect(runs.map((r) => r['gate']).toList(),
        [null, 'entrance', null, 'exit', null]);
    expect(runs[1]['gateLabel'], 'C1');
    expect(runs[1]['gateRole'], 'board');
    expect(runs[3]['gateLabel'], 'A');
    expect(runs[3]['gateRole'], 'alight');
    // The approach walk ends ON the entrance mouth…
    final approach = runs[0]['points'] as List;
    expect(approach.last, (runs[1]['points'] as List).first);
    // …and the walk after the ride begins AT the exit mouth, not on the
    // pavement 30 m away where Google starts its next step.
    final street = runs[4]['points'] as List;
    expect(street.first, (runs[3]['points'] as List).last);
    expect(street, hasLength(3));
  });
}
