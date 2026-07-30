import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import 'package:voyza/widgets/globe_land_mask.dart';

/// A slowly rotating monochrome wireframe globe — blurred, low-contrast —
/// meant to sit BEHIND screen content as ambient decoration. Draws only
/// with the theme's neutral tone so it never competes with foreground
/// components.
class RotatingGlobeBackground extends StatefulWidget {
  const RotatingGlobeBackground({super.key, this.animate = true});

  /// Pause the rotation while the hosting tab is offstage. IndexedStack keeps
  /// offstage children alive, so without this the ticker would burn frames
  /// forever while the user is on another tab.
  final bool animate;

  @override
  State<RotatingGlobeBackground> createState() =>
      _RotatingGlobeBackgroundState();
}

class _RotatingGlobeBackgroundState extends State<RotatingGlobeBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // One full revolution per 75 s — motion you notice, not motion you watch.
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 75));
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant RotatingGlobeBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.animate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lineColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFF17263C).withValues(alpha: 0.06);
    final landColor = isDark
        ? Colors.white.withValues(alpha: 0.16)
        : const Color(0xFF17263C).withValues(alpha: 0.12);

    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: _GlobePainter(
              rotation: _controller.value * 2 * math.pi,
              color: lineColor,
              landColor: landColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _GlobePainter extends CustomPainter {
  _GlobePainter({
    required this.rotation,
    required this.color,
    required this.landColor,
  });

  final double rotation;
  final Color color;
  final Color landColor;

  /// Axial tilt (~23°, like Earth's) so the spin reads as 3D rather than a
  /// flat wheel.
  static const double _tilt = 0.40;

  @override
  void paint(Canvas canvas, Size size) {
    // 60% of the full-bleed radius — the sphere reads as an object floating
    // behind the content, its limb visible on screen.
    final center = size.center(Offset.zero);
    final radius =
        math.sqrt(size.width * size.width + size.height * size.height) /
            2 *
            0.61;

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);

    // Limb (the sphere's outline) — back on screen at this size.
    canvas.drawCircle(center, radius, grid);

    // Meridians — these carry the visible rotation.
    for (var lon = 0; lon < 360; lon += 30) {
      _drawSphericalCurve(canvas, center, radius, grid, (t) {
        return (-90 + 180 * t, lon.toDouble());
      });
    }
    // Parallels — static rings that give the sphere its volume.
    for (final lat in const [-60.0, -30.0, 0.0, 30.0, 60.0]) {
      _drawSphericalCurve(canvas, center, radius, grid, (t) => (lat, 360 * t));
    }

    _drawContinents(canvas, center, radius);
  }

  /// Dot-matrix continents from the baked 3° Natural Earth land mask. All
  /// front-facing dots go out in a single drawPoints call.
  void _drawContinents(Canvas canvas, Offset center, double radius) {
    final dots = <Offset>[];
    for (var row = 0; row < kGlobeLandMask3Deg.length; row++) {
      final line = kGlobeLandMask3Deg[row];
      final lat = 87.0 - 3.0 * row;
      for (var col = 0; col < line.length; col++) {
        if (line.codeUnitAt(col) != 0x31) continue; // '1' = land
        final lon = -178.5 + 3.0 * col;
        final p = _project(lat, lon, radius);
        if (p != null) dots.add(center + p);
      }
    }
    final dotPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.5
      ..strokeCap = StrokeCap.round
      ..color = landColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6);
    canvas.drawPoints(PointMode.points, dots, dotPaint);
  }

  /// Samples a lat/lon curve and draws only its camera-facing segments.
  void _drawSphericalCurve(Canvas canvas, Offset center, double radius,
      Paint paint, (double, double) Function(double t) curve) {
    const steps = 144;
    final path = Path();
    var penDown = false;
    for (var i = 0; i <= steps; i++) {
      final (lat, lon) = curve(i / steps);
      final p = _project(lat, lon, radius);
      if (p == null) {
        penDown = false;
        continue;
      }
      final o = center + p;
      if (penDown) {
        path.lineTo(o.dx, o.dy);
      } else {
        path.moveTo(o.dx, o.dy);
        penDown = true;
      }
    }
    canvas.drawPath(path, paint);
  }

  /// Lat/lon (degrees) → orthographic screen offset from the globe centre,
  /// or null when the point sits on the far hemisphere.
  Offset? _project(double latDeg, double lonDeg, double radius) {
    final lat = latDeg * math.pi / 180;
    // Spin happens around the sphere's own polar axis, THEN the whole
    // sphere is tilted — so the poles stay put while the grid turns.
    final lon = lonDeg * math.pi / 180 + rotation;
    final x = math.cos(lat) * math.sin(lon);
    final y = math.sin(lat);
    final z = math.cos(lat) * math.cos(lon);
    final yT = y * math.cos(_tilt) - z * math.sin(_tilt);
    final zT = y * math.sin(_tilt) + z * math.cos(_tilt);
    if (zT < 0) return null;
    return Offset(x * radius, -yT * radius);
  }

  @override
  bool shouldRepaint(_GlobePainter oldDelegate) =>
      oldDelegate.rotation != rotation ||
      oldDelegate.color != color ||
      oldDelegate.landColor != landColor;
}
