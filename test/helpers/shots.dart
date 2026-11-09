// Exporting what a widget test rendered, for an eye-check without a device.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Writes the [RepaintBoundary] under [boundaryKey] to [path] as a PNG.
/// Creates the directory. Call after `pumpAndSettle`.
Future<void> exportShot(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String path, {
  double pixelRatio = 2,
}) async {
  await tester.runAsync(() async {
    final boundary = boundaryKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(png!.buffer.asUint8List());
  });
}
