import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';

export 'package:tutorial_coach_mark/tutorial_coach_mark.dart' show ContentAlign;

import '../core/theme.dart';
import '../providers/onboarding_checklist_provider.dart';

/// ── Getting-started checklist ────────────────────────────────────────────
/// Two presentations of the same list:
///  • [OnboardingChecklistCard] — inline on the home tab while the user has
///    no trips (replaces the old "Plan your first trip" empty-state pitch).
///  • [showChecklistSheet] — glass bottom sheet opened from
///    [ChecklistHeaderChip] once trips exist, so the list never crowds the
///    screen. Step taps dismiss the sheet FIRST, then run the guide.
///
/// Step taps only fire the [ChecklistGuide] bus — the owning screens do the
/// scrolling/navigation/spotlighting (trip_screen, trip_details, map).

const _kStepMeta = {
  ChecklistStep.createTrip: (
    icon: Icons.add_location_alt_outlined,
    title: 'Create your first trip',
    subtitle: 'Name it, pick dates — 30 seconds',
  ),
  ChecklistStep.addLocations: (
    icon: Icons.place_outlined,
    title: 'Add 3 places to it',
    subtitle: 'Search anything — cafés, sights, hotels',
  ),
  ChecklistStep.activateTrip: (
    icon: Icons.play_circle_outline,
    title: 'Activate the trip',
    subtitle: 'Puts it on your map, ready to go',
  ),
  ChecklistStep.optimizeRoute: (
    icon: Icons.route_outlined,
    title: 'Optimize your route',
    subtitle: 'The magic: best order, less travel time',
  ),
};

Color _progressColor(double t) {
  if (t >= 1) return const Color(0xFF30D158);
  if (t >= 0.5) return const Color(0xFF00D4FF);
  return const Color(0xFFF5A623);
}

class _ChecklistBody extends ConsumerWidget {
  const _ChecklistBody({required this.onStepTap, this.inSheet = false});

  final void Function(ChecklistStep step) onStepTap;
  final bool inSheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final s = ref.watch(checklistProvider);
    final doneCount = s.done.length;
    final color = _progressColor(s.progress);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Get started with VoyZa',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            Text(
              '$doneCount of ${ChecklistStep.values.length}',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: s.progress),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
            builder: (_, v, __) => LinearProgressIndicator(
              value: v,
              minHeight: 7,
              backgroundColor: theme.dividerColor.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
        const SizedBox(height: 6),
        ...ChecklistStep.values.map((step) => _StepRow(
              step: step,
              state: s,
              onTap: () => onStepTap(step),
            )),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow(
      {required this.step, required this.state, required this.onTap});

  final ChecklistStep step;
  final ChecklistState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = _kStepMeta[step]!;
    final done = state.isDone(step);
    final enabled = state.isEnabled(step);
    final dimmed = !done && !enabled;

    return Opacity(
      opacity: dimmed ? 0.38 : 1,
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done
                    ? const Color(0xFF30D158)
                    : theme.colorScheme.primary
                        .withValues(alpha: enabled ? 0.15 : 0.07),
                border: done
                    ? null
                    : Border.all(
                        color: theme.dividerColor.withValues(alpha: 0.4)),
              ),
              child: Icon(
                done ? Icons.check_rounded : meta.icon,
                size: 17,
                color: done ? Colors.white : theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    meta.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      decoration: done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (!done)
                    Text(
                      meta.subtitle,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            if (enabled)
              FilledButton.tonal(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  backgroundColor:
                      const Color(0xFFF5A623).withValues(alpha: 0.16),
                  foregroundColor: const Color(0xFFF5A623),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                  shape: const StadiumBorder(
                      side: BorderSide(color: Color(0x66F5A623))),
                ),
                child: const Text('Show me'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Inline variant for the no-trips home state.
class OnboardingChecklistCard extends StatelessWidget {
  const OnboardingChecklistCard({super.key, required this.onStepTap});

  final void Function(ChecklistStep step) onStepTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.25)),
      ),
      child: _ChecklistBody(onStepTap: onStepTap),
    );
  }
}

/// Empty-home state for a user who already finished the checklist: the
/// guided list would be noise, so acknowledge and point at New Trip.
class ChecklistAllSetCard extends StatelessWidget {
  const ChecklistAllSetCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF30D158).withValues(alpha: 0.15),
            ),
            child: const Icon(Icons.check_rounded,
                size: 30, color: Color(0xFF30D158)),
          ),
          const SizedBox(height: 14),
          Text("You're all set!",
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            'You know the ropes — create a trip to continue.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Small amber entry point for the home header while the checklist is
/// unfinished but trips already exist — the list itself lives in the sheet.
class ChecklistHeaderChip extends ConsumerWidget {
  const ChecklistHeaderChip({super.key, required this.onStepTap});

  final void Function(ChecklistStep step) onStepTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(checklistProvider);
    if (!s.loaded || s.isComplete) return const SizedBox.shrink();
    const amber = Color(0xFFF5A623);
    // Same corner radius as the New Trip button beside it; height comes
    // from the parent (IntrinsicHeight row stretches both to match).
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Material(
        color: amber.withValues(alpha: 0.16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: amber, width: 1.2)),
        child: InkWell(
          customBorder:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          onTap: () => showChecklistSheet(context, onStepTap: onStepTap),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.checklist_rounded, size: 18, color: amber),
                const SizedBox(width: 6),
                Text(
                  '${s.done.length}/${ChecklistStep.values.length}',
                  style: const TextStyle(
                      color: amber, fontWeight: FontWeight.w800, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass sheet variant. Dismisses BEFORE running the tapped step's guide so
/// the spotlight never fights the sheet for the screen.
Future<void> showChecklistSheet(
  BuildContext context, {
  required void Function(ChecklistStep step) onStepTap,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: AppTheme.sheetBarrierColor(context),
    builder: (sheetContext) => ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(
            sigmaX: AppTheme.sheetBlurSigma, sigmaY: AppTheme.sheetBlurSigma),
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context)
                .scaffoldBackgroundColor
                .withValues(alpha: AppTheme.sheetFillAlpha(context)),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(
                color: AppTheme.sheetBorderColor(context), width: 0.8),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _ChecklistBody(
                    inSheet: true,
                    onStepTap: (step) {
                      Navigator.of(sheetContext).pop();
                      // Let the sheet's exit finish before the guide starts
                      // measuring target positions.
                      Future.delayed(const Duration(milliseconds: 260),
                          () => onStepTap(step));
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Floating n/3 badge for trip details while step 2 is the active goal —
/// the checklist lives on home, so this is the in-context reminder of what
/// "done" means here.
class AddLocationsProgressBadge extends ConsumerWidget {
  const AddLocationsProgressBadge({super.key, required this.count});

  /// Live location count of the trip on screen.
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(checklistProvider);
    final active = s.loaded &&
        s.isDone(ChecklistStep.createTrip) &&
        !s.isDone(ChecklistStep.addLocations);
    if (!active) return const SizedBox.shrink();

    const amber = Color(0xFFF5A623);
    final n = count.clamp(0, 3);
    // Material(transparency) matters: this badge floats OUTSIDE the
    // Scaffold, and a Text with no Material ancestor renders with the
    // framework's yellow double-underline fallback style.
    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xF01B2A3F),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: amber.withValues(alpha: 0.6)),
            boxShadow: const [
              BoxShadow(color: Colors.black38, blurRadius: 8),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < n ? amber : Colors.white24,
                  ),
                ),
              ],
              const SizedBox(width: 3),
              Text(
                n >= 3
                    ? 'Done!'
                    : 'Add ${3 - n} more place${3 - n == 1 ? '' : 's'} · $n/3',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ── Single-target spotlight ──────────────────────────────────────────────
/// Same look and timings as the map tour (map_tutorial.dart), but for one
/// target at a time — each checklist tap guides exactly one control.
void showChecklistCoach(
  BuildContext context, {
  required GlobalKey targetKey,
  required String title,
  required String body,
  ContentAlign align = ContentAlign.bottom,
}) {
  if (targetKey.currentContext == null) {
    debugPrint('showChecklistCoach: target not laid out, skipping');
    return;
  }
  TutorialCoachMark(
    targets: [
      TargetFocus(
        identify: 0,
        keyTarget: targetKey,
        enableOverlayTab: true,
        shape: ShapeLightFocus.RRect,
        radius: 16,
        contents: [
          TargetContent(
            align: align,
            builder: (context, controller) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(body,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 14.5, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    ],
    colorShadow: Colors.black,
    opacityShadow: 0.75,
    paddingFocus: 6,
    hideSkip: true,
    focusAnimationDuration: const Duration(milliseconds: 250),
    unFocusAnimationDuration: const Duration(milliseconds: 200),
    pulseAnimationDuration: const Duration(milliseconds: 300),
  ).show(context: context);
}

/// ── Completion celebration ───────────────────────────────────────────────
/// Full-screen takeover in the app's own palette: green scalloped seal with
/// a bold check, sparkles, eyebrow + big title, and one cyan CTA pinned to
/// the bottom. Entrance is staggered (seal pops, text rises, button fades).
Future<void> showChecklistCompleteCelebration(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    useSafeArea: false,
    builder: (_) => const Dialog.fullscreen(
      child: _ChecklistCelebrationScreen(),
    ),
  );
}

class _ChecklistCelebrationScreen extends StatefulWidget {
  const _ChecklistCelebrationScreen();

  @override
  State<_ChecklistCelebrationScreen> createState() =>
      _ChecklistCelebrationScreenState();
}

class _ChecklistCelebrationScreenState
    extends State<_ChecklistCelebrationScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _seal;
  late final Animation<double> _text;
  late final Animation<double> _button;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100));
    _seal = CurvedAnimation(
        parent: _c, curve: const Interval(0, 0.45, curve: Curves.easeOutBack));
    _text = CurvedAnimation(
        parent: _c,
        curve: const Interval(0.35, 0.75, curve: Curves.easeOutCubic));
    _button = CurvedAnimation(
        parent: _c, curve: const Interval(0.6, 1, curve: Curves.easeOut));
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const green = Color(0xFF23A55A);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 3),
              ScaleTransition(
                scale: _seal,
                child: const SizedBox(
                  height: 230,
                  child: CustomPaint(painter: _SealBadgePainter()),
                ),
              ),
              const Spacer(flex: 2),
              FadeTransition(
                opacity: _text,
                child: SlideTransition(
                  position:
                      Tween(begin: const Offset(0, 0.12), end: Offset.zero)
                          .animate(_text),
                  child: Column(
                    children: [
                      const Text(
                        'Congratulations!',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: green,
                            fontSize: 17,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        "You're all set",
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Trip created, places added, route optimized — '
                        'planning that usually takes an evening, done in '
                        'minutes. This is how every trip works from here.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.45),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(flex: 4),
              FadeTransition(
                opacity: _button,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 17),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                    textStyle: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  child: const Text('Start exploring'),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// Green scalloped seal + 3D check + sparkles (the attachment's badge,
/// redrawn in code so it needs no asset and follows device pixel ratio).
class _SealBadgePainter extends CustomPainter {
  const _SealBadgePainter();

  Path _seal(Offset c, double r) {
    const scallops = 12;
    const amp = 0.055;
    final path = Path();
    for (var i = 0; i <= 240; i++) {
      final t = i / 240 * 2 * math.pi;
      final rr = r * (1 + amp * math.cos(scallops * t));
      final p = c + Offset(math.cos(t), math.sin(t)) * rr;
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  Path _sparkle(Offset c, double r) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final t = i * math.pi / 4 - math.pi / 2;
      final rr = i.isEven ? r : r * 0.32;
      final p = c + Offset(math.cos(t), math.sin(t)) * rr;
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    const green = Color(0xFF23A55A);
    const greenDark = Color(0xFF17753F);
    const sparkle = Color(0xFF2EC4B6);
    final r = size.height * 0.36;

    // Seal: dark offset layer first for the sticker-like depth.
    canvas.drawPath(
        _seal(c + const Offset(7, 9), r), Paint()..color = greenDark);
    canvas.drawPath(_seal(c, r), Paint()..color = green);

    // Check mark, with its own darker offset for the 3D look.
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.30
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final check = Path()
      ..moveTo(c.dx - r * 0.42, c.dy + r * 0.02)
      ..lineTo(c.dx - r * 0.08, c.dy + r * 0.36)
      ..lineTo(c.dx + r * 0.48, c.dy - 0.38 * r);
    canvas.drawPath(check.shift(const Offset(4, 6)), stroke..color = greenDark);
    canvas.drawPath(check, stroke..color = Colors.white);

    // Sparkles — same trio of positions as the reference.
    canvas.drawPath(_sparkle(c + Offset(r * 1.28, -r * 1.18), r * 0.16),
        Paint()..color = sparkle);
    canvas.drawPath(_sparkle(c + Offset(-r * 1.42, r * 0.30), r * 0.12),
        Paint()..color = sparkle);
    canvas.drawPath(_sparkle(c + Offset(r * 1.38, r * 1.05), r * 0.20),
        Paint()..color = sparkle);
  }

  @override
  bool shouldRepaint(covariant _SealBadgePainter oldDelegate) => false;
}
