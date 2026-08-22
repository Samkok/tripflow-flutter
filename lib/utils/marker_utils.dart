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
    double size = 30, // The total size of the bitmap (including glow)
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

  /// The current-location dot with Google-Maps-style heading beam: the same
  /// dot as [getCurrentLocationMarker] (identical pixel geometry, so swapping
  /// variants never changes the dot's size) plus a translucent wedge pointing
  /// "up" in bitmap space. The wedge is aimed by the Marker's `rotation`
  /// property (platform-side, cheap) — this bitmap itself is static and
  /// rendered exactly once.
  static Future<BitmapDescriptor> getCurrentLocationHeadingMarker({
    double dotSize = 30, // matches getCurrentLocationMarker's size
    Color backgroundColor = const Color(0xFF4285F4),
  }) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    const double canvasSize = 76;
    const double center = canvasSize / 2;
    const double beamRadius = center - 2;
    const Offset c = Offset(center, center);

    // Beam: a 52° wedge from the dot center, fading radially outward.
    const double halfAngleRad = 26 * 3.1415926535 / 180;
    const double upRad = -3.1415926535 / 2; // pointing up (north in bitmap)
    final Paint beamPaint = Paint()
      ..shader = ui.Gradient.radial(
        c,
        beamRadius,
        [
          backgroundColor.withValues(alpha: 0.42),
          backgroundColor.withValues(alpha: 0.0),
        ],
        [0.18, 1.0],
      );
    final Path beamPath = Path()
      ..moveTo(c.dx, c.dy)
      ..arcTo(
        Rect.fromCircle(center: c, radius: beamRadius),
        upRad - halfAngleRad,
        2 * halfAngleRad,
        false,
      )
      ..close();
    canvas.drawPath(beamPath, beamPaint);

    // Dot layers — same paints/radii as getCurrentLocationMarker.
    final Paint corePaint = Paint()..color = backgroundColor;
    final Paint glowPaint = Paint()
      ..color = backgroundColor.withValues(alpha: 0.3);
    final Paint whiteRingPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;
    final double glowRadius = dotSize / 2;
    final double coreRadius = dotSize / 5;
    final double whiteRingRadius = coreRadius + 2.0;
    canvas.drawCircle(c, glowRadius, glowPaint);
    canvas.drawCircle(c, whiteRingRadius, whiteRingPaint);
    canvas.drawCircle(c, coreRadius, corePaint);

    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage(canvasSize.toInt(), canvasSize.toInt());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);

    if (data == null) {
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
    }
    return BitmapDescriptor.bytes(data.buffer.asUint8List());
  }

  /// Creates a custom bitmap for a destination marker (e.g., a flag).
  static Future<BitmapDescriptor> getDestinationMarkerBitmap({
    Color color = Colors.red,
    double size = 20.0,
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
  /// Amber used for "might be closed" pins and their warning line — the
  /// same amber the Unscheduled bucket and the planner warnings use.
  static const Color warningAmber = Color(0xFFFFB300);

  static Future<MarkerBitmapResult> getCustomMarkerBitmap({
    required int number,
    required String name,
    Color backgroundColor = Colors.red,
    Color textColor = Colors.white,
    required bool isDarkMode,
    bool isStart = false,
    double size = 20,
    bool isSkipped = false,
    bool isDone = false,
    // Optional amber caution line drawn under the name (e.g. "might be
    // closed on this date"). Wraps to two lines like the name.
    String? warningLine,
  }) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();

    // Render at the DEVICE pixel ratio: these bitmaps were drawn 1:1 in
    // logical pixels (20px circle, 12px label) and Google Maps upscaled
    // them ~3x on modern phones — the "blurry name" effect. The canvas is
    // scaled so every measurement below stays in logical units; the PNG is
    // physically dpr× larger and imagePixelRatio tells the map its true
    // density.
    final double dpr = (WidgetsBinding
                .instance.platformDispatcher.implicitView?.devicePixelRatio ??
            3.0)
        .clamp(1.0, 4.0);

    // --- 1. Configure Text Painters ---
    // Painter for the number inside the circle or the skipped icon
    TextPainter contentPainter = TextPainter(textDirection: TextDirection.ltr);

    if (isStart) {
      contentPainter.text = TextSpan(
        text: String.fromCharCode(Icons.flag_rounded.codePoint),
        style: TextStyle(
          fontSize: size * 0.55,
          fontFamily: Icons.flag_rounded.fontFamily,
          color: textColor,
        ),
      );
    } else if (isDone) {
      contentPainter.text = TextSpan(
        text: String.fromCharCode(Icons.check.codePoint),
        style: TextStyle(
          fontSize: size * 0.6,
          fontFamily: Icons.check.fontFamily,
          color: textColor,
        ),
      );
    } else if (isSkipped) {
      contentPainter.text = TextSpan(
        text: String.fromCharCode(Icons.remove_circle_outline.codePoint),
        style: TextStyle(
          fontSize: size * 0.5,
          fontFamily: Icons.remove_circle_outline.fontFamily,
          color: textColor,
        ),
      );
    } else {
      contentPainter.text = TextSpan(
        text: number.toString(),
        style: TextStyle(
          fontSize: size * 0.5,
          fontWeight: FontWeight.w900, // Extra bold for better readability
          color: textColor,
        ),
      );
    }
    contentPainter.layout();

    // Painter for the location name below the circle. Full name up to 50
    // characters (the old 60px wrap width truncated almost everything to
    // "Hong Kong In..."), centered across up to two lines.
    final displayName =
        name.length > 50 ? '${name.substring(0, 50).trimRight()}…' : name;
    TextPainter namePainter = TextPainter(
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 2,
        ellipsis: '...');
    namePainter.text = TextSpan(
      text: displayName,
      style: TextStyle(
        fontSize: 12, // Increased from 14 for better readability
        fontWeight: FontWeight.w700, // Bolder for better visibility
        color: isDarkMode ? Colors.white : Colors.black87,
        shadows: [
          // Multiple shadows for crisp text outline
          Shadow(
              color: isDarkMode
                  ? Colors.black.withValues(alpha: 0.9)
                  : Colors.white.withValues(alpha: 0.95),
              blurRadius: 3,
              offset: const Offset(0, 0)),
          Shadow(
              color: isDarkMode
                  ? Colors.black.withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.8),
              blurRadius: 6,
              offset: const Offset(0, 1)),
        ],
      ),
    );
    // Wide enough that ~25 characters fit per line — 50-char names wrap
    // onto two lines instead of vanishing into an ellipsis.
    namePainter.layout(maxWidth: 170);

    // Optional caution line under the name, amber with the same halo so
    // it stays legible over any map tile.
    TextPainter? warningPainter;
    if (warningLine != null && warningLine.trim().isNotEmpty) {
      warningPainter = TextPainter(
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          maxLines: 2,
          ellipsis: '...');
      warningPainter.text = TextSpan(
        text: warningLine,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: warningAmber,
          shadows: [
            Shadow(
                color: isDarkMode
                    ? Colors.black.withValues(alpha: 0.9)
                    : Colors.white.withValues(alpha: 0.95),
                blurRadius: 3,
                offset: const Offset(0, 0)),
            Shadow(
                color: isDarkMode
                    ? Colors.black.withValues(alpha: 0.7)
                    : Colors.white.withValues(alpha: 0.8),
                blurRadius: 6,
                offset: const Offset(0, 1)),
          ],
        ),
      );
      warningPainter.layout(maxWidth: 170);
    }
    const double warningGap = 2.0;
    final double warningHeight =
        warningPainter == null ? 0 : warningPainter.height + warningGap;

    // --- 2. Calculate Canvas Dimensions ---
    final double circleRadius = size / 2;
    const double shadowRadius = 4.0; // Shadow offset
    const double paddingBelowCircle = 16.0; // Increased padding
    final double textWidth = warningPainter == null
        ? namePainter.width
        : (warningPainter.width > namePainter.width
            ? warningPainter.width
            : namePainter.width);
    final double totalWidth = textWidth > size ? textWidth : size;
    final double totalHeight = size +
        paddingBelowCircle +
        namePainter.height +
        warningHeight +
        shadowRadius;
    final double canvasCenterX = totalWidth / 2;

    final Canvas canvas = Canvas(pictureRecorder);
    canvas.scale(dpr);

    // --- 3. Draw the Elements ---

    // Apply grayscale filter if skipped
    if (isSkipped) {
      const ColorFilter greyscaleFilter = ColorFilter.matrix(<double>[
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

    // Draw shadow for depth (multiple layers for softer shadow)
    final Paint shadowPaint1 = Paint()
      ..color = Colors.black.withValues(alpha: 0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final Paint shadowPaint2 = Paint()
      ..color = Colors.black.withValues(alpha: 0.1)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    canvas.drawCircle(Offset(canvasCenterX, circleRadius + 2), circleRadius + 1,
        shadowPaint2);
    canvas.drawCircle(
        Offset(canvasCenterX, circleRadius + 1), circleRadius, shadowPaint1);

    // Draw white border/stroke for better contrast
    final Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawCircle(
        Offset(canvasCenterX, circleRadius), circleRadius, borderPaint);

    // Draw the main circle with gradient effect
    final Paint circlePaint = Paint()
      ..color = isStart
          ? Colors.green.shade600
          : (isDone ? Colors.green.shade500 : backgroundColor)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(
        Offset(canvasCenterX, circleRadius), circleRadius - 1.5, circlePaint);

    // Draw inner highlight for 3D effect
    final Paint highlightPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

    canvas.drawCircle(Offset(canvasCenterX, circleRadius - circleRadius * 0.3),
        circleRadius * 0.4, highlightPaint);

    // Draw the number/icon inside the circle
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
    // …and the caution line under the name.
    if (warningPainter != null) {
      warningPainter.paint(
        canvas,
        Offset(canvasCenterX - warningPainter.width / 2,
            size + paddingBelowCircle + namePainter.height + warningGap),
      );
    }

    // --- 4. Convert to Bitmap ---
    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage((totalWidth * dpr).round(), (totalHeight * dpr).round());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);

    if (data == null) {
      return MarkerBitmapResult(
          BitmapDescriptor.defaultMarker, const Offset(0.5, 1.0));
    }

    final double anchorX = canvasCenterX / totalWidth;
    final double anchorY = (size / 2) / totalHeight;

    return MarkerBitmapResult(
      BitmapDescriptor.bytes(
        data.buffer.asUint8List(),
        imagePixelRatio: dpr,
      ),
      Offset(anchorX, anchorY),
    );
  }

  /// Creates a combined distance label + Open Maps button as one bitmap.
  /// Draws: [ distance chip ] on top, [ OPEN MAPS button ] below, with a gap.
  /// Anchor is set to bottom-center so the whole stack sits above the midpoint.
  /// Single compact leg chip drawn ON the route line:
  ///   [car icon]  4.4 km · 12 min  (>)
  ///
  /// Replaces the old stacked distance-chip + OPEN MAPS button pair, which
  /// buried the very polyline the user tapped. Tapping this opens the leg
  /// sheet (see showRouteLegSheet) where the actions live.
  ///
  /// Rendered at device pixel ratio and handed to the map with a matching
  /// imagePixelRatio, so the text stays crisp instead of being upscaled.
  /// Mode → chip glyph. Transit gets a vehicle-specific glyph so a Venice
  /// vaporetto reads as a boat, not a bus.
  static IconData legModeIcon(String mode, {String? vehicleType}) {
    switch (mode) {
      case 'walk':
        return Icons.directions_walk_rounded;
      case 'bicycle':
        return Icons.directions_bike_rounded;
      case 'two_wheeler':
        return Icons.two_wheeler_rounded;
      case 'direct':
        return Icons.multiple_stop_rounded;
      case 'transit':
        switch (vehicleType) {
          case 'FERRY':
            return Icons.directions_boat_rounded;
          case 'HEAVY_RAIL':
          case 'COMMUTER_TRAIN':
          case 'LONG_DISTANCE_TRAIN':
          case 'HIGH_SPEED_TRAIN':
            return Icons.train_rounded;
          case 'SUBWAY':
          case 'METRO_RAIL':
            return Icons.subway_rounded;
          case 'TRAM':
          case 'LIGHT_RAIL':
            return Icons.tram_rounded;
          default:
            return Icons.directions_bus_rounded;
        }
      default:
        return Icons.directions_car_rounded;
    }
  }

  /// Google-style leg endpoint "collar": a small white dot with a soft dark
  /// ring, placed where legs begin/end and where transit journeys change
  /// vehicle (board/alight junctions). Static bitmap, rendered once.
  static Future<MarkerBitmapResult> getLegEndpointDotMarker() async {
    final double dpr = (WidgetsBinding
                .instance.platformDispatcher.implicitView?.devicePixelRatio ??
            3.0)
        .clamp(1.0, 4.0);
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    canvas.scale(dpr);

    const double d = 14;
    const Offset c = Offset(d / 2, d / 2);
    canvas.drawCircle(
        c, 6.4, Paint()..color = const Color(0xCC33404F)); // soft ring
    canvas.drawCircle(c, 4.6, Paint()..color = Colors.white);

    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage((d * dpr).round(), (d * dpr).round());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      return MarkerBitmapResult(
          BitmapDescriptor.defaultMarker, const Offset(0.5, 0.5));
    }
    return MarkerBitmapResult(
      BitmapDescriptor.bytes(data.buffer.asUint8List(), imagePixelRatio: dpr),
      const Offset(0.5, 0.5),
    );
  }

  static Future<MarkerBitmapResult> getRouteLegChipMarker({
    required String distanceLabel,
    String? durationLabel,
    String mode = 'drive',
    String? vehicleType,
    String? badgeText,
    Color? badgeColor,
    // Endpoint names — when provided, a second smaller line "A → B" renders
    // under the stats row so the chip says WHERE the leg goes, not just how
    // far. Long names are trimmed per side so both ends always survive.
    String? fromName,
    String? toName,
  }) async {
    final double dpr = (WidgetsBinding
                .instance.platformDispatcher.implicitView?.devicePixelRatio ??
            3.0)
        .clamp(1.0, 4.0);

    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    canvas.scale(dpr);

    const double hPad = 11.0;
    const double vPad = 8.0;
    const double gap = 6.0;
    const double chevronDiameter = 22.0;
    const double shadowExtra = 5.0;
    const Color cyan = Color(0xFF00D4FF);

    final IconData modeIcon = legModeIcon(mode, vehicleType: vehicleType);
    final iconPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(modeIcon.codePoint),
        style: TextStyle(
            fontSize: 15, fontFamily: modeIcon.fontFamily, color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Transit line badge — the "[2]" in Google's itinerary rows, drawn in
    // the line's official color right after the vehicle glyph.
    final bool hasBadge = badgeText != null && badgeText.isNotEmpty;
    final TextPainter? badgePainter = !hasBadge
        ? null
        : (TextPainter(
            text: TextSpan(
              text: badgeText,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800),
            ),
            textDirection: TextDirection.ltr,
          )..layout());
    const double badgeHPad = 6.0;
    final double badgeWidth =
        badgePainter == null ? 0 : badgePainter.width + badgeHPad * 2;

    // "4.4 km · 12 min" — the middle dot is dropped when the route service
    // gave us no duration for this leg.
    final label = (durationLabel == null || durationLabel.isEmpty)
        ? distanceLabel
        : '$distanceLabel · $durationLabel';
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
            color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const IconData chevronIcon = Icons.chevron_right_rounded;
    final chevronPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(chevronIcon.codePoint),
        style: TextStyle(
            fontSize: 17,
            fontFamily: chevronIcon.fontFamily,
            color: const Color(0xFF17263C)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // "From → To" endpoint line — quieter than the stats row (smaller, and
    // dimmed) so it reads as context, not competition. Each name is trimmed
    // on its own so a long "from" can never push the "to" out of the chip.
    String trimName(String s) => s.length > 18 ? '${s.substring(0, 17)}…' : s;
    final bool hasRouteLine = (fromName != null && fromName.isNotEmpty) ||
        (toName != null && toName.isNotEmpty);
    final TextPainter? routePainter = !hasRouteLine
        ? null
        : (TextPainter(
            text: TextSpan(
              text: '${trimName(fromName ?? '')} → ${trimName(toName ?? '')}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.78),
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.1,
              ),
            ),
            maxLines: 1,
            ellipsis: '…',
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: 230));
    const double routeLineGap = 3.0;

    final double contentHeight = [
      iconPainter.height,
      textPainter.height,
      chevronDiameter,
    ].reduce((a, b) => a > b ? a : b);
    final double chipHeight = vPad +
        contentHeight +
        (routePainter == null ? 0 : routeLineGap + routePainter.height) +
        vPad;
    final double mainRowWidth = hPad +
        iconPainter.width +
        gap +
        (badgePainter == null ? 0 : badgeWidth + gap) +
        textPainter.width +
        gap +
        chevronDiameter +
        hPad;
    final double chipWidth = routePainter == null
        ? mainRowWidth
        : (routePainter.width + hPad * 2 > mainRowWidth
            ? routePainter.width + hPad * 2
            : mainRowWidth);
    final double totalHeight = chipHeight + shadowExtra;

    final chipRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, chipWidth, chipHeight),
      Radius.circular(chipHeight / 2),
    );

    canvas.drawShadow(
      Path()
        ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 2, chipWidth, chipHeight),
          Radius.circular(chipHeight / 2),
        )),
      Colors.black.withValues(alpha: 0.45),
      4.0,
      true,
    );
    // Near-opaque navy so the label stays readable over any map tile.
    canvas.drawRRect(chipRect, Paint()..color = const Color(0xF01B2A3F));
    canvas.drawRRect(
      chipRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = cyan.withValues(alpha: 0.45),
    );

    // Main row is vertically centred in its own band (the top row) so the
    // endpoint line below never shifts it; horizontally centred in case the
    // endpoint line came out wider than the stats row.
    final double rowMid = vPad + contentHeight / 2;
    double x = hPad + (chipWidth - mainRowWidth) / 2;
    iconPainter.paint(canvas, Offset(x, rowMid - iconPainter.height / 2));
    x += iconPainter.width + gap;
    if (badgePainter != null) {
      final badgeHeight = badgePainter.height + 4;
      final badgeRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, rowMid - badgeHeight / 2, badgeWidth, badgeHeight),
        const Radius.circular(5),
      );
      canvas.drawRRect(
          badgeRect, Paint()..color = badgeColor ?? const Color(0xFFE53935));
      badgePainter.paint(
          canvas, Offset(x + badgeHPad, rowMid - badgePainter.height / 2));
      x += badgeWidth + gap;
    }
    textPainter.paint(canvas, Offset(x, rowMid - textPainter.height / 2));
    x += textPainter.width + gap;

    // Cyan affordance dot — signals "there is more behind this".
    canvas.drawCircle(
      Offset(x + chevronDiameter / 2, rowMid),
      chevronDiameter / 2,
      Paint()..color = cyan,
    );
    chevronPainter.paint(
      canvas,
      Offset(
        x + (chevronDiameter - chevronPainter.width) / 2,
        rowMid - chevronPainter.height / 2,
      ),
    );

    // Endpoint line, centred under the stats row.
    routePainter?.paint(
      canvas,
      Offset(
        (chipWidth - routePainter.width) / 2,
        vPad + contentHeight + routeLineGap,
      ),
    );

    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage((chipWidth * dpr).round(), (totalHeight * dpr).round());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      return MarkerBitmapResult(
          BitmapDescriptor.defaultMarker, const Offset(0.5, 0.5));
    }

    // Centred on the leg midpoint so the chip straddles the polyline.
    return MarkerBitmapResult(
      BitmapDescriptor.bytes(data.buffer.asUint8List(), imagePixelRatio: dpr),
      const Offset(0.5, 0.5),
    );
  }

  static Future<MarkerBitmapResult> getDistanceAndMapsMarker(
      String distanceLabel) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    const double hPad = 10.0;
    const double vPad = 5.0;
    const double btnHeight = 28.0;
    const double btnHPad = 8.0;
    const double gap = 6.0;
    const double shadowExtra = 4.0;

    // --- Distance label painters ---
    final distText = TextPainter(
      text: TextSpan(
        text: distanceLabel,
        style: const TextStyle(
            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final double chipHeight = vPad * 2 + distText.height;

    // --- Open Maps button painters ---
    const IconData mapsIcon = Icons.directions;
    final mapsIconPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(mapsIcon.codePoint),
        style: TextStyle(
            fontSize: 14, fontFamily: mapsIcon.fontFamily, color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final mapsTextPainter = TextPainter(
      text: const TextSpan(
        text: 'OPEN MAPS',
        style: TextStyle(
            color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final double btnContentWidth =
        mapsIconPainter.width + 4 + mapsTextPainter.width;
    final double btnWidth = btnHPad * 2 + btnContentWidth;

    // Canvas width = widest of the two elements
    final double chipWidth = hPad * 2 + distText.width;
    final double totalWidth = chipWidth > btnWidth ? chipWidth : btnWidth;
    final double totalHeight = chipHeight + gap + btnHeight + shadowExtra;

    // --- Draw distance chip ---
    canvas.drawShadow(
      Path()
        ..addRRect(RRect.fromRectAndRadius(
            Rect.fromLTWH(
                (totalWidth - chipWidth) / 2, 2, chipWidth, chipHeight),
            const Radius.circular(12))),
      Colors.black.withValues(alpha: 0.35),
      3.0,
      true,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH((totalWidth - chipWidth) / 2, 0, chipWidth, chipHeight),
          const Radius.circular(12)),
      Paint()..color = const Color(0xDD1A1A2E),
    );
    distText.paint(
      canvas,
      Offset((totalWidth - distText.width) / 2, vPad),
    );

    // --- Draw Open Maps button ---
    final double btnTop = chipHeight + gap;
    final double btnLeft = (totalWidth - btnWidth) / 2;
    canvas.drawShadow(
      Path()
        ..addRRect(RRect.fromRectAndRadius(
            Rect.fromLTWH(btnLeft, btnTop + 2, btnWidth, btnHeight),
            const Radius.circular(14))),
      Colors.black.withValues(alpha: 0.3),
      4.0,
      true,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(btnLeft, btnTop, btnWidth, btnHeight),
          const Radius.circular(14)),
      Paint()..color = const Color(0xFF4285F4),
    );
    final double contentStartX = btnLeft + (btnWidth - btnContentWidth) / 2;
    mapsIconPainter.paint(
        canvas,
        Offset(
            contentStartX, btnTop + (btnHeight - mapsIconPainter.height) / 2));
    mapsTextPainter.paint(
        canvas,
        Offset(contentStartX + mapsIconPainter.width + 4,
            btnTop + (btnHeight - mapsTextPainter.height) / 2));

    // --- Convert ---
    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage(totalWidth.toInt(), totalHeight.toInt());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);

    if (data == null) {
      return MarkerBitmapResult(
          BitmapDescriptor.defaultMarker, const Offset(0.5, 1.0));
    }

    // Anchor at bottom-center so the entire stack renders above the map position
    return MarkerBitmapResult(
      BitmapDescriptor.bytes(data.buffer.asUint8List()),
      const Offset(0.5, 1.0),
    );
  }

  /// Creates the 'OPEN GRAB' button marker
  static Future<MarkerBitmapResult> getGrabButtonMarker() async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    const double padding = 8.0;
    const double height = 28.0;

    const IconData grabIcon = Icons.local_taxi;
    final iconPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(grabIcon.codePoint),
        style: TextStyle(
            fontSize: 14, fontFamily: grabIcon.fontFamily, color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'OPEN GRAB',
        style: TextStyle(
            color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final double contentWidth = iconPainter.width + 4 + textPainter.width;
    final double totalWidth = padding * 2 + contentWidth;

    canvas.drawShadow(
      Path()
        ..addRRect(RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 2, totalWidth, height),
            const Radius.circular(14))),
      Colors.black.withValues(alpha: 0.3),
      4.0,
      true,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, totalWidth, height), const Radius.circular(14)),
      Paint()..color = const Color(0xFF00B14F),
    );

    final double startX = (totalWidth - contentWidth) / 2;
    iconPainter.paint(
        canvas, Offset(startX, (height - iconPainter.height) / 2));
    textPainter.paint(
        canvas,
        Offset(
            startX + iconPainter.width + 4, (height - textPainter.height) / 2));

    final ui.Image img = await pictureRecorder
        .endRecording()
        .toImage(totalWidth.toInt(), (height + 4).toInt());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);

    if (data == null) {
      return MarkerBitmapResult(
          BitmapDescriptor.defaultMarker, const Offset(0.5, 0.5));
    }

    // Anchor at top-center so it renders below the map position
    return MarkerBitmapResult(BitmapDescriptor.bytes(data.buffer.asUint8List()),
        const Offset(0.5, 0.0));
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

    const double padding = 12.0;
    const double separatorWidth = 2.0;
    const double separatorPadding = 16.0;
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
    durationPainter.paint(canvas, const Offset(padding, padding));

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
