import 'dart:math' as math;

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';

import '../services/subscription_limit_service.dart';
import 'free_places_meter.dart';

/// One-time activation celebrations. Gating (per-user "already celebrated"
/// flags) lives with the callers via [OnboardingService]; these are pure UI.
///
/// Hierarchy is deliberate: the first-trip modal is light (emoji + meter),
/// the first-optimize one is the big moment (confetti) — optimizing is the
/// product's "aha," so it gets the fireworks.

String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h > 0 && m > 0) return '${h}h ${m}m';
  if (h > 0) return '${h}h';
  return '${m}m';
}

/// Light congrats modal after the user's very first trip is created.
/// Points them at the next step (adding places) and frames the free-place
/// allowance as a goal meter. [placesUsed] is the user's live own-place
/// count — usually 0, but a user who saved unassigned places before their
/// first trip should see the truth.
Future<void> showFirstTripCelebration(BuildContext context,
    {int placesUsed = 0}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🎉', style: TextStyle(fontSize: 44)),
              const SizedBox(height: 12),
              Text(
                'Your first trip is ready!',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Now the fun part — add the places you want to visit. '
                'Search below to add your first one.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              FreePlacesMeter(
                used: placesUsed.clamp(
                    0, SubscriptionLimitService.freePlaceAllowance),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Add places',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// The big one-time celebration after the user's first successful route
/// optimization — the product "aha." Confetti + the real numbers.
///
/// [onSignUp] is provided only for ANONYMOUS users: it renders a secondary
/// "Sign up free to keep your places" nudge (their local places genuinely
/// merge into the account on login via syncOnLogin). Invoked AFTER the
/// dialog pops.
Future<void> showFirstOptimizeCelebration(
  BuildContext context, {
  required int stops,
  required Duration totalTime,
  VoidCallback? onSignUp,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _FirstOptimizeDialog(
      stops: stops,
      totalTime: totalTime,
      onSignUp: onSignUp,
    ),
  );
}

class _FirstOptimizeDialog extends StatefulWidget {
  final int stops;
  final Duration totalTime;
  final VoidCallback? onSignUp;

  const _FirstOptimizeDialog({
    required this.stops,
    required this.totalTime,
    this.onSignUp,
  });

  @override
  State<_FirstOptimizeDialog> createState() => _FirstOptimizeDialogState();
}

class _FirstOptimizeDialogState extends State<_FirstOptimizeDialog> {
  late final ConfettiController _confetti;

  @override
  void initState() {
    super.initState();
    _confetti = ConfettiController(duration: const Duration(seconds: 2));
    // Fire after the dialog's entrance animation lands.
    WidgetsBinding.instance.addPostFrameCallback((_) => _confetti.play());
  }

  @override
  void dispose() {
    _confetti.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showTime = widget.totalTime > Duration.zero;
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('🏆', style: TextStyle(fontSize: 44)),
                const SizedBox(height: 12),
                Text(
                  'First route optimized!',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text.rich(
                  TextSpan(
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                    children: [
                      const TextSpan(text: 'VoyZa put your '),
                      TextSpan(
                        text:
                            '${widget.stops} ${widget.stops == 1 ? 'stop' : 'stops'}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const TextSpan(text: ' in the smartest order'),
                      if (showTime) ...[
                        const TextSpan(text: ' — about '),
                        TextSpan(
                          text: _formatDuration(widget.totalTime),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const TextSpan(text: ' door to door'),
                      ],
                      const TextSpan(text: ', with no backtracking.'),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Show me the route',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                if (widget.onSignUp != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: TextButton(
                      onPressed: () {
                        final cb = widget.onSignUp!;
                        Navigator.of(context).pop();
                        cb();
                      },
                      child: const Text('Sign up free to keep your places'),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Confetti bursts downward over the dialog.
        ConfettiWidget(
          confettiController: _confetti,
          blastDirection: math.pi / 2,
          blastDirectionality: BlastDirectionality.explosive,
          emissionFrequency: 0.05,
          numberOfParticles: 24,
          maxBlastForce: 24,
          minBlastForce: 8,
          gravity: 0.25,
          shouldLoop: false,
        ),
      ],
    );
  }
}
