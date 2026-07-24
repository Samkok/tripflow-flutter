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
///
/// [onInvite] is provided only for AUTHENTICATED users (who have a referral
/// code): renders a secondary "Invite a friend, get a free month" button —
/// the aha moment is the highest-converting referral surface. Mutually
/// exclusive with [onSignUp] in practice (anon has no code).
Future<void> showFirstOptimizeCelebration(
  BuildContext context, {
  required int stops,
  required Duration totalTime,
  Duration timeSaved = Duration.zero,
  VoidCallback? onSignUp,
  VoidCallback? onInvite,
  VoidCallback? onShare,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _FirstOptimizeDialog(
      stops: stops,
      totalTime: totalTime,
      timeSaved: timeSaved,
      onSignUp: onSignUp,
      onInvite: onInvite,
      onShare: onShare,
    ),
  );
}

class _FirstOptimizeDialog extends StatefulWidget {
  final int stops;
  final Duration totalTime;

  /// Travel time saved vs the user's original order. Only shown when ≥ ~5
  /// minutes — the number IS the retellable story ("it saved me an hour"),
  /// so it must always be defensible.
  final Duration timeSaved;
  final VoidCallback? onSignUp;
  final VoidCallback? onInvite;

  /// Opens the before/after route-card share sheet. Offered to EVERYONE
  /// (authed + anonymous) — the aha peak is the moment worth sharing
  /// (Contagious: share prompt at the emotional high point).
  final VoidCallback? onShare;

  const _FirstOptimizeDialog({
    required this.stops,
    required this.totalTime,
    this.timeSaved = Duration.zero,
    this.onSignUp,
    this.onInvite,
    this.onShare,
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
    final showSaved = widget.timeSaved >= const Duration(minutes: 5);
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
                      if (showSaved) ...[
                        const TextSpan(text: '\nThat\'s '),
                        TextSpan(
                          text:
                              '${_formatDuration(widget.timeSaved)} of backtracking saved',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const TextSpan(text: ' vs your original order.'),
                      ],
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
                if (widget.onShare != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: TextButton.icon(
                      onPressed: () {
                        final cb = widget.onShare!;
                        Navigator.of(context).pop();
                        cb();
                      },
                      icon: const Icon(Icons.ios_share_rounded, size: 18),
                      label: const Text('Share your route'),
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
                if (widget.onInvite != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: TextButton.icon(
                      onPressed: () {
                        final cb = widget.onInvite!;
                        Navigator.of(context).pop();
                        cb();
                      },
                      icon: const Icon(Icons.card_giftcard_rounded, size: 18),
                      label: const Text('Invite a friend, get a free month'),
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

/// Post-trip recap ("the trip, by the numbers") — shown once per trip in the
/// T+1..T+3 window after it ends. The share CTA is the point: it rides the
/// moment people are already posting trip photos, so the recap card becomes
/// behavioral residue with attribution.
Future<void> showTripRecapDialog(
  BuildContext context, {
  required String tripName,
  required int days,
  required int places,
  required Duration timeSaved,
  VoidCallback? onShare,
}) {
  String fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final primary = theme.colorScheme.primary;

      Widget stat(String value, String label) => Column(
            children: [
              Text(value,
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w800, color: primary)),
              const SizedBox(height: 2),
              Text(label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          );

      return Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🧳', style: TextStyle(fontSize: 44)),
              const SizedBox(height: 12),
              Text(
                'How was $tripName?',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                'Your trip, by the numbers:',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  stat('$days', days == 1 ? 'day' : 'days'),
                  stat('$places', places == 1 ? 'place' : 'places'),
                  if (timeSaved >= const Duration(minutes: 5))
                    stat('~${fmt(timeSaved)}', 'saved'),
                ],
              ),
              const SizedBox(height: 22),
              if (onShare != null)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      onShare();
                    },
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    label: const Text('Share the recap'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Plan Card moment — the trip's plan just became fully optimized (every day
/// has a route). The pre-trip social-currency peak: the user is about to
/// message the group chat anyway; hand them the artifact. [onShare] receives
/// whether the roast line should be on the card (curation control).
Future<void> showPlanCardDialog(
  BuildContext context, {
  required String tripName,
  required String archetype,
  required int days,
  required int places,
  required Duration timeSaved,
  required String roastLine,
  required void Function(bool roastEnabled) onShare,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _PlanCardDialog(
      tripName: tripName,
      archetype: archetype,
      days: days,
      places: places,
      timeSaved: timeSaved,
      roastLine: roastLine,
      onShare: onShare,
    ),
  );
}

class _PlanCardDialog extends StatefulWidget {
  final String tripName;
  final String archetype;
  final int days;
  final int places;
  final Duration timeSaved;
  final String roastLine;
  final void Function(bool roastEnabled) onShare;

  const _PlanCardDialog({
    required this.tripName,
    required this.archetype,
    required this.days,
    required this.places,
    required this.timeSaved,
    required this.roastLine,
    required this.onShare,
  });

  @override
  State<_PlanCardDialog> createState() => _PlanCardDialogState();
}

class _PlanCardDialogState extends State<_PlanCardDialog> {
  bool _roastEnabled = true;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🏅', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 10),
            Text(
              'Your ${widget.tripName} plan is ready',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            // The earned identity — the shareable unit.
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primary.withValues(alpha: 0.4)),
              ),
              child: Text(
                widget.archetype,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: primary,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${widget.days} ${widget.days == 1 ? 'day' : 'days'} · '
              '${widget.places} places · zero backtracking'
              '${widget.timeSaved >= const Duration(minutes: 5) ? '\n~${_fmt(widget.timeSaved)} saved vs the chaos version' : ''}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              value: _roastEnabled,
              onChanged: (v) => setState(() => _roastEnabled = v),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                'Roast me a little',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '"${widget.roastLine}"',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onShare(_roastEnabled);
                },
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: const Text('Share my plan'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Later'),
            ),
          ],
        ),
      ),
    );
  }
}
