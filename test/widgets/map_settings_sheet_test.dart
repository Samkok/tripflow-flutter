import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/providers/debounced_settings_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/widgets/map_settings_sheet.dart';

import '../helpers/pump.dart';

void main() {
  testWidgets('the names switch flips the provider and is remembered',
      (tester) async {
    final prefs = await useMockPrefs();
    final container = await pumpVoyza(tester, const MapSettingsSheetBody());
    await tester.pumpAndSettle();
    expect(container.read(showPlaceNamesProvider), isTrue);

    await tester.tap(find.byKey(const Key('map-settings-place-names')));
    await tester.pumpAndSettle();
    expect(container.read(showPlaceNamesProvider), isFalse);
    expect(prefs.getBool('map_show_place_names'), isFalse);
  });

  testWidgets('a remembered choice is the first frame\'s value',
      (tester) async {
    await useMockPrefs({'map_show_place_names': false});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(showPlaceNamesProvider), isFalse);
  });

  testWidgets('dragging the slider changes the zone distance preview',
      (tester) async {
    await useMockPrefs();
    final container = await pumpVoyza(tester, const MapSettingsSheetBody());
    await tester.pumpAndSettle();
    final before = container.read(proximityThresholdPreviewProvider);

    await tester.drag(find.byKey(const Key('map-settings-zone-slider')),
        const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(container.read(proximityThresholdPreviewProvider),
        isNot(equals(before)));
    // Let any debounce run out so no timer outlives the test.
    await tester.pump(const Duration(seconds: 3));
  });
}
