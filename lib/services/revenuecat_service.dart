import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

/// RevenueCat configuration constants
class RevenueCatConfig {
  /// Entitlement identifier for VoyZa Pro
  static const String entitlementVoyZaPro = 'VoyZa Pro';

  /// Product identifiers
  static const String productMonthly = 'monthly';
  static const String productYearly = 'yearly';

  /// Offering identifier (default)
  static const String defaultOffering = 'default';
}

/// Result class for purchase operations
class RevenueCatPurchaseResult {
  final bool success;
  final String? errorMessage;
  final CustomerInfo? customerInfo;
  final bool userCancelled;

  const RevenueCatPurchaseResult({
    required this.success,
    this.errorMessage,
    this.customerInfo,
    this.userCancelled = false,
  });

  factory RevenueCatPurchaseResult.success(CustomerInfo info) =>
      RevenueCatPurchaseResult(
        success: true,
        customerInfo: info,
      );

  factory RevenueCatPurchaseResult.error(String message) =>
      RevenueCatPurchaseResult(
        success: false,
        errorMessage: message,
      );

  factory RevenueCatPurchaseResult.cancelled() => const RevenueCatPurchaseResult(
        success: false,
        userCancelled: true,
      );
}

/// Service for managing RevenueCat subscriptions and purchases
class RevenueCatService {
  static final RevenueCatService _instance = RevenueCatService._internal();
  factory RevenueCatService() => _instance;
  RevenueCatService._internal();

  static bool _isInitialized = false;
  static final Completer<void> _initCompleter = Completer<void>();

  /// Stream controller for customer info updates
  final _customerInfoController = StreamController<CustomerInfo>.broadcast();
  Stream<CustomerInfo> get customerInfoStream => _customerInfoController.stream;

  /// Check if RevenueCat is initialized
  static bool get isInitialized => _isInitialized;

  /// Wait for RevenueCat initialization
  static Future<void> waitForInitialization() async {
    if (_isInitialized) return;
    await _initCompleter.future;
  }

  /// Initialize RevenueCat SDK
  /// Should be called once during app startup
  static Future<void> initialize() async {
    if (_isInitialized) {
      debugPrint('RevenueCatService: Already initialized');
      return;
    }

    try {
      // Get platform-specific API key
      final apiKey = Platform.isIOS
          ? dotenv.env['REVENUECAT_API_KEY_IOS']
          : dotenv.env['REVENUECAT_API_KEY_ANDROID'];

      if (apiKey == null || apiKey.isEmpty) {
        final platform = Platform.isIOS ? 'iOS' : 'Android';
        throw Exception('REVENUECAT_API_KEY_$platform not found in .env file');
      }

      debugPrint('RevenueCatService: Initializing with API key for ${Platform.isIOS ? 'iOS' : 'Android'}...');

      // Configure RevenueCat
      final configuration = PurchasesConfiguration(apiKey);

      // Enable debug logs in debug mode
      if (kDebugMode) {
        await Purchases.setLogLevel(LogLevel.debug);
      }

      await Purchases.configure(configuration);

      // Set up listener for customer info updates
      Purchases.addCustomerInfoUpdateListener((customerInfo) {
        debugPrint('RevenueCatService: Customer info updated via listener');
        debugPrint('RevenueCatService: Listener - Active entitlements: ${customerInfo.entitlements.active.keys.toList()}');
        debugPrint('RevenueCatService: Listener - All entitlements: ${customerInfo.entitlements.all.keys.toList()}');
        RevenueCatService()._customerInfoController.add(customerInfo);
      });

      _isInitialized = true;
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }

      debugPrint('RevenueCatService: Initialized successfully');
    } catch (e, stackTrace) {
      debugPrint('RevenueCatService: Initialization failed - $e');
      debugPrint('Stack trace: $stackTrace');
      if (!_initCompleter.isCompleted) {
        _initCompleter.completeError(e);
      }
      rethrow;
    }
  }

  /// Login a user to RevenueCat
  /// This associates the user's purchases with their app user ID
  Future<CustomerInfo> login(String appUserId) async {
    await waitForInitialization();
    try {
      debugPrint('RevenueCatService: Logging in user: $appUserId');
      final result = await Purchases.logIn(appUserId);
      debugPrint('RevenueCatService: Login successful');
      return result.customerInfo;
    } catch (e) {
      debugPrint('RevenueCatService: Login failed - $e');
      rethrow;
    }
  }

  /// Logout the current user
  /// This creates a new anonymous user
  Future<CustomerInfo> logout() async {
    await waitForInitialization();
    try {
      debugPrint('RevenueCatService: Logging out user');
      final customerInfo = await Purchases.logOut();
      debugPrint('RevenueCatService: Logout successful');
      return customerInfo;
    } catch (e) {
      debugPrint('RevenueCatService: Logout failed - $e');
      rethrow;
    }
  }

  /// Get current customer info
  Future<CustomerInfo> getCustomerInfo() async {
    await waitForInitialization();
    try {
      final customerInfo = await Purchases.getCustomerInfo();
      debugPrint('RevenueCatService: Retrieved customer info');
      debugPrint('RevenueCatService: Active entitlements: ${customerInfo.entitlements.active.keys.toList()}');
      debugPrint('RevenueCatService: All entitlements: ${customerInfo.entitlements.all.keys.toList()}');
      return customerInfo;
    } catch (e) {
      debugPrint('RevenueCatService: Failed to get customer info - $e');
      rethrow;
    }
  }

  /// Check if user has VoyZa Pro entitlement
  Future<bool> hasVoyZaProEntitlement() async {
    try {
      final customerInfo = await getCustomerInfo();
      return customerInfo.entitlements.active
          .containsKey(RevenueCatConfig.entitlementVoyZaPro);
    } catch (e) {
      debugPrint('RevenueCatService: Failed to check entitlement - $e');
      return false;
    }
  }

  /// Get the VoyZa Pro entitlement info if active
  Future<EntitlementInfo?> getVoyZaProEntitlement() async {
    try {
      final customerInfo = await getCustomerInfo();
      return customerInfo
          .entitlements.active[RevenueCatConfig.entitlementVoyZaPro];
    } catch (e) {
      debugPrint('RevenueCatService: Failed to get entitlement info - $e');
      return null;
    }
  }

  /// Get available offerings
  Future<Offerings> getOfferings() async {
    await waitForInitialization();
    try {
      final offerings = await Purchases.getOfferings();
      debugPrint(
          'RevenueCatService: Retrieved ${offerings.all.length} offerings');
      return offerings;
    } catch (e) {
      debugPrint('RevenueCatService: Failed to get offerings - $e');
      rethrow;
    }
  }

  /// Get the current/default offering
  Future<Offering?> getCurrentOffering() async {
    final offerings = await getOfferings();
    return offerings.current;
  }

  /// Get available packages from the current offering
  Future<List<Package>> getAvailablePackages() async {
    final offering = await getCurrentOffering();
    return offering?.availablePackages ?? [];
  }

  /// Purchase a package
  Future<RevenueCatPurchaseResult> purchasePackage(Package package) async {
    await waitForInitialization();
    try {
      debugPrint(
          'RevenueCatService: Purchasing package: ${package.identifier}');
      // ignore: deprecated_member_use
      final result = await Purchases.purchasePackage(package);
      debugPrint('RevenueCatService: Purchase successful');
      debugPrint('RevenueCatService: Purchase result - Active entitlements: ${result.customerInfo.entitlements.active.keys.toList()}');
      debugPrint('RevenueCatService: Purchase result - All entitlements: ${result.customerInfo.entitlements.all.keys.toList()}');

      // Check if the expected entitlement is active
      final hasVoyZaPro = result.customerInfo.entitlements.active.containsKey(RevenueCatConfig.entitlementVoyZaPro);
      debugPrint('RevenueCatService: Has voyza_pro entitlement: $hasVoyZaPro');

      // purchasePackage returns PurchaseResult which contains customerInfo
      return RevenueCatPurchaseResult.success(result.customerInfo);
    } on PlatformException catch (e) {
      final errorCode = PurchasesErrorHelper.getErrorCode(e);
      if (errorCode == PurchasesErrorCode.purchaseCancelledError) {
        debugPrint('RevenueCatService: Purchase cancelled by user');
        return RevenueCatPurchaseResult.cancelled();
      }
      debugPrint('RevenueCatService: Purchase error - $errorCode');
      return RevenueCatPurchaseResult.error(_getErrorMessage(errorCode));
    } catch (e) {
      debugPrint('RevenueCatService: Purchase failed - $e');
      return RevenueCatPurchaseResult.error(
          'An unexpected error occurred. Please try again.');
    }
  }

  /// Purchase a product by ID (monthly or yearly)
  Future<RevenueCatPurchaseResult> purchaseProduct(String productId) async {
    try {
      final packages = await getAvailablePackages();
      final package = packages.firstWhere(
        (p) => p.storeProduct.identifier == productId,
        orElse: () => throw Exception('Product not found: $productId'),
      );
      return purchasePackage(package);
    } catch (e) {
      debugPrint('RevenueCatService: Purchase product failed - $e');
      return RevenueCatPurchaseResult.error(
          'Product not available. Please try again later.');
    }
  }

  /// Purchase the monthly subscription
  Future<RevenueCatPurchaseResult> purchaseMonthly() async {
    try {
      final packages = await getAvailablePackages();
      final monthlyPackage = packages.firstWhere(
        (p) => p.packageType == PackageType.monthly,
        orElse: () => throw Exception('Monthly package not found'),
      );
      return purchasePackage(monthlyPackage);
    } catch (e) {
      return RevenueCatPurchaseResult.error(
          'Monthly subscription not available.');
    }
  }

  /// Purchase the yearly subscription
  Future<RevenueCatPurchaseResult> purchaseYearly() async {
    try {
      final packages = await getAvailablePackages();
      final yearlyPackage = packages.firstWhere(
        (p) => p.packageType == PackageType.annual,
        orElse: () => throw Exception('Yearly package not found'),
      );
      return purchasePackage(yearlyPackage);
    } catch (e) {
      return RevenueCatPurchaseResult.error(
          'Yearly subscription not available.');
    }
  }

  /// Restore purchases
  Future<RevenueCatPurchaseResult> restorePurchases() async {
    await waitForInitialization();
    try {
      debugPrint('RevenueCatService: Restoring purchases');
      final customerInfo = await Purchases.restorePurchases();
      debugPrint('RevenueCatService: Restore successful');

      // Check if any subscriptions were restored
      if (customerInfo.entitlements.active.isNotEmpty) {
        return RevenueCatPurchaseResult.success(customerInfo);
      } else {
        return RevenueCatPurchaseResult.error(
            'No active subscriptions found to restore.');
      }
    } catch (e) {
      debugPrint('RevenueCatService: Restore failed - $e');
      return RevenueCatPurchaseResult.error(
          'Failed to restore purchases. Please try again.');
    }
  }

  /// Get subscription management URL
  Future<String?> getManagementUrl() async {
    try {
      final customerInfo = await getCustomerInfo();
      return customerInfo.managementURL;
    } catch (e) {
      debugPrint('RevenueCatService: Failed to get management URL - $e');
      return null;
    }
  }

  /// Check if user is anonymous
  Future<bool> isAnonymous() async {
    await waitForInitialization();
    return await Purchases.isAnonymous;
  }

  /// Get the app user ID
  Future<String> getAppUserId() async {
    await waitForInitialization();
    return await Purchases.appUserID;
  }

  /// Set user attributes for analytics
  Future<void> setUserAttributes({
    String? email,
    String? displayName,
    String? phoneNumber,
  }) async {
    await waitForInitialization();
    try {
      if (email != null) {
        await Purchases.setEmail(email);
      }
      if (displayName != null) {
        await Purchases.setDisplayName(displayName);
      }
      if (phoneNumber != null) {
        await Purchases.setPhoneNumber(phoneNumber);
      }
      debugPrint('RevenueCatService: User attributes set');
    } catch (e) {
      debugPrint('RevenueCatService: Failed to set user attributes - $e');
    }
  }

  /// Sync purchases (useful for debugging)
  Future<void> syncPurchases() async {
    await waitForInitialization();
    try {
      await Purchases.syncPurchases();
      debugPrint('RevenueCatService: Purchases synced');
    } catch (e) {
      debugPrint('RevenueCatService: Failed to sync purchases - $e');
    }
  }

  /// Get current active product identifier (monthly or yearly)
  Future<String?> getCurrentProductId() async {
    try {
      final customerInfo = await getCustomerInfo();
      final proEntitlement = customerInfo.entitlements.active[RevenueCatConfig.entitlementVoyZaPro];
      return proEntitlement?.productIdentifier;
    } catch (e) {
      debugPrint('RevenueCatService: Failed to get current product ID - $e');
      return null;
    }
  }

  /// Check if user is on monthly plan
  Future<bool> isMonthlyPlan() async {
    final productId = await getCurrentProductId();
    return productId?.contains('monthly') ?? false;
  }

  /// Check if user is on yearly plan
  Future<bool> isYearlyPlan() async {
    final productId = await getCurrentProductId();
    return productId?.contains('yearly') ?? false;
  }

  /// Change subscription plan
  /// This allows users to switch between monthly and yearly subscriptions
  Future<RevenueCatPurchaseResult> changePlan(Package newPackage) async {
    await waitForInitialization();
    try {
      debugPrint('RevenueCatService: Changing plan to: ${newPackage.identifier}');

      // Get current subscription info
      final customerInfo = await getCustomerInfo();
      final proEntitlement = customerInfo.entitlements.active[RevenueCatConfig.entitlementVoyZaPro];

      if (proEntitlement == null) {
        return RevenueCatPurchaseResult.error('No active subscription to change.');
      }

      // Purchase the new package (RevenueCat/App Store/Play Store handles the upgrade/downgrade)
      final result = await purchasePackage(newPackage);

      if (result.success) {
        debugPrint('RevenueCatService: Plan change successful');
      }

      return result;
    } catch (e) {
      debugPrint('RevenueCatService: Plan change failed - $e');
      return RevenueCatPurchaseResult.error('Failed to change plan. Please try again.');
    }
  }

  /// Get human-readable error message
  String _getErrorMessage(PurchasesErrorCode errorCode) {
    switch (errorCode) {
      case PurchasesErrorCode.purchaseCancelledError:
        return 'Purchase was cancelled.';
      case PurchasesErrorCode.storeProblemError:
        return 'There was a problem with the app store. Please try again.';
      case PurchasesErrorCode.purchaseNotAllowedError:
        return 'Purchases are not allowed on this device.';
      case PurchasesErrorCode.purchaseInvalidError:
        return 'The purchase was invalid. Please try again.';
      case PurchasesErrorCode.productNotAvailableForPurchaseError:
        return 'This product is not available for purchase.';
      case PurchasesErrorCode.productAlreadyPurchasedError:
        return 'You have already purchased this product.';
      case PurchasesErrorCode.networkError:
        return 'Network error. Please check your connection.';
      case PurchasesErrorCode.receiptAlreadyInUseError:
        return 'This receipt is already in use by another account.';
      case PurchasesErrorCode.invalidReceiptError:
        return 'Invalid receipt. Please try again.';
      case PurchasesErrorCode.missingReceiptFileError:
        return 'Receipt file is missing. Please try again.';
      case PurchasesErrorCode.insufficientPermissionsError:
        return 'Insufficient permissions to make a purchase.';
      case PurchasesErrorCode.paymentPendingError:
        return 'Your payment is pending. Please wait.';
      default:
        return 'An error occurred. Please try again.';
    }
  }

  /// Dispose resources
  void dispose() {
    _customerInfoController.close();
  }
}
