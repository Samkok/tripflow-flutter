# RevenueCat Integration Guide for VoyZa

This document describes the RevenueCat SDK integration for managing VoyZa Pro subscriptions.

## Overview

The integration includes:
- RevenueCat SDK initialization
- Subscription state management with Riverpod
- Custom paywall screen
- RevenueCat native paywall support
- Customer Center for subscription management
- Pro feature gating widgets

## File Structure

```
lib/
├── services/
│   └── revenuecat_service.dart      # Core RevenueCat service
├── providers/
│   └── subscription_provider.dart    # Riverpod subscription providers
├── screens/
│   ├── paywall_screen.dart          # Custom paywall UI
│   └── subscription_management_screen.dart  # Subscription settings
└── widgets/
    └── pro_feature_gate.dart         # Pro feature gating widgets
```

## Configuration

### 1. Environment Variables

The RevenueCat API keys are stored in `.env` (platform-specific):

```env
REVENUECAT_API_KEY_IOS=your_ios_api_key_here
REVENUECAT_API_KEY_ANDROID=your_android_api_key_here
```

The app automatically selects the correct key based on the platform at runtime.

### 2. RevenueCat Dashboard Configuration

1. **Create Products** in RevenueCat:
   - `monthly` - Monthly subscription
   - `yearly` - Yearly subscription

2. **Create Entitlement**:
   - Identifier: `voyza_pro`
   - Attach both products to this entitlement

3. **Create Offering**:
   - Identifier: `default`
   - Add monthly and yearly packages

4. **Configure Paywall** (optional):
   - Go to Paywalls in RevenueCat dashboard
   - Design your paywall using the visual editor
   - Attach it to the `default` offering

5. **Configure Customer Center** (optional):
   - Go to Customer Center in RevenueCat dashboard
   - Configure the appearance and options

### 3. Platform-Specific Setup

#### Android

1. Add your app to Google Play Console
2. Configure in-app products:
   - `monthly` subscription
   - `yearly` subscription
3. Link Google Play to RevenueCat dashboard
4. Add billing permission in `AndroidManifest.xml` (auto-added by Flutter plugin):
   ```xml
   <uses-permission android:name="com.android.vending.BILLING"/>
   ```

#### iOS

1. Add your app to App Store Connect
2. Configure in-app purchases:
   - `monthly` subscription
   - `yearly` subscription
3. Link App Store to RevenueCat dashboard
4. Enable In-App Purchase capability in Xcode
5. Add StoreKit configuration for testing

## Usage

### Check if User is Pro

```dart
// Using provider
final isPro = ref.watch(isProProvider);

// Using service directly
final isPro = await RevenueCatService().hasVoyZaProEntitlement();
```

### Show Paywall

```dart
// Show RevenueCat native paywall (preferred)
await showRevenueCatPaywall(context);

// Show custom paywall
await showCustomPaywall(context);

// Show best available paywall
final upgraded = await showPaywall(context);
if (upgraded) {
  // User subscribed!
}
```

### Gate Pro Features

```dart
// Using ProFeatureGate widget
ProFeatureGate(
  featureName: 'Unlimited Trips',
  description: 'Create as many trips as you want',
  child: YourProFeatureWidget(),
)

// Using ProVisibility
ProVisibility(
  child: ProOnlyButton(),
  replacement: LockedButton(),
)

// Using ProLockButton
ProLockButton(
  onUnlocked: () => doProAction(),
  tooltip: 'Export to PDF',
)

// Using ProUpgradeBanner
ProUpgradeBanner(
  message: 'Get unlimited trips with Pro!',
)
```

### Programmatic Pro Check

```dart
class MyWidget extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ElevatedButton(
      onPressed: () async {
        // Check and show paywall if needed
        final canProceed = await ref.requirePro(context);
        if (canProceed) {
          // User is Pro or just upgraded
          doProAction();
        }
      },
      child: Text('Pro Feature'),
    );
  }
}
```

### Subscription Management

```dart
// Navigate to subscription settings
navigateToSubscriptionManagement(context);

// Or use the screen directly
Navigator.push(context, MaterialPageRoute(
  builder: (context) => const SubscriptionManagementScreen(),
));
```

### Purchase Programmatically

```dart
final notifier = ref.read(subscriptionProvider.notifier);

// Purchase monthly
final success = await notifier.purchaseMonthly();

// Purchase yearly
final success = await notifier.purchaseYearly();

// Restore purchases
final success = await notifier.restorePurchases();
```

### Listen to Subscription Changes

```dart
// Watch subscription state
final state = ref.watch(subscriptionProvider);
print('Is Pro: ${state.isPro}');
print('Is Loading: ${state.isLoading}');
print('Error: ${state.errorMessage}');

// Watch specific properties
final isPro = ref.watch(isProProvider);
final isLoading = ref.watch(subscriptionLoadingProvider);
```

### Get Subscription Details

```dart
// Get expiration date
final expirationAsync = ref.watch(subscriptionExpirationProvider);
expirationAsync.when(
  data: (expiration) => print('Expires: $expiration'),
  loading: () => print('Loading...'),
  error: (e, _) => print('Error: $e'),
);

// Check if subscription will renew
final willRenewAsync = ref.watch(willRenewProvider);

// Get management URL
final urlAsync = ref.watch(managementUrlProvider);
```

### User Identity

```dart
final service = RevenueCatService();

// Login user (after authentication)
await service.login(userId);

// Logout (when user signs out)
await service.logout();

// Set user attributes
await service.setUserAttributes(
  email: 'user@example.com',
  displayName: 'John Doe',
);
```

## Testing

### Sandbox Testing

1. **Android**: Use a license testing account in Google Play Console
2. **iOS**: Use a sandbox test account in App Store Connect

### Testing Purchases

```dart
// In debug mode, RevenueCat logs are enabled
// Check logcat/console for purchase flow logs
```

### Testing Entitlements

You can grant entitlements manually in the RevenueCat dashboard for testing:
1. Go to Customers
2. Find your test user
3. Grant the `voyza_pro` entitlement

## Error Handling

The service handles common errors:

```dart
final result = await service.purchaseMonthly();

if (result.success) {
  // Purchase successful
} else if (result.userCancelled) {
  // User cancelled - don't show error
} else {
  // Show error message
  showSnackBar(result.errorMessage ?? 'Purchase failed');
}
```

## Best Practices

1. **Always check Pro status before showing Pro features**
   ```dart
   if (ref.read(isProProvider)) {
     showProFeature();
   } else {
     showPaywall(context);
   }
   ```

2. **Handle loading states**
   ```dart
   final state = ref.watch(subscriptionProvider);
   if (state.isLoading) {
     return CircularProgressIndicator();
   }
   ```

3. **Refresh after purchase/restore**
   ```dart
   await ref.read(subscriptionProvider.notifier).refresh();
   ```

4. **Link RevenueCat user to your auth user**
   ```dart
   // On login
   await RevenueCatService().login(supabaseUser.id);

   // On logout
   await RevenueCatService().logout();
   ```

## Debugging

Enable verbose logging:

```dart
// Already enabled in debug mode via revenuecat_service.dart
if (kDebugMode) {
  await Purchases.setLogLevel(LogLevel.debug);
}
```

Check logs for:
- `RevenueCatService:` prefix for service logs
- RevenueCat SDK logs for purchase flow

## Troubleshooting

### "Product not found"
- Ensure products are created in both app stores
- Products match identifiers in RevenueCat
- Wait for product approval (can take 24-48 hours)

### "Purchase not allowed"
- Check device has valid payment method
- Sandbox account properly configured
- App has billing permission

### Entitlement not updating
- Call `refresh()` after purchase
- Check RevenueCat dashboard for transaction
- Verify entitlement configuration

## Resources

- [RevenueCat Flutter SDK Docs](https://www.revenuecat.com/docs/getting-started/installation/flutter)
- [RevenueCat Paywalls](https://www.revenuecat.com/docs/tools/paywalls)
- [RevenueCat Customer Center](https://www.revenuecat.com/docs/tools/customer-center)
- [Testing Guide](https://www.revenuecat.com/docs/test-and-launch/sandbox)
