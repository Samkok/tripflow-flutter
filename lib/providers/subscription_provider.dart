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

/// Conflict information when database and SDK disagree
class ConflictInfo {
  final String conflictType; // 'expired_vs_active', 'active_vs_expired', 'plan_mismatch', 'renewal_mismatch'
  final String? databaseStatus;
  final String? sdkStatus;
  final String? databaseProductId;
  final String? sdkProductId;
  final bool? databaseWillRenew;
  final bool? sdkWillRenew;
  final DateTime detectedAt;
  final String resolutionStrategy; // 'trust_database', 'trust_sdk', 'trigger_webhook_sync'

  const ConflictInfo({
    required this.conflictType,
    required this.databaseStatus,
    required this.sdkStatus,
    this.databaseProductId,
    this.sdkProductId,
    this.databaseWillRenew,
    this.sdkWillRenew,
    required this.detectedAt,
    required this.resolutionStrategy,
  });

  String get userMessage {
    switch (conflictType) {
      case 'expired_vs_active':
        return 'Your subscription status is being synchronized. You have active access.';
      case 'active_vs_expired':
        return 'Subscription sync in progress. Please refresh in a moment.';
      case 'plan_mismatch':
        return 'Plan details are being updated. This may take a moment.';
      case 'renewal_mismatch':
        return 'Renewal settings are being synchronized.';
      default:
        return 'Subscription details are being synchronized.';
    }
  }

  ConflictInfo copyWith({
    String? conflictType,
    String? databaseStatus,
    String? sdkStatus,
    String? databaseProductId,
    String? sdkProductId,
    bool? databaseWillRenew,
    bool? sdkWillRenew,
    DateTime? detectedAt,
    String? resolutionStrategy,
  }) {
    return ConflictInfo(
      conflictType: conflictType ?? this.conflictType,
      databaseStatus: databaseStatus ?? this.databaseStatus,
      sdkStatus: sdkStatus ?? this.sdkStatus,
      databaseProductId: databaseProductId ?? this.databaseProductId,
      sdkProductId: sdkProductId ?? this.sdkProductId,
      databaseWillRenew: databaseWillRenew ?? this.databaseWillRenew,
      sdkWillRenew: sdkWillRenew ?? this.sdkWillRenew,
      detectedAt: detectedAt ?? this.detectedAt,
      resolutionStrategy: resolutionStrategy ?? this.resolutionStrategy,
    );
  }
}

/// Subscription state for the notifier
class SubscriptionState {
  final bool isLoading;
  final bool isPro;
  final String? errorMessage;
  final CustomerInfo? customerInfo;

  // Database-first fields
  final String? databaseStatus; // 'active', 'expired', null if not loaded
  final DateTime? lastDatabaseUpdate;
  final ConflictInfo? activeConflict;
  final bool isDatabasePrimary; // true = use database as source of truth, false = fallback to SDK
  final bool? databaseWillRenew;
  final DateTime? databaseExpiresAt;
  final String? databaseProductId;

  const SubscriptionState({
    this.isLoading = false,
    this.isPro = false,
    this.errorMessage,
    this.customerInfo,
    this.databaseStatus,
    this.lastDatabaseUpdate,
    this.activeConflict,
    this.isDatabasePrimary = true,
    this.databaseWillRenew,
    this.databaseExpiresAt,
    this.databaseProductId,
  });

  SubscriptionState copyWith({
    bool? isLoading,
    bool? isPro,
    String? errorMessage,
    CustomerInfo? customerInfo,
    String? databaseStatus,
    DateTime? lastDatabaseUpdate,
    ConflictInfo? activeConflict,
    bool? isDatabasePrimary,
    bool? databaseWillRenew,
    DateTime? databaseExpiresAt,
    String? databaseProductId,
    bool clearConflict = false,
  }) {
    return SubscriptionState(
      isLoading: isLoading ?? this.isLoading,
      isPro: isPro ?? this.isPro,
      errorMessage: errorMessage,
      customerInfo: customerInfo ?? this.customerInfo,
      databaseStatus: databaseStatus ?? this.databaseStatus,
      lastDatabaseUpdate: lastDatabaseUpdate ?? this.lastDatabaseUpdate,
      activeConflict: clearConflict ? null : (activeConflict ?? this.activeConflict),
      isDatabasePrimary: isDatabasePrimary ?? this.isDatabasePrimary,
      databaseWillRenew: databaseWillRenew ?? this.databaseWillRenew,
      databaseExpiresAt: databaseExpiresAt ?? this.databaseExpiresAt,
      databaseProductId: databaseProductId ?? this.databaseProductId,
    );
  }
}

/// Notifier for managing subscription actions
class SubscriptionNotifier extends StateNotifier<SubscriptionState> {
  final RevenueCatService _service;
  StreamSubscription<CustomerInfo>? _subscription;
  StreamSubscription<SubscriptionEvent>? _realtimeSubscription;
  Timer? _expirationCheckTimer;
  Timer? _conflictMonitoringTimer;

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

    // Initialize realtime subscription for subscription changes (database-first)
    await _initializeRealtimeSubscription();

    // Start periodic conflict monitoring
    _startConflictMonitoring();
  }

  /// Initialize Supabase Realtime subscription for subscription status changes
  /// This provides near-instant detection of subscription expiration (<2 seconds)
  Future<void> _initializeRealtimeSubscription() async {
    try {
      // Wait for Supabase to be initialized before starting realtime subscriptions
      await SupabaseService.waitForInitialization();

      debugPrint('SubscriptionProvider: Initializing realtime subscription (database-first)');

      final realtimeService = SubscriptionRealtimeService();
      await realtimeService.subscribe();

      _realtimeSubscription = realtimeService.eventStream.listen(
        (event) {
          _handleRealtimeEvent(event);
        },
        onError: (error) {
          debugPrint('SubscriptionProvider: ⚠️ Realtime stream error: $error');
          _handleRealtimeFailure();
        },
      );

      debugPrint('SubscriptionProvider: ✅ Realtime subscription initialized');
    } catch (e) {
      debugPrint('SubscriptionProvider: ⚠️ Failed to initialize realtime subscription: $e');
      _handleRealtimeFailure();
    }
  }

  /// Handle realtime subscription failure - gracefully degrade to SDK-first mode
  void _handleRealtimeFailure() {
    debugPrint('SubscriptionProvider: 🔻 Degrading to SDK-first mode due to realtime failure');

    state = state.copyWith(
      isDatabasePrimary: false,
      errorMessage: 'Using local subscription data',
    );

    // In degraded mode, rely on SDK as primary source
    // Conflict monitoring will continue to attempt database validation
    debugPrint('SubscriptionProvider: ⚠️ App will use RevenueCat SDK as primary source');
  }

  /// Handle realtime subscription events from Supabase (database-first approach)
  void _handleRealtimeEvent(SubscriptionEvent event) {
    debugPrint('SubscriptionProvider: 📨 Realtime event received - $event');

    if (!state.isDatabasePrimary) {
      debugPrint('SubscriptionProvider: ⚠️ Database not primary, ignoring realtime event');
      return;
    }

    // Update from database status - this is now our primary source of truth
    if (event.data != null) {
      _updateFromDatabaseStatus(event.data!);
    } else {
      // Fallback if data is null - construct from event fields
      final record = {
        'status': event.status,
        'will_renew': event.willRenew,
        'expires_at': event.expiresAt?.toIso8601String(),
        'product_id': event.productIdentifier,
      };
      _updateFromDatabaseStatus(record);
    }

    debugPrint('SubscriptionProvider: ✨ State updated from database via realtime - isPro: ${state.isPro}');

    // Validate against SDK for conflict detection (async, non-blocking)
    _validateAgainstSDK();
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

  /// Update state from database subscription status (database-first approach)
  void _updateFromDatabaseStatus(Map<String, dynamic> record) {
    debugPrint('SubscriptionProvider: 🗄️ Updating from database status');

    final databaseStatus = record['status'] as String?;
    final willRenew = record['will_renew'] as bool?;
    final expiresAtStr = record['expires_at'] as String?;
    final productId = record['product_id'] as String?;

    final expiresAt = expiresAtStr != null ? DateTime.tryParse(expiresAtStr) : null;
    final isPro = databaseStatus == 'active';

    debugPrint('SubscriptionProvider: Database status = $databaseStatus, isPro = $isPro');
    debugPrint('SubscriptionProvider: Will renew = $willRenew, Expires at = $expiresAt');
    debugPrint('SubscriptionProvider: Product ID = $productId');

    state = state.copyWith(
      isPro: isPro,
      databaseStatus: databaseStatus,
      lastDatabaseUpdate: DateTime.now(),
      databaseWillRenew: willRenew,
      databaseExpiresAt: expiresAt,
      databaseProductId: productId,
    );

    // Validate against SDK to detect conflicts
    _validateAgainstSDK();
  }

  /// Validate database status against RevenueCat SDK to detect conflicts
  Future<void> _validateAgainstSDK() async {
    if (!state.isDatabasePrimary) {
      // If database is not primary (degraded mode), skip validation
      return;
    }

    try {
      debugPrint('SubscriptionProvider: 🔍 Validating database against SDK');

      final customerInfo = await _service.getCustomerInfo();
      if (customerInfo == null) {
        debugPrint('SubscriptionProvider: ⚠️ SDK returned null customer info');
        return;
      }

      final sdkIsPro = customerInfo.entitlements.active.containsKey(RevenueCatConfig.entitlementVoyZaPro);
      final sdkStatus = sdkIsPro ? 'active' : 'expired';

      // Get SDK product ID
      String? sdkProductId;
      if (sdkIsPro) {
        final entitlement = customerInfo.entitlements.active[RevenueCatConfig.entitlementVoyZaPro];
        sdkProductId = entitlement?.productIdentifier;
      }

      // Get SDK will renew
      bool? sdkWillRenew;
      if (sdkIsPro) {
        final entitlement = customerInfo.entitlements.active[RevenueCatConfig.entitlementVoyZaPro];
        sdkWillRenew = entitlement?.willRenew;
      }

      final dbStatus = state.databaseStatus;
      final dbProductId = state.databaseProductId;
      final dbWillRenew = state.databaseWillRenew;

      // Check for conflicts
      ConflictInfo? conflict;

      if (dbStatus == 'expired' && sdkStatus == 'active') {
        // Database says expired but SDK says active - trust SDK (user likely just purchased)
        debugPrint('SubscriptionProvider: ⚠️ CONFLICT: Database expired but SDK active');
        conflict = ConflictInfo(
          conflictType: 'expired_vs_active',
          databaseStatus: dbStatus,
          sdkStatus: sdkStatus,
          databaseProductId: dbProductId,
          sdkProductId: sdkProductId,
          databaseWillRenew: dbWillRenew,
          sdkWillRenew: sdkWillRenew,
          detectedAt: DateTime.now(),
          resolutionStrategy: 'trust_sdk',
        );
      } else if (dbStatus == 'active' && sdkStatus == 'expired') {
        // Database says active but SDK says expired - trust database during grace period
        debugPrint('SubscriptionProvider: ⚠️ CONFLICT: Database active but SDK expired');
        conflict = ConflictInfo(
          conflictType: 'active_vs_expired',
          databaseStatus: dbStatus,
          sdkStatus: sdkStatus,
          databaseProductId: dbProductId,
          sdkProductId: sdkProductId,
          databaseWillRenew: dbWillRenew,
          sdkWillRenew: sdkWillRenew,
          detectedAt: DateTime.now(),
          resolutionStrategy: 'trust_database',
        );
      } else if (dbStatus == 'active' && sdkStatus == 'active' && dbProductId != sdkProductId && dbProductId != null && sdkProductId != null) {
        // Both active but different products - trigger webhook sync
        debugPrint('SubscriptionProvider: ⚠️ CONFLICT: Product mismatch - DB: $dbProductId, SDK: $sdkProductId');
        conflict = ConflictInfo(
          conflictType: 'plan_mismatch',
          databaseStatus: dbStatus,
          sdkStatus: sdkStatus,
          databaseProductId: dbProductId,
          sdkProductId: sdkProductId,
          databaseWillRenew: dbWillRenew,
          sdkWillRenew: sdkWillRenew,
          detectedAt: DateTime.now(),
          resolutionStrategy: 'trigger_webhook_sync',
        );
      } else if (dbStatus == 'active' && sdkStatus == 'active' && dbWillRenew != sdkWillRenew && dbWillRenew != null && sdkWillRenew != null) {
        // Both active but different renewal status
        debugPrint('SubscriptionProvider: ⚠️ CONFLICT: Renewal mismatch - DB: $dbWillRenew, SDK: $sdkWillRenew');
        conflict = ConflictInfo(
          conflictType: 'renewal_mismatch',
          databaseStatus: dbStatus,
          sdkStatus: sdkStatus,
          databaseProductId: dbProductId,
          sdkProductId: sdkProductId,
          databaseWillRenew: dbWillRenew,
          sdkWillRenew: sdkWillRenew,
          detectedAt: DateTime.now(),
          resolutionStrategy: 'trigger_webhook_sync',
        );
      } else if (dbStatus == 'expired' && sdkStatus == 'expired') {
        // CRITICAL FIX: Both database and SDK agree subscription is expired
        // Explicitly clear any lingering conflicts from previous states
        debugPrint('SubscriptionProvider: ✅ Both expired - clearing any conflicts');
        if (state.activeConflict != null) {
          debugPrint('SubscriptionProvider: → Clearing lingering conflict');
          state = state.copyWith(clearConflict: true);
        }
        return; // Early return, no need to check further
      } else {
        debugPrint('SubscriptionProvider: ✅ No conflicts detected');
      }

      if (conflict != null) {
        state = state.copyWith(activeConflict: conflict);
        _resolveConflict(conflict);
      } else {
        // Clear any existing conflict
        if (state.activeConflict != null) {
          debugPrint('SubscriptionProvider: ✅ Conflict resolved');
          state = state.copyWith(clearConflict: true);
        }
      }
    } catch (e) {
      debugPrint('SubscriptionProvider: ⚠️ Error validating against SDK: $e');
      // Don't crash, just log the error
    }
  }

  /// Resolve detected conflict between database and SDK
  Future<void> _resolveConflict(ConflictInfo conflict) async {
    debugPrint('SubscriptionProvider: 🔧 Resolving conflict: ${conflict.conflictType}');
    debugPrint('SubscriptionProvider: Strategy: ${conflict.resolutionStrategy}');

    switch (conflict.resolutionStrategy) {
      case 'trust_sdk':
        // Database is stale, SDK just processed a purchase - trust SDK and trigger webhook
        debugPrint('SubscriptionProvider: → Trusting SDK (likely fresh purchase)');
        await _triggerWebhookSync();
        // Temporarily use SDK data while webhook processes
        final customerInfo = state.customerInfo;
        if (customerInfo != null) {
          _updateFromCustomerInfo(customerInfo);
        }

        // CRITICAL FIX: Explicitly clear the conflict after resolution
        debugPrint('SubscriptionProvider: → Clearing conflict after SDK trust');
        state = state.copyWith(clearConflict: true);
        break;

      case 'trust_database':
        // Trust database during grace period after cancellation
        debugPrint('SubscriptionProvider: → Trusting database (grace period)');
        // Database is already the source of truth, no action needed
        // SDK will eventually catch up when user restarts app or when webhook fires

        // CRITICAL FIX: Explicitly clear the conflict after resolution
        debugPrint('SubscriptionProvider: → Clearing conflict after database trust');
        state = state.copyWith(clearConflict: true);
        break;

      case 'trigger_webhook_sync':
        // Product or renewal mismatch - trigger webhook to resync
        debugPrint('SubscriptionProvider: → Triggering webhook sync');
        await _triggerWebhookSync();

        // CRITICAL FIX: Explicitly clear the conflict after sync
        debugPrint('SubscriptionProvider: → Clearing conflict after webhook sync');
        state = state.copyWith(clearConflict: true);
        break;

      default:
        debugPrint('SubscriptionProvider: ⚠️ Unknown resolution strategy');
        // Clear conflict anyway to prevent stuck state
        state = state.copyWith(clearConflict: true);
    }
  }

  /// Trigger a webhook sync by refreshing RevenueCat customer info
  /// This forces RevenueCat to send a webhook with the latest subscription state
  Future<void> _triggerWebhookSync() async {
    try {
      debugPrint('SubscriptionProvider: 🔄 Triggering webhook sync via SDK refresh');
      await _service.getCustomerInfo();
      debugPrint('SubscriptionProvider: ✅ Webhook sync triggered');
    } catch (e) {
      debugPrint('SubscriptionProvider: ⚠️ Failed to trigger webhook sync: $e');
    }
  }

  /// Start periodic conflict monitoring (every 30 seconds)
  void _startConflictMonitoring() {
    debugPrint('SubscriptionProvider: 🕐 Starting conflict monitoring');
    _conflictMonitoringTimer?.cancel();
    _conflictMonitoringTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _performConflictCheck(),
    );
  }

  /// Perform a conflict check between database and SDK
  Future<void> _performConflictCheck() async {
    if (!state.isDatabasePrimary) {
      // Skip if in degraded mode
      return;
    }

    if (state.databaseStatus == null) {
      // No database data yet
      return;
    }

    debugPrint('SubscriptionProvider: 🔍 Performing periodic conflict check');
    await _validateAgainstSDK();
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
    _conflictMonitoringTimer?.cancel();
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
