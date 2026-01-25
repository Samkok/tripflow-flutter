import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../services/revenuecat_service.dart';
import '../services/subscription_realtime_service.dart';
import '../services/supabase_service.dart';

/// Provider for the RevenueCat service singleton
final revenueCatServiceProvider = Provider<RevenueCatService>((ref) {
  return RevenueCatService();
});

/// Provider for customer info stream
final customerInfoStreamProvider = StreamProvider<CustomerInfo>((ref) {
  final service = ref.watch(revenueCatServiceProvider);
  return service.customerInfoStream;
});

/// Provider for current customer info
final customerInfoProvider = FutureProvider<CustomerInfo?>((ref) async {
  // Watch the stream to get updates
  ref.watch(customerInfoStreamProvider);

  try {
    final service = ref.read(revenueCatServiceProvider);
    return await service.getCustomerInfo();
  } catch (e) {
    debugPrint('customerInfoProvider: Failed to get customer info - $e');
    return null;
  }
});

/// Provider to check if user has VoyZa Pro entitlement
final hasVoyZaProProvider = FutureProvider<bool>((ref) async {
  // Watch customer info to react to changes
  final customerInfoAsync = ref.watch(customerInfoProvider);

  return customerInfoAsync.when(
    data: (customerInfo) {
      if (customerInfo == null) return false;
      return customerInfo.entitlements.active
          .containsKey(RevenueCatConfig.entitlementVoyZaPro);
    },
    loading: () => false,
    error: (_, __) => false,
  );
});

/// Provider for VoyZa Pro entitlement details
final voyZaProEntitlementProvider = FutureProvider<EntitlementInfo?>((ref) async {
  final customerInfoAsync = ref.watch(customerInfoProvider);

  return customerInfoAsync.when(
    data: (customerInfo) {
      if (customerInfo == null) return null;
      return customerInfo.entitlements.active[RevenueCatConfig.entitlementVoyZaPro];
    },
    loading: () => null,
    error: (_, __) => null,
  );
});

/// Provider for available offerings
final offeringsProvider = FutureProvider<Offerings?>((ref) async {
  try {
    final service = ref.read(revenueCatServiceProvider);
    return await service.getOfferings();
  } catch (e) {
    debugPrint('offeringsProvider: Failed to get offerings - $e');
    return null;
  }
});

/// Provider for current offering
final currentOfferingProvider = FutureProvider<Offering?>((ref) async {
  final offeringsAsync = ref.watch(offeringsProvider);

  return offeringsAsync.when(
    data: (offerings) => offerings?.current,
    loading: () => null,
    error: (_, __) => null,
  );
});

/// Provider for available packages
final availablePackagesProvider = FutureProvider<List<Package>>((ref) async {
  final offeringAsync = ref.watch(currentOfferingProvider);

  return offeringAsync.when(
    data: (offering) => offering?.availablePackages ?? [],
    loading: () => [],
    error: (_, __) => [],
  );
});

/// Provider for monthly package
final monthlyPackageProvider = FutureProvider<Package?>((ref) async {
  final packagesAsync = ref.watch(availablePackagesProvider);

  return packagesAsync.when(
    data: (packages) {
      try {
        return packages.firstWhere((p) => p.packageType == PackageType.monthly);
      } catch (e) {
        return null;
      }
    },
    loading: () => null,
    error: (_, __) => null,
  );
});

/// Provider for yearly package
final yearlyPackageProvider = FutureProvider<Package?>((ref) async {
  final packagesAsync = ref.watch(availablePackagesProvider);

  return packagesAsync.when(
    data: (packages) {
      try {
        return packages.firstWhere((p) => p.packageType == PackageType.annual);
      } catch (e) {
        return null;
      }
    },
    loading: () => null,
    error: (_, __) => null,
  );
});

/// Subscription state for the notifier
class SubscriptionState {
  final bool isLoading;
  final bool isPro;
  final String? errorMessage;
  final CustomerInfo? customerInfo;

  const SubscriptionState({
    this.isLoading = false,
    this.isPro = false,
    this.errorMessage,
    this.customerInfo,
  });

  SubscriptionState copyWith({
    bool? isLoading,
    bool? isPro,
    String? errorMessage,
    CustomerInfo? customerInfo,
  }) {
    return SubscriptionState(
      isLoading: isLoading ?? this.isLoading,
      isPro: isPro ?? this.isPro,
      errorMessage: errorMessage,
      customerInfo: customerInfo ?? this.customerInfo,
    );
  }
}

/// Notifier for managing subscription actions
class SubscriptionNotifier extends StateNotifier<SubscriptionState> {
  final RevenueCatService _service;
  StreamSubscription<CustomerInfo>? _subscription;
  StreamSubscription<SubscriptionEvent>? _realtimeSubscription;
  Timer? _expirationCheckTimer;

  SubscriptionNotifier(this._service)
      : super(const SubscriptionState()) {
    _initialize();
  }

  Future<void> _initialize() async {
    // Listen to customer info updates from RevenueCat SDK
    _subscription = _service.customerInfoStream.listen((info) {
      _updateFromCustomerInfo(info);
    });

    // Load initial state
    await refresh();

    // Initialize realtime subscription for subscription changes
    _initializeRealtimeSubscription();
  }

  /// Initialize Supabase Realtime subscription for subscription status changes
  /// This provides near-instant detection of subscription expiration (<2 seconds)
  Future<void> _initializeRealtimeSubscription() async {
    try {
      // Wait for Supabase to be initialized before starting realtime subscriptions
      await SupabaseService.waitForInitialization();

      debugPrint('SubscriptionProvider: Initializing realtime subscription');

      final realtimeService = SubscriptionRealtimeService();
      await realtimeService.subscribe();

      _realtimeSubscription = realtimeService.eventStream.listen((event) {
        _handleRealtimeEvent(event);
      });

      debugPrint('SubscriptionProvider: ✅ Realtime subscription initialized');
    } catch (e) {
      debugPrint('SubscriptionProvider: ⚠️ Failed to initialize realtime subscription: $e');
      // Don't crash the app if realtime subscription fails
      // The app resume check and RevenueCat listener are fallbacks
    }
  }

  /// Handle realtime subscription events from Supabase
  void _handleRealtimeEvent(SubscriptionEvent event) {
    debugPrint('SubscriptionProvider: 📨 Realtime event received - $event');

    // Determine if user has Pro based on the event
    final isPro = event.status == 'active' &&
                  event.entitlement == RevenueCatConfig.entitlementVoyZaPro;

    // Update state immediately
    state = state.copyWith(
      isPro: isPro,
      isLoading: false,
    );

    debugPrint('SubscriptionProvider: ✨ State updated from realtime event - isPro: $isPro');

    // Sync with RevenueCat for major changes to ensure consistency
    // This is a background sync that keeps RevenueCat SDK in sync with Supabase
    if (event.type == SubscriptionEventType.expired ||
        event.type == SubscriptionEventType.activated ||
        event.type == SubscriptionEventType.renewed) {
      debugPrint('SubscriptionProvider: 🔄 Syncing with RevenueCat after major event');
      refresh();
    }
  }

  void _updateFromCustomerInfo(CustomerInfo info) {
    final isPro = info.entitlements.active
        .containsKey(RevenueCatConfig.entitlementVoyZaPro);

    debugPrint('SubscriptionProvider: Updating from customer info');
    debugPrint('SubscriptionProvider: Active entitlements: ${info.entitlements.active.keys.toList()}');
    debugPrint('SubscriptionProvider: Looking for entitlement: ${RevenueCatConfig.entitlementVoyZaPro}');
    debugPrint('SubscriptionProvider: isPro = $isPro');

    state = state.copyWith(
      isPro: isPro,
      customerInfo: info,
      isLoading: false,
    );

    debugPrint('SubscriptionProvider: State updated, new isPro = ${state.isPro}');

    // Schedule a check near expiration time if Pro
    // _scheduleExpirationCheck(info);
  }

  /// Schedule a check just before the subscription expires
  // void _scheduleExpirationCheck(CustomerInfo info) {
  //   // Cancel any existing timer
  //   _expirationCheckTimer?.cancel();

  //   // Get the Pro entitlement if it exists
  //   final proEntitlement = info.entitlements.all[RevenueCatConfig.entitlementVoyZaPro];
  //   if (proEntitlement == null) return;

  //   // Get expiration date
  //   final expirationDateStr = proEntitlement.expirationDate;
  //   if (expirationDateStr == null) return;

  //   final expirationDate = DateTime.tryParse(expirationDateStr);
  //   if (expirationDate == null) return;

  //   // Calculate time until expiration
  //   final now = DateTime.now();
  //   final timeUntilExpiration = expirationDate.difference(now);

  //   // If already expired, refresh immediately
  //   if (timeUntilExpiration.isNegative) {
  //     debugPrint('SubscriptionProvider: Subscription already expired, refreshing now');
  //     refresh();
  //     return;
  //   }

  //   // Schedule a refresh 1 minute before expiration
  //   final checkTime = timeUntilExpiration - const Duration(minutes: 1);
  //   if (checkTime.isNegative) {
  //     // Less than 1 minute until expiration, check in 10 seconds
  //     debugPrint('SubscriptionProvider: Subscription expires very soon, checking in 10 seconds');
  //     _expirationCheckTimer = Timer(const Duration(seconds: 10), () async {
  //       debugPrint('SubscriptionProvider: Checking subscription near expiration time');
  //       await refresh();
  //     });
  //   } else {
  //     debugPrint('SubscriptionProvider: Scheduled expiration check in ${checkTime.inMinutes} minutes');
  //     _expirationCheckTimer = Timer(checkTime, () async {
  //       debugPrint('SubscriptionProvider: Checking subscription near expiration time');
  //       await refresh();
  //     });
  //   }
  // }

  /// Refresh subscription status
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final customerInfo = await _service.getCustomerInfo();
      _updateFromCustomerInfo(customerInfo);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Failed to load subscription status',
      );
    }
  }

  /// Purchase monthly subscription
  Future<bool> purchaseMonthly() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final result = await _service.purchaseMonthly();
      if (result.success && result.customerInfo != null) {
        _updateFromCustomerInfo(result.customerInfo!);
        return true;
      } else if (result.userCancelled) {
        state = state.copyWith(isLoading: false);
        return false;
      } else {
        state = state.copyWith(
          isLoading: false,
          errorMessage: result.errorMessage,
        );
        return false;
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Purchase failed. Please try again.',
      );
      return false;
    }
  }

  /// Purchase yearly subscription
  Future<bool> purchaseYearly() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final result = await _service.purchaseYearly();
      if (result.success && result.customerInfo != null) {
        _updateFromCustomerInfo(result.customerInfo!);
        return true;
      } else if (result.userCancelled) {
        state = state.copyWith(isLoading: false);
        return false;
      } else {
        state = state.copyWith(
          isLoading: false,
          errorMessage: result.errorMessage,
        );
        return false;
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Purchase failed. Please try again.',
      );
      return false;
    }
  }

  /// Purchase a specific package
  Future<bool> purchasePackage(Package package) async {
    debugPrint('SubscriptionProvider: Starting purchase for package: ${package.identifier}');
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final result = await _service.purchasePackage(package);
      debugPrint('SubscriptionProvider: Purchase result - success: ${result.success}, cancelled: ${result.userCancelled}');

      if (result.success && result.customerInfo != null) {
        debugPrint('SubscriptionProvider: Purchase successful, updating from customer info');
        _updateFromCustomerInfo(result.customerInfo!);
        return true;
      } else if (result.userCancelled) {
        debugPrint('SubscriptionProvider: Purchase cancelled by user');
        state = state.copyWith(isLoading: false);
        return false;
      } else {
        debugPrint('SubscriptionProvider: Purchase failed - ${result.errorMessage}');
        state = state.copyWith(
          isLoading: false,
          errorMessage: result.errorMessage,
        );
        return false;
      }
    } catch (e) {
      debugPrint('SubscriptionProvider: Purchase exception - $e');
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Purchase failed. Please try again.',
      );
      return false;
    }
  }

  /// Restore purchases
  Future<bool> restorePurchases() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final result = await _service.restorePurchases();
      if (result.success && result.customerInfo != null) {
        _updateFromCustomerInfo(result.customerInfo!);
        return true;
      } else {
        state = state.copyWith(
          isLoading: false,
          errorMessage: result.errorMessage,
        );
        return false;
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Restore failed. Please try again.',
      );
      return false;
    }
  }

  /// Change subscription plan
  Future<bool> changePlan(Package newPackage) async {
    debugPrint('SubscriptionProvider: Changing plan to: ${newPackage.identifier}');
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final result = await _service.changePlan(newPackage);
      debugPrint('SubscriptionProvider: Plan change result - success: ${result.success}');

      if (result.success && result.customerInfo != null) {
        debugPrint('SubscriptionProvider: Plan change successful');
        _updateFromCustomerInfo(result.customerInfo!);
        return true;
      } else if (result.userCancelled) {
        debugPrint('SubscriptionProvider: Plan change cancelled by user');
        state = state.copyWith(isLoading: false);
        return false;
      } else {
        debugPrint('SubscriptionProvider: Plan change failed - ${result.errorMessage}');
        state = state.copyWith(
          isLoading: false,
          errorMessage: result.errorMessage,
        );
        return false;
      }
    } catch (e) {
      debugPrint('SubscriptionProvider: Plan change exception - $e');
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Failed to change plan. Please try again.',
      );
      return false;
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _realtimeSubscription?.cancel();
    _expirationCheckTimer?.cancel();
    super.dispose();
  }
}

/// Provider for subscription notifier
final subscriptionProvider =
    StateNotifierProvider<SubscriptionNotifier, SubscriptionState>((ref) {
  final service = ref.watch(revenueCatServiceProvider);
  return SubscriptionNotifier(service);
});

/// Convenience provider for checking if user is pro
final isProProvider = Provider<bool>((ref) {
  final state = ref.watch(subscriptionProvider);
  return state.isPro;
});

/// Convenience provider for subscription loading state
final subscriptionLoadingProvider = Provider<bool>((ref) {
  final state = ref.watch(subscriptionProvider);
  return state.isLoading;
});

/// Provider for subscription expiration date
final subscriptionExpirationProvider = FutureProvider<DateTime?>((ref) async {
  final entitlementAsync = ref.watch(voyZaProEntitlementProvider);

  return entitlementAsync.when(
    data: (entitlement) {
      if (entitlement == null) return null;
      final expirationDate = entitlement.expirationDate;
      if (expirationDate == null) return null;
      return DateTime.tryParse(expirationDate);
    },
    loading: () => null,
    error: (_, __) => null,
  );
});

/// Provider to check if subscription will renew
final willRenewProvider = FutureProvider<bool>((ref) async {
  final entitlementAsync = ref.watch(voyZaProEntitlementProvider);

  return entitlementAsync.when(
    data: (entitlement) {
      if (entitlement == null) return false;
      return entitlement.willRenew;
    },
    loading: () => false,
    error: (_, __) => false,
  );
});

/// Provider for management URL
final managementUrlProvider = FutureProvider<String?>((ref) async {
  final customerInfoAsync = ref.watch(customerInfoProvider);

  return customerInfoAsync.when(
    data: (customerInfo) => customerInfo?.managementURL,
    loading: () => null,
    error: (_, __) => null,
  );
});

/// Provider for current product identifier
final currentProductIdProvider = FutureProvider<String?>((ref) async {
  final service = ref.read(revenueCatServiceProvider);
  return await service.getCurrentProductId();
});

/// Provider to check if user is on monthly plan
final isMonthlyPlanProvider = FutureProvider<bool>((ref) async {
  final productIdAsync = ref.watch(currentProductIdProvider);

  return productIdAsync.when(
    data: (productId) => productId?.contains('monthly') ?? false,
    loading: () => false,
    error: (_, __) => false,
  );
});

/// Provider to check if user is on yearly plan
final isYearlyPlanProvider = FutureProvider<bool>((ref) async {
  final productIdAsync = ref.watch(currentProductIdProvider);

  return productIdAsync.when(
    data: (productId) => productId?.contains('yearly') ?? false,
    loading: () => false,
    error: (_, __) => false,
  );
});
