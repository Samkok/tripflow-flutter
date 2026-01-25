# RevenueCat Integration Examples

This document shows real-world examples of how the RevenueCat integration is used throughout the VoyZa app.

## Overview

The integration is now fully connected to your app:

1. ✅ **Settings Screen** - Shows subscription status and management
2. ✅ **Auth Service** - Links RevenueCat user with Supabase user
3. ✅ **Main Initialization** - RevenueCat initializes with app
4. ✅ **Pro Feature Gates** - Ready to use throughout the app

## User Flow

### 1. User Signs Up or Logs In

**What happens:**
```
User signs up/in → Supabase auth → RevenueCat user linked
```

**Code (auth_service.dart):**
```dart
if (response.user != null) {
  // Link RevenueCat user identity with Supabase user
  await RevenueCatService().login(response.user!.id);

  // Set user attributes for analytics
  await RevenueCatService().setUserAttributes(
    email: response.user!.email,
  );
}
```

**Benefits:**
- Purchases are tied to the user's account
- User keeps their Pro subscription across devices
- RevenueCat analytics track user behavior

### 2. User Opens Settings

**What happens:**
```
Settings Screen → Shows Pro banner (if not Pro) → Shows subscription tile
```

**UI Elements:**
- **Pro Upgrade Banner** - Shows at top for non-Pro users
- **Subscription Tile** - Shows current status and link to management

**Code (settings_screen.dart):**
```dart
// Pro upgrade banner for non-Pro users
const ProUpgradeBanner(),

// Subscription tile
_buildSubscriptionTile(context, ref),
```

**User sees:**
- If **not Pro**: "Upgrade to Pro - Unlock all premium features"
- If **Pro**: "VoyZa Pro - Manage your subscription"

### 3. User Taps Subscription Tile

**Navigation:**
```
Settings → Subscription Tile → SubscriptionManagementScreen
```

**Screen shows:**
- Current subscription status (Free Plan / VoyZa Pro)
- Expiration date and renewal status (if Pro)
- Upgrade button (if not Pro)
- Manage subscription button (if Pro)
- Customer Center button
- FAQ section

### 4. User Upgrades to Pro

**Flow:**
```
Tap "Upgrade to Pro" → PaywallScreen → Select plan → Purchase → Success
```

**Code example:**
```dart
// User taps upgrade button
ElevatedButton(
  onPressed: () async {
    final result = await showPaywall(context);
    if (result) {
      // User is now Pro!
      showSuccessMessage();
    }
  },
  child: Text('Upgrade to Pro'),
)
```

**What happens:**
1. Paywall shows monthly and yearly options
2. User selects a plan
3. Platform payment sheet appears (Apple/Google)
4. Purchase processes through RevenueCat
5. Entitlement granted immediately
6. UI updates automatically via providers

### 5. Using Pro Features in Your App

## Example 1: Gate an Entire Feature

**Scenario:** Limit trip count for free users

```dart
class CreateTripButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userTrips = ref.watch(userTripsProvider);

    return ElevatedButton(
      onPressed: () async {
        final isPro = ref.read(isProProvider);

        // Free users limited to 3 trips
        if (!isPro && userTrips.length >= 3) {
          final upgraded = await showPaywall(context);
          if (!upgraded) return; // User didn't upgrade
        }

        // Create trip
        createNewTrip();
      },
      child: Text('Create Trip'),
    );
  }
}
```

## Example 2: Using ProFeatureGate Widget

**Scenario:** Show "Offline Maps" feature only to Pro users

```dart
ProFeatureGate(
  featureName: 'Offline Maps',
  description: 'Download maps for offline use',
  child: OfflineMapsWidget(),
)
```

**Result:**
- **Pro users**: See the full OfflineMapsWidget
- **Free users**: See lock icon with upgrade prompt

## Example 3: Conditional UI Elements

**Scenario:** Show export button only for Pro users

```dart
class TripDetailsScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Trip Details'),
        actions: [
          // Export button only for Pro
          ProVisibility(
            child: IconButton(
              icon: Icon(Icons.download),
              onPressed: exportToPDF,
            ),
            replacement: ProLockButton(
              onUnlocked: exportToPDF,
              tooltip: 'Export to PDF',
            ),
          ),
        ],
      ),
      body: TripContent(),
    );
  }
}
```

**Result:**
- **Pro users**: See export button, can tap to export
- **Free users**: See lock icon, tapping shows paywall

## Example 4: Check Before Action

**Scenario:** Require Pro for advanced route optimization

```dart
class OptimizeRouteButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ElevatedButton(
      onPressed: () async {
        // Check if user has Pro
        final canProceed = await ref.requirePro(context);
        if (!canProceed) return;

        // User is Pro, proceed with optimization
        optimizeRoute();
      },
      child: Text('Optimize Route'),
    );
  }
}
```

## Example 5: Different Limits

**Scenario:** Free users get 10 locations per trip, Pro users unlimited

```dart
class AddLocationButton extends ConsumerWidget {
  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(isProProvider);
    final locationCount = trip.locations.length;

    return ElevatedButton(
      onPressed: () async {
        // Check limits
        if (!isPro && locationCount >= 10) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('Limit Reached'),
              content: Text(
                'Free users can add up to 10 locations per trip.\n\n'
                'Upgrade to VoyZa Pro for unlimited locations!',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    showPaywall(context);
                  },
                  child: Text('Upgrade'),
                ),
              ],
            ),
          );
          return;
        }

        // Add location
        addLocation();
      },
      child: Text('Add Location'),
    );
  }
}
```

## Example 6: Feature Banner

**Scenario:** Show upgrade banner on trip screen

```dart
class TripScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Column(
        children: [
          // Show banner only for non-Pro users
          ProUpgradeBanner(
            message: 'Get unlimited trips and offline maps with Pro!',
          ),

          // Rest of trip UI
          Expanded(
            child: TripContent(),
          ),
        ],
      ),
    );
  }
}
```

## Example 7: Ad-Free Experience

**Scenario:** Show ads to free users, hide for Pro users

```dart
class MapScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(isProProvider);

    return Scaffold(
      body: Column(
        children: [
          Expanded(child: GoogleMap(...)),

          // Show ads only for free users
          if (!isPro)
            BannerAdWidget(),
        ],
      ),
    );
  }
}
```

## Subscription State Management

### Listen to Subscription Changes

```dart
class MyWidget extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subscriptionState = ref.watch(subscriptionProvider);

    if (subscriptionState.isLoading) {
      return CircularProgressIndicator();
    }

    if (subscriptionState.errorMessage != null) {
      return ErrorWidget(subscriptionState.errorMessage!);
    }

    return subscriptionState.isPro
        ? ProContent()
        : FreeContent();
  }
}
```

### Manual Refresh

```dart
// Refresh subscription status
await ref.read(subscriptionProvider.notifier).refresh();
```

### Get Subscription Details

```dart
// Check expiration
final expirationAsync = ref.watch(subscriptionExpirationProvider);
expirationAsync.whenData((expiration) {
  if (expiration != null) {
    print('Expires: $expiration');
  }
});

// Check if will renew
final willRenew = ref.watch(willRenewProvider);

// Get management URL
final urlAsync = ref.watch(managementUrlProvider);
```

## Testing Checklist

### Test User Flows

- [ ] Sign up → Check RevenueCat user created
- [ ] Sign in → Check RevenueCat user linked
- [ ] Sign out → Check RevenueCat user logged out
- [ ] Open Settings → See subscription tile
- [ ] Tap subscription tile → See management screen
- [ ] Tap upgrade → See paywall
- [ ] Purchase subscription → See Pro status
- [ ] Access Pro feature → Works without paywall
- [ ] Restore purchases → Subscription restored

### Test Pro Features

- [ ] ProFeatureGate shows content for Pro users
- [ ] ProFeatureGate shows lock for free users
- [ ] ProVisibility works correctly
- [ ] ProLockButton shows/hides correctly
- [ ] ProUpgradeBanner hides for Pro users
- [ ] requirePro() extension works

### Test Edge Cases

- [ ] App works without internet (local Pro check)
- [ ] Subscription expires → UI updates
- [ ] Subscription renews → UI updates
- [ ] Multiple devices → Same Pro status
- [ ] Restore on new device → Works correctly

## Common Patterns

### Pattern 1: Feature Limit

```dart
final isPro = ref.watch(isProProvider);
final limit = isPro ? null : 10; // null = unlimited

if (limit != null && items.length >= limit) {
  await showPaywall(context);
  return;
}
```

### Pattern 2: Premium Quality

```dart
final isPro = ref.watch(isProProvider);
final quality = isPro ? 'high' : 'medium';

exportMap(quality: quality);
```

### Pattern 3: Graceful Degradation

```dart
final isPro = ref.watch(isProProvider);

if (isPro) {
  return AdvancedOptimization();
} else {
  return BasicOptimization();
}
```

### Pattern 4: Prompt with Context

```dart
if (!isPro) {
  final shouldUpgrade = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Premium Feature'),
      content: Text(
        'This feature requires VoyZa Pro.\n\n'
        'Benefits:\n'
        '• Unlimited trips\n'
        '• Offline maps\n'
        '• Priority support',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Not Now'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('Upgrade'),
        ),
      ],
    ),
  );

  if (shouldUpgrade == true) {
    await showPaywall(context);
  }
  return;
}
```

## Debugging

### Check Current Pro Status

```dart
// In any widget
final isPro = ref.read(isProProvider);
print('User is Pro: $isPro');

// Get full subscription state
final state = ref.read(subscriptionProvider);
print('Pro: ${state.isPro}');
print('Loading: ${state.isLoading}');
print('Error: ${state.errorMessage}');
```

### Check RevenueCat User

```dart
final service = RevenueCatService();
final userId = await service.getAppUserId();
final customerInfo = await service.getCustomerInfo();
print('RevenueCat User: $userId');
print('Active Entitlements: ${customerInfo.entitlements.active}');
```

### Test Purchases

Use sandbox accounts:
- **iOS**: Settings → App Store → Sandbox Account
- **Android**: Use license test account in Play Console

## Summary

The RevenueCat integration is now fully operational:

1. ✅ Users are automatically linked on signup/login
2. ✅ Settings screen shows subscription management
3. ✅ Paywall is accessible from settings
4. ✅ Pro feature gates are ready to use
5. ✅ Customer Center available for support
6. ✅ User identity preserved across sessions

You can now start gating features throughout your app using the provided widgets and patterns!
