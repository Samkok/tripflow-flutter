import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/services/route_share_card_service.dart';

/// Renders the realistic map card over a synthetic "map" image so the
/// compositing (cover-fit, scrim, headline, stats, wordmark) can be inspected
/// without a device. Outputs land in build/qa_shots/.
/// The real map tiles are supplied on-device by GoogleMapController.takeSnapshot.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A fake map: gradient + grid + a fake route line, so cover-fit + scrim show.
  Future<Uint8List> fakeMap() async {
    const w = 900.0, h = 1600.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(
      const Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(w, h),
            const [Color(0xFF16233A), Color(0xFF0E1726)]),
    );
    final grid = Paint()
      ..color = const Color(0x22FFFFFF)
      ..strokeWidth = 2;
    for (var x = 0.0; x < w; x += 90) {
      c.drawLine(Offset(x, 0), Offset(x, h), grid);
    }
    for (var y = 0.0; y < h; y += 90) {
      c.drawLine(Offset(0, y), Offset(w, y), grid);
    }
    c.drawPath(
      Path()
        ..moveTo(150, 300)
        ..lineTo(600, 500)
        ..lineTo(300, 900)
        ..lineTo(700, 1200),
      Paint()
        ..color = const Color(0xFF00D4FF)
        ..strokeWidth = 12
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
    final mapImg = await rec.endRecording().toImage(w.toInt(), h.toInt());
    return (await mapImg.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
  }

  Future<void> expect9x16(Uint8List png) async {
    final decoded = await ui.instantiateImageCodec(png);
    final frame = await decoded.getNextFrame();
    expect(frame.image.width, 1080);
    expect(frame.image.height, 1920);
  }

  test('renderMapCard composites branding over a map image (route mode)',
      () async {
    final png = await RouteShareCardService.instance.renderMapCard(
      mapBytes: await fakeMap(),
      tripName: 'Lisbon',
      stops: 6,
      timeSaved: const Duration(minutes: 24),
      distanceKm: 20.8,
    );

    expect(png, isNotNull, reason: 'renderMapCard should produce PNG bytes');
    Directory('build/qa_shots').createSync(recursive: true);
    File('build/qa_shots/map_card_preview.png').writeAsBytesSync(png!);
    await expect9x16(png);
  });

  test('renderMapCard draws the Plan Card identity layer (plan mode)', () async {
    // archetype -> headline, trip name -> kicker, roast -> under the stats.
    final png = await RouteShareCardService.instance.renderMapCard(
      mapBytes: await fakeMap(),
      tripName: 'Lisbon',
      stops: 6,
      timeSaved: const Duration(minutes: 24),
      distanceKm: 20.8,
      archetype: 'THE TASTE ROUTER',
      roastLine: 'This itinerary has been legally un-zig-zagged.',
    );

    expect(png, isNotNull, reason: 'plan-mode card should produce PNG bytes');
    Directory('build/qa_shots').createSync(recursive: true);
    File('build/qa_shots/plan_map_card_preview.png').writeAsBytesSync(png!);
    await expect9x16(png);
  });
}
