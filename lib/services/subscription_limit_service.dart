import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/subscription_provider.dart';
import '../screens/paywall_screen.dart';

/// Gate that enforces Pro entitlement on create-location and create-trip
/// flows. With store-managed introductory offers, "Pro" includes the trial
/// period (RevenueCat marks the entitlement active for the trial window),
/// so a single isPro check covers both cases.
class SubscriptionLimitService {
  final WidgetRef _ref;

  SubscriptionLimitService(this._ref);

  /// Returns true when the action may proceed. Returns false when the
  /// paywall was shown and the user dismissed it without subscribing.
  Future<bool> canCreate(BuildContext context) async {
    if (_ref.read(isProProvider)) return true;
    if (!context.mounted) return false;
    return await showPaywall(context);
  }
}

final subscriptionLimitServiceProvider =
    Provider.family<SubscriptionLimitService, WidgetRef>(
        (ref, widgetRef) => SubscriptionLimitService(widgetRef));
