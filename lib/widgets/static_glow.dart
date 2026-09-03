import 'package:flutter/material.dart';

/// A soft colored halo drawn behind [child] to make a primary affordance
/// stand out — e.g. the share-route FAB or the New Trip button. Circular by
/// default (sized to a FAB); pass [shape]/[borderRadius] for a rounded rect.
///
/// STATIC by design. This replaced a pulsing version (the blurred shadow
/// animated between [minBlur]/[maxBlur] for ~20 s after every mount).
/// Measured on the simulator, a single pulsing glow held the whole app at
/// ~46 fps / ~60 % CPU with ~7 ms of raster per frame — re-blurring a large
/// shadow every vsync on top of the screen's backdrop blurs — and it
/// restarted on every screen open. A fixed halo at the midpoint of the old
/// range keeps the emphasis and costs one rasterization.
///
/// The min/max parameters are kept so call-site tuning still means the same
/// thing: the halo sits at the midpoint of each range.
class StaticGlow extends StatelessWidget {
  final Widget child;
  final Color glowColor;
  final BoxShape shape;
  final BorderRadius? borderRadius;
  final double minBlur;
  final double maxBlur;
  final double maxSpread;
  final double minAlpha;
  final double maxAlpha;

  const StaticGlow({
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
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: shape,
        borderRadius: shape == BoxShape.rectangle ? borderRadius : null,
        boxShadow: [
          BoxShadow(
            color: glowColor.withValues(alpha: (minAlpha + maxAlpha) / 2),
            blurRadius: (minBlur + maxBlur) / 2,
            spreadRadius: maxSpread / 2,
          ),
        ],
      ),
      child: child,
    );
  }
}
