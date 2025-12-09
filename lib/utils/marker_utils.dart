import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class MarkerBitmapResult {
  final BitmapDescriptor bitmap;
  final Offset anchor;

  MarkerBitmapResult(this.bitmap, this.anchor);
}

class MarkerUtils {
  /// Creates a custom bitmap for the user's current location.
  /// It's designed to look like the pulsing blue dot in Google Maps.
  static Future<BitmapDescriptor> getCurrentLocationMarker({
    double size = 40, // The total size of the bitmap (including glow)
    Color backgroundColor = const Color(0xFF4285F4), // Google Blue
  }) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint corePaint = Paint()..color = backgroundColor;
    final Paint glowPaint = Paint()
      ..color = backgroundColor.withValues(alpha: 0.3);
    final Paint whiteRingPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;

    final double center = size / 2;
    final double glowRadius = size / 2;
    final double coreRadius = size / 5; // The inner blue dot
    final double whiteRingRadius = coreRadius + 2.0;

    // Draw the outer glow
    canvas.drawCircle(Offset(center, center), glowRadius, glowPaint);

    // Draw the white ring around the core
    canvas.drawCircle(Offset(center, center), whiteRingRadius, whiteRingPaint);

    // Draw the inner core
    canvas.drawCircle(Offset(center, center), coreRadius, corePaint);

    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage(size.toInt(), size.toInt());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);

    if (data == null) {
      // Fallback to a default marker if bitmap creation fails
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
    }

    return BitmapDescriptor.bytes(data.buffer.asUint8List());
  }

  /// Creates a custom bitmap for a destination marker (e.g., a flag).
  static Future<BitmapDescriptor> getDestinationMarkerBitmap({
    Color color = Colors.red,
    double size = 30.0,
  }) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint = Paint()..color = color;

    final Path path = Path();
    // Simple flag shape
    path.moveTo(size * 0.1, size * 0.9); // Bottom of pole
    path.lineTo(size * 0.1, size * 0.1); // Top of pole
    path.lineTo(size * 0.7, size * 0.1); // Top-right of flag
    path.lineTo(size * 0.5, size * 0.3); // Mid-point of flag
    path.lineTo(size * 0.7, size * 0.5); // Bottom-right of flag
    path.lineTo(size * 0.1, size * 0.5); // Bottom-left of flag (back to pole)
    path.close();

    canvas.drawPath(path, paint);

    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage(size.toInt(), size.toInt());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);

    if (data == null) {
      // Fallback to a default marker if bitmap creation fails
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
    }

    return BitmapDescriptor.bytes(data.buffer.asUint8List());
  }

  /// Creates a custom bitmap with a number and a name.
  /// Returns a [MarkerBitmapResult] containing the bitmap and the correct anchor
  /// to align the circle center with the map coordinate.
  static Future<MarkerBitmapResult> getCustomMarkerBitmap({
    required int number,
    required String name,
    Color backgroundColor = Colors.red,
    Color textColor = Colors.white,
    required bool isDarkMode,
    bool isStart = false,
    double size = 20,
    bool isSkipped = false, // Add this parameter
  }) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();

    // --- 1. Configure Text Painters ---
    // Painter for the number inside the circle or the skipped icon
    TextPainter contentPainter = TextPainter(textDirection: TextDirection.ltr);

    if (isStart) {
      contentPainter.text = TextSpan(
        text: String.fromCharCode(Icons.flag_rounded.codePoint),
        style: TextStyle(
          fontSize: size * 0.6,
          fontFamily: Icons.flag_rounded.fontFamily,
          color: textColor,
        ),
      );
    } else if (isSkipped) {
      contentPainter.text = TextSpan(
        text: String.fromCharCode(Icons.remove_circle_outline.codePoint),
        style: TextStyle(
          fontSize: size * 0.5, // Keep similar size to number
          fontFamily: Icons.remove_circle_outline.fontFamily,
          color: textColor, // Use textColor for the icon
        ),
      );
    } else {
      contentPainter.text = TextSpan(
        text: number.toString(),
        style: TextStyle(
          fontSize: size * 0.5,
          fontWeight: FontWeight.bold,
          color: textColor,
        ),
      );
    }
    contentPainter.layout();

    // Painter for the location name below the circle
    TextPainter namePainter = TextPainter(
        textDirection: TextDirection.ltr, maxLines: 2, ellipsis: '...');
    namePainter.text = TextSpan(
      text: name,
      style: TextStyle(
        fontSize: 14, // Reduced to 14
        fontWeight: FontWeight.w600,
        color: isDarkMode ? Colors.white : Colors.black,
        shadows: [
          Shadow(
              color: isDarkMode
                  ? Colors.black.withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.7),
              blurRadius: 2,
              offset: const Offset(0, 0))
        ],
      ),
    );
    // Layout the name with a max width to allow wrapping
    namePainter.layout(maxWidth: size * 2.5);

    // --- 2. Calculate Canvas Dimensions ---
    final double circleRadius = size / 2;
    final double paddingBelowCircle = 12.0;
    final double totalWidth =
        namePainter.width > size ? namePainter.width : size;
    final double totalHeight = size + paddingBelowCircle + namePainter.height;
    final double canvasCenterX = totalWidth / 2;

    final Canvas canvas = Canvas(pictureRecorder);

    // --- 3. Draw the Elements ---
    // Apply grayscale filter if skipped
    if (isSkipped) {
      final ColorFilter greyscaleFilter = ColorFilter.matrix(<double>[
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]);
      canvas.saveLayer(null, Paint()..colorFilter = greyscaleFilter);
    }

    // Draw the circle
    final Paint circlePaint = Paint()
      ..color = isStart ? Colors.green.shade600 : backgroundColor;

    canvas.drawCircle(
        Offset(canvasCenterX, circleRadius), circleRadius, circlePaint);

    // Draw the number inside the circle
    contentPainter.paint(
      canvas,
      Offset(
        canvasCenterX - contentPainter.width / 2,
        circleRadius - contentPainter.height / 2,
      ),
    );

    // Draw the name below the circle
    namePainter.paint(
      canvas,
      Offset(canvasCenterX - namePainter.width / 2, size + paddingBelowCircle),
    );

    // --- 4. Convert to Bitmap ---
    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage(totalWidth.toInt(), totalHeight.toInt());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);

    if (data == null) {
      return MarkerBitmapResult(
          BitmapDescriptor.defaultMarker, const Offset(0.5, 1.0));
    }

    final double anchorX = canvasCenterX / totalWidth;
    final double anchorY = (size / 2) / totalHeight;

    return MarkerBitmapResult(
      BitmapDescriptor.bytes(data.buffer.asUint8List()),
      Offset(anchorX, anchorY),
    );
  }

  /// Creates a 'Open Google Maps' button marker
  static Future<MarkerBitmapResult> getGoogleMapsButtonMarker() async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    const double padding = 8.0;
    const double height = 28.0;

    // Paints
    final Paint buttonPaint = Paint()
      ..color = const Color(0xFF4285F4) // Google Blue
      ..style = PaintingStyle.fill;

    // Text "Open Maps"
    final TextPainter textPainter = TextPainter(
      text: const TextSpan(
        text: 'OPEN MAPS',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    // Icon
    const IconData iconData = Icons.directions;
    final TextPainter iconPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(iconData.codePoint),
        style: TextStyle(
          fontSize: 14,
          fontFamily: iconData.fontFamily,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    iconPainter.layout();

    final double contentWidth = iconPainter.width + 4 + textPainter.width;
    final double totalWidth = padding * 2 + contentWidth;
    final double totalHeight = height;

    // Draw Shadow
    final RRect shadowRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 2, totalWidth, totalHeight),
      const Radius.circular(14),
    );
    canvas.drawShadow(Path()..addRRect(shadowRRect),
        Colors.black.withOpacity(0.3), 4.0, true);

    // Draw Button
    final RRect buttonRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, totalWidth, totalHeight),
      const Radius.circular(14),
    );
    canvas.drawRRect(buttonRRect, buttonPaint);

    // Draw Content
    final double contentStartX = padding;
    final double contentStartY = (totalHeight - iconPainter.height) / 2;

    iconPainter.paint(canvas, Offset(contentStartX, contentStartY));

    final double textStartY = (totalHeight - textPainter.height) / 2;
    textPainter.paint(
        canvas, Offset(contentStartX + iconPainter.width + 4, textStartY));

    // Convert
    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage(totalWidth.toInt(), (totalHeight + 4).toInt());

    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);

    if (data == null) {
      return MarkerBitmapResult(
          BitmapDescriptor.defaultMarker, const Offset(0.5, 0.5));
    }

    return MarkerBitmapResult(BitmapDescriptor.bytes(data.buffer.asUint8List()),
        const Offset(0.5, 0.5));
  }

  /// Creates a custom bitmap for leg start/end markers.
  static Future<BitmapDescriptor> getLegMarkerBitmap({
    required Color color,
    required IconData icon,
    double size = 40,
  }) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final double radius = size / 2;

    // Draw circle background
    final Paint paint = Paint()..color = color;
    canvas.drawCircle(Offset(radius, radius), radius, paint);

    // Draw icon
    TextPainter iconPainter = TextPainter(textDirection: TextDirection.ltr);
    iconPainter.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: radius,
        fontFamily: icon.fontFamily,
        color: Colors.white,
      ),
    );
    iconPainter.layout();
    iconPainter.paint(
      canvas,
      Offset(radius - iconPainter.width / 2, radius - iconPainter.height / 2),
    );

    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage(size.toInt(), size.toInt());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);

    if (data == null) {
      return BitmapDescriptor.defaultMarker;
    }

    return BitmapDescriptor.bytes(data.buffer.asUint8List());
  }

  /// Creates a custom bitmap for displaying route info (duration and distance).
  static Future<BitmapDescriptor> getRouteInfoMarker({
    required String duration,
    required String distance,
    bool isHighlighted = false,
    Color backgroundColor = const Color(0xFF1A1A2E),
    Color primaryColor = Colors.blue,
    Color accentColor = Colors.red,
  }) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    final TextPainter durationPainter = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
              text: '⏱ ', style: TextStyle(color: primaryColor, fontSize: 12)),
          TextSpan(
              text: duration,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
        ],
      ),
      textDirection: TextDirection.ltr,
    );
    durationPainter.layout();

    final TextPainter distancePainter = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
              text: '📏 ', style: TextStyle(color: accentColor, fontSize: 12)),
          TextSpan(
              text: distance,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
        ],
      ),
      textDirection: TextDirection.ltr,
    );
    distancePainter.layout();

    final double padding = 12.0;
    final double separatorWidth = 2.0;
    final double separatorPadding = 16.0;
    final double totalWidth = durationPainter.width +
        distancePainter.width +
        (padding * 2) +
        separatorWidth +
        (separatorPadding * 2);
    final double totalHeight = durationPainter.height + (padding * 2);

    final RRect backgroundRRect = RRect.fromLTRBR(
      0,
      0,
      totalWidth,
      totalHeight,
      const Radius.circular(24),
    );

    // Draw background
    final Paint backgroundPaint = Paint()
      ..color = backgroundColor.withValues(alpha: 0.8);
    canvas.drawRRect(backgroundRRect, backgroundPaint);

    // Draw border
    final Paint borderPaint = Paint()
      ..color =
          isHighlighted ? primaryColor : primaryColor.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRRect(backgroundRRect, borderPaint);

    // Draw duration
    durationPainter.paint(canvas, Offset(padding, padding));

    // Draw separator
    final double separatorX =
        padding + durationPainter.width + separatorPadding;
    final Paint separatorPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..strokeWidth = separatorWidth;
    canvas.drawLine(Offset(separatorX, padding / 2),
        Offset(separatorX, totalHeight - padding / 2), separatorPaint);

    // Draw distance
    distancePainter.paint(
        canvas, Offset(separatorX + separatorPadding, padding));

    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage(totalWidth.toInt(), totalHeight.toInt());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);

    if (data == null) {
      return BitmapDescriptor.defaultMarker;
    }

    return BitmapDescriptor.bytes(data.buffer.asUint8List());
  }
}

/// This is a placeholder for the existing marker generation logic.
/// In a real scenario, other marker generation functions like
/// `createNumberedMarkerBitmap` would also be in this file.
/// For this request, we are only adding the current location marker logic.

/*
Example of another function that would live here:

static Future<BitmapDescriptor> createNumberedMarkerBitmap({
  required int number,
  required Color backgroundColor,
  required Color textColor,
  double size = 100,
}) async {
  final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(pictureRecorder);
  final Paint paint = Paint()..color = backgroundColor;
  final double radius = size / 2;

  canvas.drawCircle(
    Offset(radius, radius),
    radius,
    paint,
  );

  TextPainter painter = TextPainter(textDirection: TextDirection.ltr);
  painter.text = TextSpan(
    text: number.toString(),
    style: TextStyle(
      fontSize: radius,
      fontWeight: FontWeight.bold,
      color: textColor,
    ),
  );

  painter.layout();
  painter.paint(
    canvas,
    Offset(
      radius - painter.width / 2,
      radius - painter.height / 2,
    ),
  );

  final img = await pictureRecorder.endRecording().toImage(
        size.toInt(),
        size.toInt(),
      );
  final data = await img.toByteData(format: ui.ImageByteFormat.png);

  if (data == null) {
    return BitmapDescriptor.defaultMarker;
  }

  return BitmapDescriptor.bytes(data.buffer.asUint8List());
}
*/
