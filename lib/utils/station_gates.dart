import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A station's way in or out, as Google's walking steps describe it. "Take
/// exit A" / "Take entrance C1" is a step of its own — platform to the exit
/// mouth after a ride, mouth to the platform before one — and the street
/// walk continues from a point in front of the mouth. That geometry is the
/// one accurate source for where the gate is and which way it faces; it is
/// what the map's exit symbols and the walking legs are built from.
class StationGate {
  const StationGate({
    required this.kind,
    required this.label,
    required this.position,
    required this.front,
    required this.headingDeg,
  });

  /// Google's own word: "exit" or "entrance" (Hong Kong says "exit" for
  /// both directions; the sign on the street is what the traveller reads).
  final String kind;

  /// "A", "C1", "M8"…
  final String label;

  /// The mouth of the gate — where the symbol sits.
  final LatLng position;

  /// Where the street walk starts (after a ride) or ends (before one); the
  /// mouth itself when Google gave no separate point.
  final LatLng front;

  /// The way OUT of the station, degrees clockwise from north — the
  /// direction a traveller faces stepping onto the street. Entrances use
  /// the same convention so every gate on the map reads alike.
  final double headingDeg;

  bool get isExit => kind == 'exit';

  /// "Exit A", "Entrance C1".
  String get title => '${isExit ? 'Exit' : 'Entrance'} $label';

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'label': label,
        'lat': position.latitude,
        'lng': position.longitude,
        'frontLat': front.latitude,
        'frontLng': front.longitude,
        'headingDeg': headingDeg,
      };

  static StationGate? fromJson(Object? raw) {
    if (raw is StationGate) return raw;
    if (raw is! Map) return null;
    final kind = raw['kind'] as String?;
    final label = raw['label'] as String?;
    final lat = (raw['lat'] as num?)?.toDouble();
    final lng = (raw['lng'] as num?)?.toDouble();
    final heading = (raw['headingDeg'] as num?)?.toDouble();
    if (kind == null || label == null || lat == null || lng == null) {
      return null;
    }
    if (heading == null) return null;
    final frontLat = (raw['frontLat'] as num?)?.toDouble() ?? lat;
    final frontLng = (raw['frontLng'] as num?)?.toDouble() ?? lng;
    return StationGate(
      kind: kind,
      label: label,
      position: LatLng(lat, lng),
      front: LatLng(frontLat, frontLng),
      headingDeg: heading,
    );
  }
}

/// ("exit", "A") from "Take exit A"; null for any other instruction. Only
/// the first line counts ("Take exit A\nDestination will be on the left").
({String kind, String label})? parseGateInstruction(String? instructions) {
  if (instructions == null) return null;
  final first = instructions.split('\n').first.trim();
  final m = RegExp(r'^take\s+(exit|entrance)\s+(.+)$', caseSensitive: false)
      .firstMatch(first);
  if (m == null) return null;
  final label = m.group(2)!.trim();
  if (label.isEmpty) return null;
  return (kind: m.group(1)!.toLowerCase(), label: label);
}

/// Degrees clockwise from north, [a] → [b], in [0, 360).
double bearingDegrees(LatLng a, LatLng b) {
  final lat1 = _rad(a.latitude);
  final lat2 = _rad(b.latitude);
  final dLng = _rad(b.longitude - a.longitude);
  final y = math.sin(dLng) * math.cos(lat2);
  final x = math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
  final deg = math.atan2(y, x) * 180 / math.pi;
  return (deg + 360) % 360;
}

/// Great-circle distance in metres.
double metersBetween(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = _rad(b.latitude - a.latitude);
  final dLng = _rad(b.longitude - a.longitude);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(a.latitude)) *
          math.cos(_rad(b.latitude)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(h)));
}

double _rad(double deg) => deg * math.pi / 180;

/// Farther than this and the neighbouring step did not start (or end) in
/// front of the gate: Google skipped the forecourt, and that step's first
/// stretch says nothing about the gate's own direction.
const double gateFrontMaxMeters = 60;

/// Closer than this and the two points are the same spot: no direction in
/// them, fall back to the gate step itself.
const double gateFrontMinMeters = 3;

/// The gate a ride is LEFT through: [gateStep] runs platform → mouth. The
/// arrow points where the walk goes on — towards [nextStep]'s start when it
/// begins in front of the mouth, else along the step's last stretch (the
/// passage out of the station).
StationGate? alightingGate({
  required String kind,
  required String label,
  required List<LatLng> gateStep,
  List<LatLng>? nextStep,
}) {
  if (gateStep.isEmpty) return null;
  final mouth = gateStep.last;
  final candidate =
      (nextStep != null && nextStep.isNotEmpty) ? nextStep.first : null;
  final picked = _frontAndHeading(mouth, candidate);
  final heading = picked.heading ?? _bearingIntoEnd(gateStep);
  if (heading == null) return null;
  return StationGate(
    kind: kind,
    label: label,
    position: mouth,
    front: picked.front ?? mouth,
    headingDeg: heading,
  );
}

/// The gate a ride is BOARDED through: [gateStep] runs mouth → platform.
/// Still oriented outwards (towards [prevStep]'s end, where the traveller
/// came from on the street), so entrances and exits read the same way.
StationGate? boardingGate({
  required String kind,
  required String label,
  required List<LatLng> gateStep,
  List<LatLng>? prevStep,
}) {
  if (gateStep.isEmpty) return null;
  final mouth = gateStep.first;
  final candidate =
      (prevStep != null && prevStep.isNotEmpty) ? prevStep.last : null;
  final picked = _frontAndHeading(mouth, candidate);
  final heading = picked.heading ?? _bearingOutOfStart(gateStep);
  if (heading == null) return null;
  return StationGate(
    kind: kind,
    label: label,
    position: mouth,
    front: picked.front ?? mouth,
    headingDeg: heading,
  );
}

({LatLng? front, double? heading}) _frontAndHeading(
    LatLng mouth, LatLng? candidate) {
  if (candidate == null) return (front: null, heading: null);
  final d = metersBetween(mouth, candidate);
  if (d > gateFrontMaxMeters) return (front: null, heading: null);
  if (d < gateFrontMinMeters) return (front: candidate, heading: null);
  return (front: candidate, heading: bearingDegrees(mouth, candidate));
}

/// Bearing of the stretch that ARRIVES at the last point (platform → mouth
/// direction for an exit step), skipping repeated points.
double? _bearingIntoEnd(List<LatLng> pts) {
  final end = pts.last;
  for (var i = pts.length - 2; i >= 0; i--) {
    if (metersBetween(pts[i], end) >= 1) return bearingDegrees(pts[i], end);
  }
  return null;
}

/// Bearing from the second distinct point BACK to the first — the way out
/// through an entrance step that runs mouth → platform.
double? _bearingOutOfStart(List<LatLng> pts) {
  final start = pts.first;
  for (var i = 1; i < pts.length; i++) {
    if (metersBetween(start, pts[i]) >= 1) return bearingDegrees(pts[i], start);
  }
  return null;
}

/// How big a gate's symbol is ON THE GROUND. The symbols are ground
/// overlays, not markers: a fixed footprint in metres, so they are specks
/// from afar and only read once the traveller zooms in to the station —
/// the way the exit signs themselves work. Canvas heights, badge bitmap
/// (30 pt tall → the badge itself ≈ 10 m) and arrow bitmap (76 pt square,
/// arrow tip ≈ 16 m from the mouth).
const double gateBadgeGroundMeters = 14;
const double gateArrowGroundMeters = 35.5;

/// A box of [widthMeters] × [heightMeters] centred on [center], as the
/// bounds a ground overlay is stretched to.
LatLngBounds gateGroundBounds(
  LatLng center, {
  required double widthMeters,
  required double heightMeters,
}) {
  const metersPerDegLat = 111320.0;
  final metersPerDegLng = metersPerDegLat * math.cos(_rad(center.latitude));
  final dLat = heightMeters / 2 / metersPerDegLat;
  final dLng = widthMeters / 2 / math.max(metersPerDegLng, 1e-6);
  return LatLngBounds(
    southwest: LatLng(center.latitude - dLat, center.longitude - dLng),
    northeast: LatLng(center.latitude + dLat, center.longitude + dLng),
  );
}
