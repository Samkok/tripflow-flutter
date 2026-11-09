import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'route_spine.dart';

/// Skeletons for the home screen, built as GHOSTS of the real trip card:
/// same translucent shell, same hairline border, same corner radius — and a
/// frosted BackdropFilter so the ambient globe blurs through them instead of
/// the old flat grey slabs. Placeholder bars use low-alpha ink (never grey),
/// and the shimmer sweep carries a faint cyan sheen so even loading feels
/// on-brand. The card's route-spine signature is present at low alpha, so
/// the page's identity exists before its data does.
class _Shimmer extends StatefulWidget {
  final Widget child;
  const _Shimmer({required this.child});

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.colorScheme.onSurface.withValues(alpha: 0.07);
    final sheen = theme.colorScheme.primary.withValues(alpha: 0.16);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final dx = bounds.width * 2 * _controller.value - bounds.width;
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [base, sheen, base],
              stops: const [0.35, 0.5, 0.65],
              transform: _SlideGradientTransform(dx),
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _SlideGradientTransform extends GradientTransform {
  final double dx;
  const _SlideGradientTransform(this.dx);
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(dx, 0, 0);
  }
}

class _SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;
  const _SkeletonBox({
    this.width,
    required this.height,
    this.radius = 6,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// The shared frosted shell: same geometry as the real card, with the globe
/// blurring through behind a thin translucent fill.
class _GlassCardShell extends StatelessWidget {
  final Widget child;
  const _GlassCardShell({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: theme.cardColor.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.2),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Ghost of one trip card: flag badge, name bar, the route spine at low
/// alpha, metadata bar, and the action bar — in the real card's positions,
/// so data resolving reads as content filling in, never a layout jump.
class TripCardSkeleton extends StatelessWidget {
  const TripCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Shimmer(
      child: _GlassCardShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                _SkeletonBox(width: 34, height: 34, radius: 10),
                SizedBox(width: 10),
                Expanded(child: _SkeletonBox(height: 20, radius: 7)),
                SizedBox(width: 16),
                _SkeletonBox(width: 4, height: 18, radius: 2), // ⋮ ghost
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 12,
              width: double.infinity,
              child: CustomPaint(
                painter: RouteSpinePainter(
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.22),
                  stops: 3,
                ),
              ),
            ),
            const SizedBox(height: 10),
            const _SkeletonBox(width: 210, height: 12),
            const SizedBox(height: 16),
            const _SkeletonBox(height: 42, radius: 12),
          ],
        ),
      ),
    );
  }
}

/// Vertically stacked list of [TripCardSkeleton]s, matching the spacing of
/// the loaded trip list in `trip_screen.dart`.
class TripsListSkeleton extends StatelessWidget {
  final int count;
  const TripsListSkeleton({super.key, this.count = 3});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        children: List.generate(
          count,
          (i) => Padding(
            padding: EdgeInsets.only(bottom: i == count - 1 ? 0 : 12),
            child: const TripCardSkeleton(),
          ),
        ),
      ),
    );
  }
}
