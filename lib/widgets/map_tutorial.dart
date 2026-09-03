import 'package:flutter/material.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';

import '../services/subscription_limit_service.dart';

/// Builds the one-time, 3-step map spotlight tour:
///   1. search bar  → add your first place
///   2. map center  → press & hold to discover nearby places
///   3. optimize    → 3+ places unlock route optimization
///
/// Fully PASSIVE by design: the scrim swallows every gesture, each step has
/// an explicit Next/Got-it button, and the skip affordance is always
/// available. No gesture pass-through — executing e.g. the search push
/// mid-tour would strand the remaining steps over a covered screen.
///
/// Gating (once-per-user flag, visibility, overlay collisions) is entirely
/// the caller's job (map_screen._maybeStartMapTutorial); this file is pure
/// presentation.
TutorialCoachMark buildMapTutorial(
  BuildContext context, {
  required GlobalKey searchBarKey,
  required GlobalKey optimizeKey,
  required bool isPro,
  required VoidCallback onFinish,
  required bool Function(int lastShownStep) onSkip,
}) {
  // Captured by both callbacks below: beforeFocus records which step is on
  // screen so a Skip can report where the user bailed.
  var lastStep = 0;

  final targets = <TargetFocus>[
    TargetFocus(
      identify: 0,
      keyTarget: searchBarKey,
      shape: ShapeLightFocus.RRect,
      radius: 30, // matches the search pill's border radius
      enableTargetTab: false,
      enableOverlayTab: false,
      contents: [
        TargetContent(
          align: ContentAlign.bottom,
          builder: (context, controller) => _StepCard(
            title: 'Add your first place',
            body: 'Search any spot — sights, food, hotels — and save it to '
                'your day.'
                '${isPro ? '' : '\nYou\'ve got ${SubscriptionLimitService.freePlaceAllowance} free places to start.'}',
            buttonLabel: 'Next',
            onPressed: controller.next,
          ),
        ),
      ],
    ),
    TargetFocus(
      identify: 1,
      targetPosition: _mapBandTarget(context),
      shape: ShapeLightFocus.Circle,
      enableTargetTab: false,
      enableOverlayTab: false,
      contents: [
        TargetContent(
          align: ContentAlign.bottom,
          builder: (context, controller) => _StepCard(
            icon: Icons.touch_app_rounded,
            title: 'Discover what\'s nearby',
            body: 'Press and hold anywhere on the map to find places around '
                'that point.',
            buttonLabel: 'Next',
            onPressed: controller.next,
          ),
        ),
      ],
    ),
    // Step 3 only when the optimize button is actually laid out (it always
    // should be after the header restructure, but a dead key would crash
    // the overlay — filter proactively).
    if (_isLaidOut(optimizeKey))
      TargetFocus(
        identify: 2,
        keyTarget: optimizeKey,
        shape: ShapeLightFocus.RRect,
        radius: 12,
        enableTargetTab: false,
        enableOverlayTab: false,
        contents: [
          TargetContent(
            align: ContentAlign.top,
            builder: (context, controller) => _StepCard(
              title: 'Then let VoyZa do the routing',
              body: 'Save 3 or more places and Optimize puts them in the '
                  'smartest order — see more, backtrack less.',
              buttonLabel: 'Got it',
              onPressed: controller.next, // last step → finishes
            ),
          ),
        ],
      ),
  ];

  return TutorialCoachMark(
    targets: targets,
    colorShadow: Colors.black,
    opacityShadow: 0.75,
    paddingFocus: 6,
    // A real, legible "Skip tour" button rather than the package's faint
    // default label — an escape hatch the user can't find is no escape hatch.
    alignSkip: Alignment.topRight,
    skipWidget: const _SkipButton(),
    // Snappier hops between steps. The package defaults (600/600/500ms) make
    // a 3-step tour feel sluggish; these keep the motion readable without
    // making the user wait for it.
    focusAnimationDuration: const Duration(milliseconds: 250),
    unFocusAnimationDuration: const Duration(milliseconds: 200),
    // No pulsing spotlight: the package repaints the full-screen scrim
    // every frame while pulsing — measured at ~48 fps / 67 % CPU for as
    // long as a step is on screen. A static cutout reads just as well.
    pulseEnable: false,
    pulseAnimationDuration: const Duration(milliseconds: 300),
    beforeFocus: (target) => lastStep = (target.identify as int?) ?? 0,
    onFinish: onFinish,
    onSkip: () => onSkip(lastStep),
  );
}

/// Skip affordance for the tour. Pill-shaped so it reads as tappable against
/// the dark scrim, and padded clear of the status bar via SafeArea.
class _SkipButton extends StatelessWidget {
  const _SkipButton();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(top: 8, right: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
          ),
          child: const Text(
            'Skip tour',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

bool _isLaidOut(GlobalKey key) {
  final render = key.currentContext?.findRenderObject();
  return render is RenderBox && render.hasSize;
}

/// Spotlight circle for the "hold the map" step: centered in the band
/// between the top UI (status bar + search overlay + progress chip) and
/// the collapsed bottom sheet, clamped for small screens / landscape.
TargetPosition _mapBandTarget(BuildContext context) {
  final media = MediaQuery.of(context);
  final screenW = media.size.width;
  final screenH = media.size.height;
  // 50 = map overlay top offset, 60 = search bar, ~35 = progress chip + gap.
  final topUi = media.padding.top + 50 + 60 + 35;
  final sheetTop = screenH * (1 - 0.23); // collapsed sheet snap
  final band = (sheetTop - topUi).clamp(120.0, double.infinity);
  final d = (0.6 * band).clamp(100.0, 180.0);
  return TargetPosition(
    Size(d, d),
    Offset((screenW - d) / 2, topUi + (band - d) / 2),
  );
}

class _StepCard extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String body;
  final String buttonLabel;
  final VoidCallback onPressed;

  const _StepCard({
    this.icon,
    required this.title,
    required this.body,
    required this.buttonLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, color: Colors.white, size: 34),
          const SizedBox(height: 10),
        ],
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          body,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            buttonLabel,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
