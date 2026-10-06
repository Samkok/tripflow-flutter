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
}
