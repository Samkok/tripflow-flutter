import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/user_trip_provider.dart';
import '../../services/analytics_service.dart';
import '../../services/anonymous_user_service.dart';
import '../../services/onboarding_service.dart';
import '../../services/review_prompt_service.dart';
import '../../services/subscription_limit_service.dart';
import '../../utils/countries.dart';
import '../../widgets/country_picker_sheet.dart';

/// One-time first-run onboarding: two quick questions (traveler type, next
/// destination) + a "how VoyZa works" page that funnels straight into
/// creating the first trip. Skippable at every step; skipping lands the user
/// on the existing empty-state card, which still works standalone.
///
/// Mirrors [maybeShowAnalyticsConsent]'s call pattern: eligibility is checked
/// inside [maybeShowOnboarding], safe to fire-and-forget post-frame.
bool _onboardingInFlight = false;

Future<void> maybeShowOnboarding(BuildContext context, WidgetRef ref) async {
  if (_onboardingInFlight) return;
  _onboardingInFlight = true;
  try {
    final service = OnboardingService.instance;
    final authUserId = ref.read(currentUserIdProvider);
    final anonId = await AnonymousUserService.id;

    // ── Anonymous: onboard on the device identity. No trips to check
    // (anonymous users can't create trips) and no sample-trip CTA (it
    // requires login) — the flow funnels them to the map instead.
    if (authUserId == null) {
      if (!await service.shouldShowOnboarding(anonId)) return;
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => OnboardingScreen(userId: anonId, isAnonymous: true),
        ),
      );
      return;
    }

    // ── Authenticated.
    final userId = authUserId;
    if (!await service.shouldShowOnboarding(userId)) return;

    // Zero-trips check. On timeout/error do nothing — never block the app;
    // we'll simply try again next session.
    List<dynamic>? trips;
    try {
      trips = await ref
          .read(userTripsProvider.future)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      return;
    }

    // Seed flags before any onboarding decision. hasTrips suppresses
    // onboarding + first-trip/place celebrations for existing users; the
    // per-install optimize counter ALSO covers the anonymous→signup path —
    // a user who already got the optimize confetti anonymously shouldn't
    // get a second one on their fresh account.
    final optimizes =
        await ReviewPromptService.instance.getSuccessfulOptimizeCount();
    await service.seedFromExistingState(
      userId,
      hasTrips: trips.isNotEmpty,
      lifetimeOptimizes: optimizes,
    );
    if (trips.isNotEmpty) return; // existing user — onboarding suppressed

    // A device that already onboarded ANONYMOUSLY shouldn't repeat the
    // questions right after signup — carry the completion over.
    if (!await service.shouldShowOnboarding(anonId)) {
      await service.markOnboardingSuppressed(userId, 'auto_from_anonymous');
      return;
    }

    // Re-check: seeding a trip-less user does NOT set onboarding_done, so
    // this only guards against a concurrent completion elsewhere.
    if (!await service.shouldShowOnboarding(userId)) return;

    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => OnboardingScreen(userId: userId),
      ),
    );
  } finally {
    _onboardingInFlight = false;
  }
}

class OnboardingScreen extends ConsumerStatefulWidget {
  final String userId;

  /// Anonymous mode: [userId] is the persistent device UUID, the primary
  /// CTA funnels to the map (no trip form — trips need an account), and the
  /// sample-trip CTA is hidden (it requires login).
  final bool isAnonymous;

  const OnboardingScreen({
    super.key,
    required this.userId,
    this.isAnonymous = false,
  });

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _TravelerType {
  final String key;
  final String label;
  final IconData icon;
  const _TravelerType(this.key, this.label, this.icon);
}

const _travelerTypes = [
  _TravelerType('city', 'City explorer', Icons.location_city_rounded),
  _TravelerType('food', 'Food & culture', Icons.restaurant_rounded),
  _TravelerType('nature', 'Nature & adventure', Icons.terrain_rounded),
  _TravelerType('mixed', 'A bit of everything', Icons.auto_awesome_rounded),
];

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  int _page = 0;
  String? _travelerType;
  Country? _destination;

  /// Guards Skip/CTA re-entry: a rapid double-tap would otherwise pop the
  /// onboarding route AND the route beneath it.
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.onboardingStarted();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goTo(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _skip() async {
    if (_finishing) return;
    _finishing = true;
    AnalyticsService.instance.onboardingSkipped(_page);
    await OnboardingService.instance.markOnboardingSkipped(widget.userId);
    if (mounted) Navigator.of(context).pop();
  }

  /// Shared completion bookkeeping for both CTAs.
  Future<void> _complete() async {
    await OnboardingService.instance.saveAnswers(
      widget.userId,
      travelerType: _travelerType,
      countryCode: _destination?.code,
    );
    AnalyticsService.instance.onboardingCompleted(
      _travelerType ?? 'unanswered',
      _destination != null,
    );
    await OnboardingService.instance.markOnboardingCompleted(widget.userId);
  }

  Future<void> _planFirstTrip() async {
    if (_finishing) return;
    _finishing = true;
    await _complete();
    AnalyticsService.instance.onboardingCta('plan');
    if (widget.isAnonymous) {
      // No trip form without an account — land them on the map where the
      // search bar is, ready to add their first place.
      ref.read(mainTabRequestProvider.notifier).state = 1; // Map tab
    } else {
      // TripScreen listens and opens the create form with this country.
      ref.read(tripFormPrefillProvider.notifier).state =
          _destination?.code ?? '';
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _trySampleTrip() async {
    if (_finishing) return;
    _finishing = true;
    await _complete();
    AnalyticsService.instance.onboardingCta('sample');
    ref.read(sampleTripRequestProvider.notifier).state =
        ref.read(sampleTripRequestProvider) + 1;
    if (mounted) Navigator.of(context).pop();
  }

  /// One tailored line on the value page, keyed off the traveler type.
  String get _tailoredLine => switch (_travelerType) {
        'city' => 'Perfect for hopping between sights, streets, and skylines.',
        'food' =>
          'Perfect for stringing markets, cafés, and must-eat spots together.',
        'nature' =>
          'Perfect for routing between trailheads, viewpoints, and camps.',
        _ => 'Perfect for making every day of your trip flow smoothly.',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _skip(); // system back = skip
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              // Top bar: dots + Skip
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(child: _buildDots(theme)),
                    TextButton(
                      onPressed: _skip,
                      child: Text(
                        'Skip',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [
                    _buildTravelerPage(theme),
                    _buildDestinationPage(theme),
                    _buildValuePage(theme),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDots(ThemeData theme) {
    return Row(
      children: List.generate(3, (i) {
        final active = i == _page;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.only(right: 6),
          width: active ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }

  // ── Page 1: traveler type ────────────────────────────────────────────────
  Widget _buildTravelerPage(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          Text(
            'What kind of traveler\nare you?',
            style: theme.textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'We\'ll tune VoyZa to how you like to explore.',
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          ..._travelerTypes.map((t) {
            final selected = _travelerType == t.key;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  setState(() => _travelerType = t.key);
                  // Auto-advance after a beat so the selection registers.
                  Future.delayed(
                      const Duration(milliseconds: 250), () => _goTo(1));
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: selected
                        ? theme.colorScheme.primary.withValues(alpha: 0.12)
                        : theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: selected
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(t.icon,
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 14),
                      Text(
                        t.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          const Spacer(flex: 2),
        ],
      ),
    );
  }

  // ── Page 2: destination ─────────────────────────────────────────────────
  Widget _buildDestinationPage(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          Text(
            'Where to next?',
            style: theme.textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            widget.isAnonymous
                ? 'Pick a country — we\'ll keep it in mind for your first trip.'
                : 'Pick a country and we\'ll set up your first trip there.',
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () async {
              final result = await showCountryPickerSheet(
                context,
                selectedCode: _destination?.code,
              );
              if (result == null) return;
              setState(() {
                _destination =
                    result.code == kClearCountry.code ? null : result;
              });
              if (_destination != null) {
                Future.delayed(
                    const Duration(milliseconds: 250), () => _goTo(2));
              }
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _destination != null
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.2),
                  width: _destination != null ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Text(
                    _destination?.flagEmoji ?? '🌍',
                    style: const TextStyle(fontSize: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _destination?.name ?? 'Choose a country',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: _destination != null
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: _destination != null
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(Icons.expand_more_rounded,
                      color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: () => _goTo(2),
              child: Text(
                'I\'m not sure yet',
                style:
                    TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          const Spacer(flex: 2),
        ],
      ),
    );
  }

  // ── Page 3: value + CTAs ─────────────────────────────────────────────────
  Widget _buildValuePage(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          Text(
            'Here\'s how VoyZa works',
            style: theme.textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            _tailoredLine,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          _step(theme, Icons.place_outlined, 'Save the places you want to see',
              '3 or more unlocks route optimization'),
          _step(theme, Icons.auto_awesome_rounded, 'Tap Optimize',
              'VoyZa puts your stops in the smartest order'),
          _step(theme, Icons.timelapse_rounded, 'See more, backtrack less',
              'Your day flows stop to stop, no wasted detours'),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(Icons.card_giftcard_rounded,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'You\'ve got ${SubscriptionLimitService.freePlaceAllowance} free places to start — '
                    'enough to optimize your first day.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // Anonymous users get the sample trip as the PRIMARY CTA: it's their
          // one-tap path to the optimize aha (no account, no cold empty map).
          // Authenticated users keep "plan my trip" primary with the sample as
          // the secondary escape hatch.
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed:
                  widget.isAnonymous ? _trySampleTrip : _planFirstTrip,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                widget.isAnonymous
                    ? 'Try a sample trip'
                    : _destination != null
                        ? 'Plan my ${_destination!.name} trip'
                        : 'Plan my first trip',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          Center(
            child: TextButton(
              onPressed:
                  widget.isAnonymous ? _planFirstTrip : _trySampleTrip,
              child: Text(widget.isAnonymous
                  ? 'Start adding my own places'
                  : 'Try a sample trip instead'),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _step(
      ThemeData theme, IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: theme.colorScheme.primary, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
