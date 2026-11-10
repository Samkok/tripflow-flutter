import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/location_provider.dart';
import '../providers/subscription_provider.dart';
import '../screens/paywall_screen.dart';
import 'analytics_service.dart';
import '../models/saved_location.dart';

/// Gate for adding places. Since 2026-11-10 adding a place is a VoyZa Pro
/// feature for everyone: the free saved-place allowance (5, then 10) is
/// gone and the referral bonus slots are retired. "Pro" includes the store
/// trial, so one isPro check covers both.
///
/// The rule follows the PERSON ADDING, never the trip's owner: a Pro member
/// can add to anyone's trip they may edit, a free member to none.
///
/// Not gated: creating trips, the sample trip, the one free copy of a
/// shared trip, and everything done with places that already exist
/// (reorder, move, schedule, optimize, mark done, share). The Terms
/// (Subscriptions section) say the same in words; change both together.
class SubscriptionLimitService {
  final WidgetRef _ref;

  SubscriptionLimitService(this._ref);

  /// Test seam: stands in for the paywall route.
  @visibleForTesting
  static Future<bool> Function(BuildContext context)? paywallOverride;

  /// The one decision, for doors that only have a context: true when the
  /// person is Pro, or became Pro at the paywall just now.
  static Future<bool> ensureCanAdd(BuildContext context) async {
    final container = ProviderScope.containerOf(context, listen: false);
    if (container.read(isProProvider)) return true;
    AnalyticsService.instance.paywallViewed('place_limit');
    final override = paywallOverride;
    if (override != null) return override(context);
    return await showPaywall(context, trigger: PaywallTrigger.placeLimit);
  }

  /// True when adding a NEW place may proceed; false when the paywall was
  /// shown and dismissed without subscribing.
  Future<bool> canAddPlace(BuildContext context) async {
    if (_ref.read(isProProvider)) return true;
    if (!context.mounted) return false;
    return ensureCanAdd(context);
  }

  /// Batch variant (nearby picker, duplicate, copy to another day): ONE
  /// decision — and at most one paywall — for the whole selection. Returns
  /// [count] when the adds may proceed, else 0.
  Future<int> canAddPlaces(BuildContext context, int count) async {
    if (count <= 0) return 0;
    return await canAddPlace(context) ? count : 0;
  }

  /// Live count of places the current user created themselves. Anonymous
  /// users have no collaborator rows, so the raw count is already correct;
  /// authenticated rows are stamped with the creator's id on write. Places
  /// HANDED OVER from a member who left (see SavedLocation.handedOver) are
  /// the owner's now but were never added by them.
  static int ownPlaceCount(WidgetRef ref) {
    final all = ref.read(savedLocationsProvider).asData?.value ?? const [];
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return all.length;
    return all.where((l) => countsAsOwnPlace(l, userId)).length;
  }

  static bool countsAsOwnPlace(SavedLocation l, String userId) =>
      l.userId == userId && !l.handedOver;
}

final subscriptionLimitServiceProvider =
    Provider.family<SubscriptionLimitService, WidgetRef>(
        (ref, widgetRef) => SubscriptionLimitService(widgetRef));
