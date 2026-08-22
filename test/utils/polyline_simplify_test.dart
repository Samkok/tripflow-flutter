import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/utils/polyline_simplify.dart';

void main() {
  test('collinear jitter collapses to its endpoints', () {
    // 200 points along a straight 1 km street with sub-metre GPS wobble.
    final pts = [
      for (var i = 0; i <= 200; i++)
        LatLng(25.04 + i * 0.000045, 121.51 + (i.isEven ? 0.000003 : 0)),
    ];
    final out = simplifyForDisplay(pts, toleranceMeters: 2.5);
    expect(out.first, pts.first);
    expect(out.last, pts.last);
    expect(out.length, lessThan(10), reason: 'wobble is under tolerance');
  });

  test('real corners survive', () {
    // An L-shaped walk: the corner must be kept.
    final pts = [
      for (var i = 0; i <= 50; i++) LatLng(25.04 + i * 0.0001, 121.51),
      for (var i = 1; i <= 50; i++) LatLng(25.045, 121.51 + i * 0.0001),
    ];
    final out = simplifyForDisplay(pts, toleranceMeters: 2.5);
    expect(out.length, 3);
    expect(out[1].latitude, closeTo(25.045, 1e-9));
  });

  test('no point strays more than the tolerance from the thinned line', () {
    final rng = math.Random(7);
    var lat = 25.04, lng = 121.51;
    final pts = <LatLng>[];
    for (var i = 0; i < 400; i++) {
      lat += (rng.nextDouble() - 0.4) * 0.00005;
      lng += (rng.nextDouble() - 0.3) * 0.00005;
      pts.add(LatLng(lat, lng));
    }
    final out = simplifyForDisplay(pts, toleranceMeters: 3);
    expect(out.length, lessThan(pts.length));
    double distM(LatLng a, LatLng b) {
      final c = math.cos(a.latitude * math.pi / 180);
      final dx = (a.longitude - b.longitude) * 111320 * c;
      final dy = (a.latitude - b.latitude) * 111320;
      return math.sqrt(dx * dx + dy * dy);
    }
    for (final p in pts) {
      var best = double.infinity;
      for (var i = 1; i < out.length; i++) {
        for (var t = 0.0; t <= 1.0; t += 0.05) {
          final q = LatLng(
            out[i - 1].latitude + (out[i].latitude - out[i - 1].latitude) * t,
            out[i - 1].longitude +
                (out[i].longitude - out[i - 1].longitude) * t,
          );
          best = math.min(best, distM(p, q));
        }
      }
      expect(best, lessThan(3.5));
    }
  });

  test('memoized per list object; tiny inputs pass through', () {
    final pts = [for (var i = 0; i < 20; i++) LatLng(25.0 + i * 0.001, 121.5)];
    expect(identical(simplifyForDisplay(pts), simplifyForDisplay(pts)), isTrue);
    final two = [const LatLng(1, 1), const LatLng(2, 2)];
    expect(identical(simplifyForDisplay(two), two), isTrue);
  });
}
