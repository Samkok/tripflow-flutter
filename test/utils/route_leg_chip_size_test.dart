import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/utils/marker_utils.dart';

/// Google Maps silently drops marker icons wider than its texture atlas:
/// the marker still takes taps but draws nothing. A transit chip whose
/// badge carried a full route name ("Kennedy Town - Happy Valley") came out
/// 1824 px wide and vanished on both platforms — the "green leg shows no
/// box" bug. Every chip must stay under [MarkerUtils.maxChipPx].
void main() {
  Future<({int width, int height, double? ipr})> raster(
      Future<MarkerBitmapResult> f) async {
    final icon = (await f).bitmap as BytesMapBitmap;
    final codec = await ui.instantiateImageCodec(icon.byteData);
    final frame = await codec.getNextFrame();
    return (
      width: frame.image.width,
      height: frame.image.height,
      ipr: icon.imagePixelRatio
    );
  }

  testWidgets('a ride chip with a long line name stays under the atlas edge',
      (tester) async {
    await tester.runAsync(() async {
      final r = await raster(MarkerUtils.getRouteLegChipMarker(
        distanceLabel: '2.6 km',
        durationLabel: '20 min',
        mode: 'transit',
        vehicleType: 'TRAM',
        badgeText: 'Kennedy Town - Happy Valley',
        badgeColor: const Color(0xFF4CAF50),
        fromName: 'Tonnochy Road',
        toName: 'Man Wa Lane',
      ));
      expect(r.width, lessThanOrEqualTo(MarkerUtils.maxChipPx));
      expect(r.ipr, lessThanOrEqualTo(3.0));
    });
  });

  testWidgets('absurdly long endpoint names fall back to a lower pixel ratio',
      (tester) async {
    await tester.runAsync(() async {
      final r = await raster(MarkerUtils.getRouteLegChipMarker(
        distanceLabel: '12.6 km',
        durationLabel: '1h 20m',
        mode: 'transit',
        vehicleType: 'BUS',
        badgeText: 'Hong Kong International Airport Express Shuttle A21X',
        badgeColor: const Color(0xFFE53935),
        fromName: 'Hong Kong Convention and Exhibition Centre',
        toName: 'Hong Kong International Airport Terminal 1',
      ));
      expect(r.width, lessThanOrEqualTo(MarkerUtils.maxChipPx));
      expect(r.ipr, lessThanOrEqualTo(3.0));
    });
  });

  testWidgets('a plain drive chip is unchanged', (tester) async {
    await tester.runAsync(() async {
      final r = await raster(MarkerUtils.getRouteLegChipMarker(
        distanceLabel: '4.4 km',
        durationLabel: '12 min',
        mode: 'drive',
        fromName: 'The Charterhouse Causeway Bay Hotel',
        toName: 'Sang Kee Congee Shop',
      ));
      expect(r.width, lessThanOrEqualTo(MarkerUtils.maxChipPx));
      expect(r.ipr, 3.0);
    });
  });
}
