import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/location_provider.dart';
import '../providers/subscription_provider.dart';
import '../providers/referral_provider.dart';
import '../screens/paywall_screen.dart';
import 'analytics_service.dart';

/// Gate that enforces the free-tier saved-place allowance. With store-managed
/// introductory offers, "Pro" includes the trial period (RevenueCat marks the
/// entitlement active for the trial window), so a single isPro check covers
/// both cases.
///
/// Every non-Pro user may save up to [freePlaceAllowance] places before the
/// paywall appears, so they can reach the route-optimization "aha" first.
/// (Formerly the treatment arm of the PaywallExperiment A/B — made universal
/// once onboarding was built around build → optimize → paywall.)
///
/// Trip creation is NOT gated — the paywall promises "Unlimited trips."
class SubscriptionLimitService {
  final WidgetRef _ref;

  SubscriptionLimitService(this._ref);

  /// Saved-place allowance for free users. Copy in the paywall and the
  /// onboarding/goal-gradient surfaces assumes this value; update them
  /// together if it ever changes.
  static const int freePlaceAllowance = 5;

  /// The user's ACTUAL allowance: the base 5 plus permanent bonus slots
  /// earned from referrals (+2 per redemption, capped server-side at +10).
  /// Falls back to the base while the profile row is still loading.
  static int effectiveAllowanceOf(WidgetRef ref) =>
      freePlaceAllowance +
      (ref.read(referralBonusPlacesProvider).valueOrNull ?? 0);

  /// Returns true when adding a NEW place may proceed. Returns false when the
  /// paywall was shown and the user dismissed it without subscribing.
  ///
  /// Metered on the LIVE count of the user's OWN saved places (deleting
  /// places frees capacity). Counting rows by userId matters: the local
  /// location cache also holds collaborators' places from shared trips, and
  /// those must not eat a free user's allowance. The alternative — the
  /// lifetime `locations_added_count` column on user_profiles — would prevent
  /// add/delete cycling, but the live count matches the behavior users
  /// already shipped with and keeps the "delete the sample trip to free your
  /// places" escape hatch working.
  ///
  /// Known bypass (pre-existing): copyMultipleLocationsToDate in
  /// trip_provider writes rows straight to the repository without this gate.
  Future<bool> canAddPlace(BuildContext context) async {
    if (_ref.read(isProProvider)) return true;

    if (ownPlaceCount(_ref) < effectiveAllowanceOf(_ref)) return true;

    if (!context.mounted) return false;
    AnalyticsService.instance.paywallViewed('place_limit');
    return await showPaywall(context, trigger: PaywallTrigger.placeLimit);
  }

  /// Batch variant for multi-select adds (map long-press picker): ONE
  /// decision — and at most one paywall — for the whole selection, instead
  /// of re-showing the paywall for every picked place past the allowance.
  ///
  /// Returns how many of [count] requested adds may proceed: all of them
  /// (Pro, within allowance, or upgraded at the paywall), or whatever
  /// allowance remains if the paywall was declined (possibly 0).
  Future<int> canAddPlaces(BuildContext context, int count) async {
    if (count <= 0) return 0;
    if (_ref.read(isProProvider)) return count;

    final remaining = effectiveAllowanceOf(_ref) - ownPlaceCount(_ref);
    if (count <= remaining) return count;

    if (!context.mounted) return remaining.clamp(0, count);
    AnalyticsService.instance.paywallViewed('place_limit');
    final upgraded =
        await showPaywall(context, trigger: PaywallTrigger.placeLimit);
    if (upgraded) return count;
    return remaining.clamp(0, count);
  }

  /// Live count of places the current user created themselves. Anonymous
  /// users have no collaborator rows, so the raw count is already correct;
  /// authenticated rows are stamped with the creator's id on write.
  static int ownPlaceCount(WidgetRef ref) {
    final all = ref.read(savedLocationsProvider).asData?.value ?? const [];
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return all.length;
    return all.where((l) => l.userId == userId).length;
  }
}

final subscriptionLimitServiceProvider =
    Provider.family<SubscriptionLimitService, WidgetRef>(
        (ref, widgetRef) => SubscriptionLimitService(widgetRef));
