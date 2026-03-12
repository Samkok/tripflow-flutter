import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/location_model.dart';
import '../models/saved_location.dart';
import '../providers/location_provider.dart';
import '../providers/trip_provider.dart';
import '../services/subscription_limit_service.dart';

/// Central service for adding locations.
/// Handles the subscription paywall check before every add so callers
/// don't need to repeat it.
class LocationAddService {
  final WidgetRef _ref;

  LocationAddService(this._ref);

  /// Adds a [LocationModel] via the active trip context (map / search flow).
  /// Returns true if the location was added, false if the paywall blocked it.
  Future<bool> addLocation(BuildContext context, LocationModel location) async {
    final canAdd =
        await SubscriptionLimitService(_ref).canAddLocation(context);
    if (!canAdd) return false;
    await _ref.read(tripProvider.notifier).addLocation(location);
    return true;
  }

  /// Adds a [SavedLocation] directly to the repository (trip-detail flow).
  /// Returns true if the location was added, false if the paywall blocked it.
  Future<bool> addSavedLocation(
      BuildContext context, SavedLocation location) async {
    final canAdd =
        await SubscriptionLimitService(_ref).canAddLocation(context);
    if (!canAdd) return false;
    await _ref.read(locationRepositoryProvider).addLocation(location);
    return true;
  }
}
