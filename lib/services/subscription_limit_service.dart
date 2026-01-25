import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/subscription_provider.dart';
import '../repositories/location_repository.dart';
import '../screens/paywall_screen.dart';
import '../services/supabase_service.dart';

/// Configuration for subscription limits
class SubscriptionLimits {
  /// Maximum number of locations for free users
  static const int freeLocationLimit = 5;
}

/// Service to check subscription limits and show paywall when needed
class SubscriptionLimitService {
  final WidgetRef _ref;

  SubscriptionLimitService(this._ref);

  /// Check if user can add more locations
  /// Returns true if user can add, false if limit reached and user didn't upgrade
  Future<bool> canAddLocation(BuildContext context) async {
    // Check if user is Pro - if so, no limits apply
    final isPro = _ref.read(isProProvider);
    if (isPro) {
      return true;
    }

    // Get current location count based on auth state
    final currentCount = await _getUserLocationCount();

    // If under limit, allow
    if (currentCount < SubscriptionLimits.freeLocationLimit) {
      return true;
    }

    // Limit reached - show paywall
    if (context.mounted) {
      final upgraded = await showPaywall(context);
      return upgraded;
    }

    return false;
  }

  /// Get the count of locations for the current user
  /// For authenticated users: locations they created in their own trips + unassigned locations
  /// For anonymous users: local device locations
  Future<int> _getUserLocationCount() async {
    final user = SupabaseService.instance.client.auth.currentUser;

    if (user != null) {
      // Authenticated user - count locations they've created
      return await _getAuthenticatedUserLocationCount(user.id);
    } else {
      // Anonymous user - count local locations
      return await _getAnonymousUserLocationCount();
    }
  }

  /// Get persistent counter for authenticated user
  /// Reads the lifetime locations_added_count from user_profiles table
  /// This counter increments when locations are added, never decrements on delete
  /// Freezes when user is Pro, resumes if they downgrade
  Future<int> _getAuthenticatedUserLocationCount(String userId) async {
    try {
      final supabase = SupabaseService.instance.client;

      // Read the persistent counter from user_profiles
      final response = await supabase
          .from('user_profiles')
          .select('locations_added_count')
          .eq('user_id', userId)
          .single();

      final count = response['locations_added_count'] as int? ?? 0;

      debugPrint('SubscriptionLimitService: User has added $count total locations (persistent counter)');
      return count;
    } catch (e) {
      debugPrint('SubscriptionLimitService: Error reading location counter: $e');
      // Fallback to 0 on error (fail-safe: allow location addition on error)
      return 0;
    }
  }

  /// Count locations for anonymous user (local device storage)
  Future<int> _getAnonymousUserLocationCount() async {
    try {
      final repository = LocationRepository();
      await repository.init();
      final count = await repository.getLocalLocationCount();
      debugPrint('SubscriptionLimitService: Anonymous user has $count local locations');
      return count;
    } catch (e) {
      debugPrint('SubscriptionLimitService: Error counting anonymous locations: $e');
      return 0;
    }
  }

  /// Get remaining free locations
  Future<int> getRemainingFreeLocations() async {
    final isPro = _ref.read(isProProvider);
    if (isPro) {
      return -1; // Unlimited
    }

    final currentCount = await _getUserLocationCount();
    return (SubscriptionLimits.freeLocationLimit - currentCount).clamp(0, SubscriptionLimits.freeLocationLimit);
  }

  /// Check if user has reached the limit
  Future<bool> hasReachedLimit() async {
    final isPro = _ref.read(isProProvider);
    if (isPro) {
      return false;
    }

    final currentCount = await _getUserLocationCount();
    return currentCount >= SubscriptionLimits.freeLocationLimit;
  }
}

/// Provider for the subscription limit service
final subscriptionLimitServiceProvider = Provider.family<SubscriptionLimitService, WidgetRef>((ref, widgetRef) {
  return SubscriptionLimitService(widgetRef);
});
