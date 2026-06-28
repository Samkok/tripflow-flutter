import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/location_provider.dart';
import '../providers/subscription_provider.dart';
import '../screens/paywall_screen.dart';
import 'paywall_experiment_service.dart';

/// Gate that enforces Pro entitlement on create-location and create-trip
/// flows. With store-managed introductory offers, "Pro" includes the trial
/// period (RevenueCat marks the entitlement active for the trial window),
/// so a single isPro check covers both cases.
///
/// A/B experiment ([PaywallExperimentService]): users in the `freePlaces` arm
/// get a small saved-place allowance before the hard gate so they can reach
/// the route-optimization "aha" first. The `control` arm keeps the immediate
/// paywall.
class SubscriptionLimitService {
  final WidgetRef _ref;

  SubscriptionLimitService(this._ref);

  /// Returns true when the action may proceed. Returns false when the
  /// paywall was shown and the user dismissed it without subscribing.
  Future<bool> canCreate(BuildContext context) async {
    if (_ref.read(isProProvider)) return true;

    // Experiment: the treatment arm may save up to [freePlaceAllowance] places
    // before the paywall. We meter on the live total of saved places — the
    // gate fires on the place that would exceed the allowance.
    final variant = await PaywallExperimentService.instance.variant();
    if (variant == PaywallVariant.freePlaces) {
      final placeCount =
          _ref.read(savedLocationsProvider).asData?.value.length ?? 0;
      if (placeCount < PaywallExperimentService.freePlaceAllowance) {
        return true;
      }
    }

    if (!context.mounted) return false;
    return await showPaywall(context);
  }
}

final subscriptionLimitServiceProvider =
    Provider.family<SubscriptionLimitService, WidgetRef>(
        (ref, widgetRef) => SubscriptionLimitService(widgetRef));
