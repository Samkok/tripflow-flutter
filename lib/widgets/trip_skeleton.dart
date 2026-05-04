import 'package:flutter/material.dart';

/// Self-contained shimmer + skeleton primitives sized to mirror the trip
/// cards on the home screen. Kept dependency-free (no `shimmer` package) by
/// driving a sliding gradient via [AnimatedBuilder].
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
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? Colors.white12 : Colors.black12;
    final highlight = isDark ? Colors.white24 : Colors.white;
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
              colors: [base, highlight, base],
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: isDark ? Colors.white12 : Colors.black12,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Skeleton for the "Active Trip" hero card shown at the top of the home
/// screen. Sized to occupy the same vertical space as the loaded card so the
/// page layout doesn't jump when data resolves.
class ActiveTripSkeleton extends StatelessWidget {
  const ActiveTripSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Shimmer(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.15),
          ),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _SkeletonBox(width: 16, height: 16, radius: 4),
                SizedBox(width: 8),
                _SkeletonBox(width: 80, height: 12),
              ],
            ),
            SizedBox(height: 12),
            _SkeletonBox(width: 200, height: 22),
            SizedBox(height: 10),
            _SkeletonBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// Skeleton matching a single [Trip] card in the home-screen list. Matches
/// the rounded container, title row, country chip and metadata row used by
/// `_buildTripCardContent` so swapping the placeholder for real data feels
/// like content filling in, not a layout shift.
class TripCardSkeleton extends StatelessWidget {
  const TripCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Shimmer(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.dividerColor.withValues(alpha: 0.2),
          ),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: _SkeletonBox(height: 18)),
                SizedBox(width: 12),
                _SkeletonBox(width: 24, height: 24, radius: 12),
              ],
            ),
            SizedBox(height: 10),
            _SkeletonBox(width: 120, height: 12),
            SizedBox(height: 14),
            Row(
              children: [
                _SkeletonBox(width: 90, height: 12),
                SizedBox(width: 12),
                _SkeletonBox(width: 60, height: 12),
              ],
            ),
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
