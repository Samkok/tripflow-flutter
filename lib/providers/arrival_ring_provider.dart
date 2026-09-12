import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../core/theme.dart';
import '../utils/arrival_ring.dart';
import 'arrival_radius_provider.dart';
import 'trip_provider.dart';

/// The dotted ring around the current-location dot: the arrival radius
/// ([arrivalRadiusProvider]) drawn on the map, so the user can see how
/// close they must get to a stop before the map asks about marking it
/// done. Null while there is no fix.
///
/// Cost model — this must never make the map lag:
///   * re-evaluated only when the position actually changes (the
///     `select` fires per LatLng value, i.e. once per accepted tick, which
///     the ≥3 m jitter filter in updateCurrentLocation already spaces out)
///     or when the setting moves;
///   * an evaluation is 37 sin/cos pairs — microseconds;
///   * the map widget already rebuilds on those same ticks for the
///     current-location marker, so watching this adds no rebuilds, only
///     one small polyline to the native diff (37 points compared by value).
/// Nothing here runs on a timer, touches sensors, or does I/O.
final arrivalRingPolylineProvider = Provider<Polyline?>((ref) {
  final center = ref.watch(tripProvider.select((s) => s.currentLocation));
  if (center == null) return null;
  final radius = ref.watch(arrivalRadiusProvider);
  return Polyline(
    polylineId: const PolylineId('arrival_ring'),
    points: arrivalRingPoints(center, radius),
    color: AppTheme.primaryColor.withValues(alpha: 0.85),
    width: 3,
    patterns: _dottedPattern(radius),
    zIndex: 5,
    consumeTapEvents: false,
  );
});

/// Dotted, so the ring reads as a threshold rather than a drawn route.
///
/// The two platforms measure pattern lengths differently: Android in
/// pixels, iOS in METRES along the line (GMSStyleSpans with
/// kGMSLengthRhumb) — and on iOS a length-less [PatternItem.dot] becomes a
/// zero-length span, i.e. nothing is drawn at all. So Android gets true
/// round dots at a fixed pixel spacing, and iOS gets short dashes cut from
/// the ring's circumference so every ring carries the same number of
/// marks whatever its radius.
List<PatternItem> _dottedPattern(double radiusMeters) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    const marksPerRing = 24;
    final period = 2 * math.pi * radiusMeters / marksPerRing;
    return [PatternItem.dash(period * 0.42), PatternItem.gap(period * 0.58)];
  }
  return [PatternItem.dot, PatternItem.gap(6)];
}
