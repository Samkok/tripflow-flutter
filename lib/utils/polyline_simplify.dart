import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Display-only polyline simplification (Douglas–Peucker, iterative).
///
/// Google returns road geometry at full density — hundreds of vertices per
/// kilometre on a winding walk. The map SDK processes every vertex on every
/// zoom frame, and for PATTERNED (dashed) lines it also re-cuts dashes
/// along the whole path per frame, so vertex count is a direct cost. A
/// 2.5 m tolerance drops 60–80 % of vertices with no visible change at any
/// planning zoom. Routing, ETAs and the share card keep the raw geometry —
/// only what's handed to the map is thinned.
///
/// Results are memoized per input LIST OBJECT (an [Expando]): leg polyline
/// lists are stable in TripState between optimizes, so each leg is
/// simplified once, not on every overlay rebuild.
final Expando<List<LatLng>> _simplifiedCache = Expando('simplifiedPolyline');

List<LatLng> simplifyForDisplay(List<LatLng> points,
    {double toleranceMeters = 2.5}) {
  if (points.length < 3) return points;
  final cached = _simplifiedCache[points];
  if (cached != null) return cached;
  final out = _douglasPeucker(points, toleranceMeters);
  _simplifiedCache[points] = out;
  return out;
}

List<LatLng> _douglasPeucker(List<LatLng> pts, double toleranceMeters) {
  // Equirectangular projection to metres around the path's mean latitude:
  // exact enough for a city-scale tolerance and far cheaper than haversine
  // per segment.
  final lat0 = pts.map((p) => p.latitude).reduce((a, b) => a + b) / pts.length;
  final cosLat = math.cos(lat0 * math.pi / 180);
  const mPerDeg = 111320.0;
  final xs = List<double>.generate(
      pts.length, (i) => pts[i].longitude * mPerDeg * cosLat);
  final ys = List<double>.generate(pts.length, (i) => pts[i].latitude * mPerDeg);

  final keep = List<bool>.filled(pts.length, false);
  keep[0] = true;
  keep[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  final tol2 = toleranceMeters * toleranceMeters;

  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    if (b - a < 2) continue;
    final ax = xs[a], ay = ys[a], bx = xs[b], by = ys[b];
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var maxD2 = -1.0;
    var maxI = -1;
    for (var i = a + 1; i < b; i++) {
      final px = xs[i] - ax, py = ys[i] - ay;
      double d2;
      if (len2 == 0) {
        d2 = px * px + py * py;
      } else {
        // Perpendicular distance² to the chord (clamped to the segment).
        var t = (px * dx + py * dy) / len2;
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        final ex = px - t * dx, ey = py - t * dy;
        d2 = ex * ex + ey * ey;
      }
      if (d2 > maxD2) {
        maxD2 = d2;
        maxI = i;
      }
    }
    if (maxD2 > tol2 && maxI != -1) {
      keep[maxI] = true;
      stack.add((a, maxI));
      stack.add((maxI, b));
    }
  }
  return [for (var i = 0; i < pts.length; i++) if (keep[i]) pts[i]];
}
