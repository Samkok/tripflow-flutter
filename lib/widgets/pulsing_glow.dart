import 'package:flutter/material.dart';

/// A softly pulsing colored halo drawn behind [child] to make a primary
/// affordance impossible to miss — e.g. the share-route FAB. Circular by
/// default (sized to a FAB); pass [shape]/[borderRadius] for a rounded rect.
///
/// Runs its own ticker, so the animation only lives while the widget is
/// mounted (the glow appears/stops with the affordance it decorates).
class PulsingGlow extends StatefulWidget {
  final Widget child;
  final Color glowColor;
  final BoxShape shape;
  final BorderRadius? borderRadius;
  final double minBlur;
  final double maxBlur;
  final double maxSpread;
  final double minAlpha;
  final double maxAlpha;
  final Duration period;

  const PulsingGlow({
    super.key,
    required this.child,
    required this.glowColor,
    this.shape = BoxShape.circle,
    this.borderRadius,
    this.minBlur = 10,
    this.maxBlur = 34,
    this.maxSpread = 7,
    this.minAlpha = 0.45,
    this.maxAlpha = 0.95,
    this.period = const Duration(milliseconds: 1250),
  });

  @override
  State<PulsingGlow> createState() => _PulsingGlowState();
}

class _PulsingGlowState extends State<PulsingGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.period)
      ..repeat(reverse: true);
    _glow = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blurSpan = widget.maxBlur - widget.minBlur;
    final alphaSpan = widget.maxAlpha - widget.minAlpha;
    return AnimatedBuilder(
      animation: _glow,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          shape: widget.shape,
          borderRadius:
              widget.shape == BoxShape.rectangle ? widget.borderRadius : null,
          boxShadow: [
            BoxShadow(
              color: widget.glowColor
                  .withValues(alpha: widget.minAlpha + _glow.value * alphaSpan),
              blurRadius: widget.minBlur + _glow.value * blurSpan,
              spreadRadius: _glow.value * widget.maxSpread,
            ),
          ],
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}
