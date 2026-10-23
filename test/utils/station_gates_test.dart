import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/utils/station_gates.dart';

void main() {
  group('parseGateInstruction', () {
    test('reads Google\'s exit and entrance steps, first line only', () {
      expect(parseGateInstruction('Take exit A'), (kind: 'exit', label: 'A'));
      expect(parseGateInstruction('Take entrance C1'),
          (kind: 'entrance', label: 'C1'));
      expect(
          parseGateInstruction(
              'take Exit  B2\nDestination will be on the left'),
          (kind: 'exit', label: 'B2'));
    });

    test('ignores ordinary walking instructions', () {
      expect(parseGateInstruction('Head south on Park Promenade'), isNull);
      expect(parseGateInstruction('Turn right'), isNull);
      expect(parseGateInstruction(''), isNull);
      expect(parseGateInstruction(null), isNull);
    });
  });

  // Disneyland Resort station, as the Routes API returned it: the "Take
  // exit A" step runs from the platform to the mouth, and the next step
  // starts 30 m further east, on Park Promenade.
  const platform = LatLng(22.31547, 114.04492);
  const mouth = LatLng(22.31526, 114.04536);
  const front = LatLng(22.31527, 114.04565);

  group('alightingGate', () {
    test('sits at the mouth and points towards where the walk goes on', () {
      final g = alightingGate(
        kind: 'exit',
        label: 'A',
        gateStep: const [platform, mouth],
        nextStep: const [front, LatLng(22.31357, 114.04571)],
      )!;
      expect(g.position, mouth);
      expect(g.front, front);
      expect(g.title, 'Exit A');
      // Due east, give or take the few metres Google rounds to.
      expect(g.headingDeg, closeTo(88, 6));
    });

    test('falls back to the passage out when the next step is far away', () {
      final g = alightingGate(
        kind: 'exit',
        label: 'A',
        gateStep: const [platform, mouth],
        nextStep: const [LatLng(22.3100, 114.0500)], // 600 m off
      )!;
      expect(g.front, mouth);
      expect(g.headingDeg, closeTo(bearingDegrees(platform, mouth), 0.01));
      expect(g.headingDeg, closeTo(117, 6)); // east-south-east
    });

    test('a step with no direction at all yields no gate', () {
      expect(alightingGate(kind: 'exit', label: 'A', gateStep: const [mouth]),
          isNull);
    });
  });

  group('boardingGate', () {
    // Kowloon station: the street walk ends at the mouth of entrance C1,
    // and the entrance step runs mouth → platform.
    const c1Mouth = LatLng(22.30478, 114.16191);
    const c1Platform = LatLng(22.30431, 114.16148);
    const street = LatLng(22.30464, 114.16310);

    test('is oriented OUT of the station, like an exit', () {
      final g = boardingGate(
        kind: 'entrance',
        label: 'C1',
        gateStep: const [c1Mouth, c1Platform],
        prevStep: const [street, c1Mouth],
      )!;
      expect(g.position, c1Mouth);
      expect(g.title, 'Entrance C1');
      // The previous step ends ON the mouth, so the step itself decides:
      // out of the station = platform → mouth, north-east here.
      expect(g.headingDeg, closeTo(bearingDegrees(c1Platform, c1Mouth), 0.01));
      expect(g.headingDeg, inInclusiveRange(0, 90));
    });
  });

  test('toJson round-trips', () {
    final g = alightingGate(
        kind: 'exit',
        label: 'A',
        gateStep: const [platform, mouth],
        nextStep: const [front])!;
    final back = StationGate.fromJson(g.toJson())!;
    expect(back.title, g.title);
    expect(back.position, g.position);
    expect(back.front, g.front);
    expect(back.headingDeg, g.headingDeg);
    expect(StationGate.fromJson({'kind': 'exit'}), isNull);
  });
}
