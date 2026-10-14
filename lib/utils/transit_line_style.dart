import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// One look for a transit line everywhere it appears — the ride polyline,
/// the on-map chip badge, the leg sheet's ride card and route options, and
/// the plan list's rail. The surfaces used to fall back differently when
/// the feed had no colour for a line (red badge over a cyan or green line),
/// which read as two different rides.

/// Google's blue for transit lines that publish no colour of their own —
/// what Google Maps draws for the same ride.
const Color defaultTransitLineColor = Color(0xFF1A73E8);

/// '#RRGGBB' (Routes API transit line colours) → Color; null on any junk.
Color? parseLineColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final cleaned = hex.replaceFirst('#', '');
  if (cleaned.length != 6) return null;
  final value = int.tryParse(cleaned, radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

/// The fill for a ride card / run map (`lineColor`), with the shared
/// fallback.
Color transitLineFill(Map? seg) =>
    parseLineColor(seg?['lineColor'] as String?) ?? defaultTransitLineColor;

/// The feed's text colour for the line's badge, if it publishes one.
Color? transitLineTextColor(Map? seg) =>
    parseLineColor(seg?['lineTextColor'] as String?);

/// Positions of the intermediate stops of a ride, spread evenly by
/// distance along its geometry. The Routes API gives only the number of
/// stops (`stopCount`, which counts the arrival stop), never where they
/// are, so these dots say "N stops" on the map — they are not the stops'
/// true positions. Empty when the ride has no intermediate stop or no
/// usable geometry.
List<LatLng> transitStopDotPositions(List<LatLng> points, int stopCount) {
  final intermediate = stopCount - 1;
  if (intermediate < 1 || points.length < 2) return const [];
  final cum = <double>[0];
  for (var i = 1; i < points.length; i++) {
    cum.add(cum.last + _metersBetween(points[i - 1], points[i]));
  }
  final total = cum.last;
  if (total <= 0) return const [];
  final out = <LatLng>[];
  var seg = 1;
  for (var k = 1; k <= intermediate; k++) {
    final target = total * k / (intermediate + 1);
    while (seg < points.length - 1 && cum[seg] < target) {
      seg++;
    }
    final a = points[seg - 1];
    final b = points[seg];
    final span = cum[seg] - cum[seg - 1];
    final t = span <= 0 ? 0.0 : ((target - cum[seg - 1]) / span).clamp(0, 1);
    out.add(LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    ));
  }
  return out;
}

double _metersBetween(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = (b.latitude - a.latitude) * math.pi / 180;
  final dLng = (b.longitude - a.longitude) * math.pi / 180;
  final la1 = a.latitude * math.pi / 180;
  final la2 = b.latitude * math.pi / 180;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
}

String _stopKey(Map seg) {
  String norm(Object? s) => (s as String? ?? '').trim().toLowerCase();
  return '${norm(seg['boardStop'])}>${norm(seg['alightStop'])}';
}

/// Other lines that serve the same hop as [ride] — same board stop, same
/// alight stop — found among the leg's route [options] (every itinerary
/// Google offered for this leg). Google Maps prints these as "15 or 23";
/// the planner only ever carries the one line of the chosen itinerary, so
/// without this a traveller at the stop would let the other bus go by.
/// Distinct by line number, in the order the options rank, [max] at most,
/// never the ride's own line.
List<Map<String, dynamic>> alternativeLinesFor(
  Map ride,
  List<List<Map<String, dynamic>>?> options, {
  int max = 4,
}) {
  final hop = _stopKey(ride);
  if (hop == '>') return const [];
  final own = ((ride['lineShort'] as String?) ?? '').trim().toLowerCase();
  final seen = <String>{if (own.isNotEmpty) own};
  final out = <Map<String, dynamic>>[];
  for (final segs in options) {
    if (segs == null) continue;
    for (final seg in segs) {
      if (_stopKey(seg) != hop) continue;
      final line = ((seg['lineShort'] as String?) ?? '').trim();
      if (line.isEmpty || !seen.add(line.toLowerCase())) continue;
      out.add(seg);
      if (out.length >= max) return out;
    }
  }
  return out;
}
