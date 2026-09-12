import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Vertices of a circle of [radiusMeters] around [center], closed (the last
/// point repeats the first) so a polyline through them reads as a ring.
///
/// Pure arithmetic, no I/O: equirectangular offsets, which at the 10–100 m
/// radii the arrival ring uses are accurate to well under a centimetre —
/// far below a pixel at any zoom. [segments] of 36 is round to the eye at
/// the street zooms where a ring that small is visible at all, and cheap
/// enough to recompute on every position tick.
List<LatLng> arrivalRingPoints(
  LatLng center,
  double radiusMeters, {
  int segments = 36,
}) {
  // 2π·6 371 000 m / 360°: the same mean-Earth sphere as the app's
  // haversine distances, so the drawn ring and the arrival test agree.
  const metersPerDegLat = 111194.9266;
  final cosLat = math.cos(center.latitude * math.pi / 180.0);
  // Guard the poles: never divide by ~0.
  final metersPerDegLng =
      metersPerDegLat * (cosLat.abs() < 1e-6 ? 1e-6 : cosLat);
  final out = <LatLng>[];
  for (var i = 0; i <= segments; i++) {
    // `i % segments` makes the closing vertex bit-identical to the first.
    final theta = 2 * math.pi * (i % segments) / segments;
    out.add(LatLng(
      center.latitude + radiusMeters * math.cos(theta) / metersPerDegLat,
      center.longitude + radiusMeters * math.sin(theta) / metersPerDegLng,
    ));
  }
  return out;
}
