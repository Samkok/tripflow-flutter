import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/utils/arrival_ring.dart';

double _haversineMeters(LatLng a, LatLng b) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180.0;
  final dLat = rad(b.latitude - a.latitude);
  final dLng = rad(b.longitude - a.longitude);
  final s = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(a.latitude)) *
          math.cos(rad(b.latitude)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.atan2(math.sqrt(s), math.sqrt(1 - s));
}

void main() {
  test('every vertex sits on the radius and the ring closes on itself', () {
    const c = LatLng(48.8566, 2.3522);
    final pts = arrivalRingPoints(c, 25);
    expect(pts.length, 37);
    expect(pts.first, pts.last);
    for (final p in pts) {
      expect(_haversineMeters(c, p), closeTo(25, 0.05));
    }
  });

  test('stays round at high latitude', () {
    const tromso = LatLng(69.6492, 18.9553);
    for (final p in arrivalRingPoints(tromso, 50)) {
      expect(_haversineMeters(tromso, p), closeTo(50, 0.1));
    }
  });

  test('segments control the vertex count', () {
    const c = LatLng(0, 0);
    expect(arrivalRingPoints(c, 10, segments: 12).length, 13);
  });

  test('the smallest and largest settings both produce distinct rings', () {
    const c = LatLng(13.7563, 100.5018);
    final small = arrivalRingPoints(c, 10);
    final large = arrivalRingPoints(c, 50);
    expect(_haversineMeters(c, small[9]), closeTo(10, 0.05));
    expect(_haversineMeters(c, large[9]), closeTo(50, 0.05));
  });
}
