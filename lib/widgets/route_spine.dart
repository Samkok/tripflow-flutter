import 'package:flutter/material.dart';

/// The trip card's signature: a miniature route — dashed line, stop dots,
/// terminal pin — drawn under the trip name. Structure encodes content:
/// [stops] scales with the trip's real place count, so a packed itinerary
/// visibly carries more stops than a fresh one. Cyan when the trip is
/// active; faint ink when idle.
class RouteSpinePainter extends CustomPainter {
  const RouteSpinePainter({
    required this.color,
    required this.stops,
  });

  final Color color;

  /// Number of intermediate stop dots (clamp to taste at the call site).
  final int stops;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final line = Paint()
      ..color = color.withValues(alpha: color.a * 0.7)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final dot = Paint()..color = color;

    // Dashed baseline: 4px dash, 4px gap, ending short of the pin.
    final pinX = size.width - 5;
    var x = 2.0;
    while (x < pinX - 6) {
      canvas.drawLine(
          Offset(x, y), Offset((x + 4).clamp(0, pinX - 6), y), line);
      x += 8;
    }

    // Stop dots, evenly spread along the line (excluding the endpoints).
    final n = stops.clamp(0, 8);
    for (var i = 1; i <= n; i++) {
      final sx = 2 + (pinX - 14) * i / (n + 1);
      canvas.drawCircle(Offset(sx, y), 2.2, dot);
    }

    // Terminal pin: a larger ringed dot — the destination.
    canvas.drawCircle(Offset(pinX, y), 4.2, dot);
    canvas.drawCircle(
      Offset(pinX, y),
      2.0,
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(covariant RouteSpinePainter old) =>
      color != old.color || stops != old.stops;
}
