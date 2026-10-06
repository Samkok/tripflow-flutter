import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/widgets/leg_rail.dart';

/// The plan list's line badge is filled with the line's own colour. Its
/// label was always white, so a yellow line (Hong Kong's N11) showed a
/// blank yellow box. These tests read the label's colour off the widget.
void main() {
  LocationModel place(String id) => LocationModel(
        id: id,
        name: id,
        address: '',
        coordinates: const LatLng(22.28, 114.18),
        addedAt: DateTime(2026),
      );

  /// A walk → ride → walk transit leg whose ride is [ride].
  Widget rail(Map<String, dynamic> ride) {
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: LegRail(
            legIndex: 0,
            from: place('a'),
            to: place('b'),
            legData: {
              'mode': 'transit',
              'distance': 3700.0,
              'duration': const Duration(minutes: 18),
              'transitSteps': [
                const {'mode': 'WALK', 'durationSeconds': 180},
                {'mode': 'TRANSIT', 'durationSeconds': 660, ...ride},
                const {'mode': 'WALK', 'durationSeconds': 240},
              ],
            },
          ),
        ),
      ),
    );
  }

  Color? labelColor(WidgetTester tester, String label) =>
      tester.widget<Text>(find.text(label)).style?.color;

  testWidgets('a yellow line is labelled in black', (tester) async {
    await tester.pumpWidget(rail({'lineShort': 'N11', 'lineColor': '#e9f10c'}));
    expect(labelColor(tester, 'N11'), Colors.black);
  });

  testWidgets('a red line is still labelled in white', (tester) async {
    await tester
        .pumpWidget(rail({'lineShort': 'N619', 'lineColor': '#e60012'}));
    expect(labelColor(tester, 'N619'), Colors.white);
  });

  testWidgets("the feed's navy is kept on a yellow line", (tester) async {
    await tester.pumpWidget(rail({
      'lineShort': 'Circle',
      'lineColor': '#ffd300',
      'lineTextColor': '#113b92',
    }));
    expect(labelColor(tester, 'Circle'), const Color(0xFF113B92));
  });

  testWidgets('black from a blank feed does not darken a red line',
      (tester) async {
    await tester.pumpWidget(rail({
      'lineShort': 'N680',
      'lineColor': '#e60012',
      'lineTextColor': '#000000',
    }));
    expect(labelColor(tester, 'N680'), Colors.white);
  });

  testWidgets('a line with no colour sits on the app cyan, in black',
      (tester) async {
    await tester.pumpWidget(rail({'lineShort': '87'}));
    expect(labelColor(tester, '87'), Colors.black);
  });
}
