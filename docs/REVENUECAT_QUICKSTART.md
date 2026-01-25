# RevenueCat Integration - Quick Start Guide

## ✅ What's Already Done

Your VoyZa app now has a **complete RevenueCat integration**. Here's what's been implemented:

### 1. Core Services
- ✅ [RevenueCatService](../lib/services/revenuecat_service.dart) - Complete SDK wrapper
- ✅ [Subscription Providers](../lib/providers/subscription_provider.dart) - Reactive state management
- ✅ Background initialization in [main.dart](../lib/main.dart)

### 2. User Interface
- ✅ [Paywall Screen](../lib/screens/paywall_screen.dart) - Custom paywall with feature list
- ✅ [Subscription Management](../lib/screens/subscription_management_screen.dart) - Full management UI
- ✅ [Pro Feature Gates](../lib/widgets/pro_feature_gate.dart) - 4 reusable widgets for feature gating
- ✅ Settings integration in [settings_screen.dart](../lib/screens/settings_screen.dart)

### 3. Authentication Integration
- ✅ User identity linking in [auth_service.dart](../lib/services/auth_service.dart)
- ✅ Auto-login to RevenueCat on sign in/up
- ✅ Auto-logout on sign out
- ✅ User attributes (email, name) sent to RevenueCat

### 4. Configuration
- ✅ API key configured in `.env` file
- ✅ Products configured: `monthly` and `yearly`
- ✅ Entitlement configured: `voyza_pro`

## 🚀 What You Need to Do

### Step 1: RevenueCat Dashboard Setup (5 minutes)

1. **Go to RevenueCat Dashboard**: https://app.revenuecat.com
2. **Create Products**:
   - Product ID: `monthly` (e.g., $9.99/month)
   - Product ID: `yearly` (e.g., $79.99/year)
3. **Create Entitlement**:
   - Name: `VoyZa Pro`
   - Identifier: `voyza_pro`
   - Attach both products to this entitlement

### Step 2: Platform Setup

#### iOS (App Store Connect)
1. Create in-app purchases with IDs: `monthly` and `yearly`
2. Add to your app in App Store Connect
3. Configure pricing
4. Submit for review

#### Android (Google Play Console)
1. Create subscription products with IDs: `monthly` and `yearly`
2. Configure pricing
3. Activate subscriptions

See [REVENUECAT_SETUP.md](./REVENUECAT_SETUP.md) for detailed platform setup instructions.

### Step 3: Test the Integration (10 minutes)

1. **Run the app**:
   ```bash
   flutter run
   ```

2. **Sign in** to your account
   - RevenueCat will automatically create a user linked to your Supabase ID

3. **Open Settings** → **Tap "Upgrade to Pro"**
   - You should see the paywall screen

4. **Test a sandbox purchase**:
   - iOS: Use a sandbox tester account
   - Android: Use a test account from Play Console

### Step 4: Start Gating Features (Ongoing)

Now you can start adding Pro features throughout your app!

#### Quick Example: Limit Trips for Free Users

```dart
// In your create trip button
class CreateTripButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(isProProvider);
    final userTrips = ref.watch(userTripsProvider);

    return ElevatedButton(
      onPressed: () async {
        // Free users limited to 3 trips
        if (!isPro && userTrips.length >= 3) {
          final upgraded = await showPaywall(context);
          if (!upgraded) return;
        }

        // Create trip
        Navigator.push(context, CreateTripScreen());
      },
      child: Text('Create New Trip'),
    );
  }
}
```

See [REVENUECAT_INTEGRATION_EXAMPLES.md](./REVENUECAT_INTEGRATION_EXAMPLES.md) for 7+ complete examples.

## 📱 User Flow Overview

Here's how your users will experience subscriptions:

```
1. User signs up/in
   └─> RevenueCat user created automatically
   └─> User attributes (email, name) sent to RevenueCat

2. User opens Settings
   └─> Sees "Upgrade to Pro" banner (if not Pro)
   └─> Sees subscription tile

3. User taps "Upgrade to Pro"
   └─> Paywall screen appears
   └─> Selects Monthly or Yearly plan
   └─> Completes purchase
   └─> Instantly becomes Pro user

4. User access is checked throughout app
   └─> ProFeatureGate widgets show/hide features
   └─> isProProvider checks subscription status
   └─> UI updates automatically when status changes

5. User can manage subscription
   └─> Settings → Subscription tile
   └─> Subscription Management screen
   └─> Customer Center for self-service
```

## 🛠️ Available Widgets for Feature Gating

### 1. ProFeatureGate
Shows content for Pro users, lock screen for free users:

```dart
ProFeatureGate(
  featureName: 'Offline Maps',
  description: 'Download maps for offline use',
  child: OfflineMapsWidget(),
)
```

### 2. ProVisibility
Like Visibility widget but for Pro features:

```dart
ProVisibility(
  child: ExportButton(),
  replacement: ProLockButton(onUnlocked: exportToPDF),
)
```

### 3. ProLockButton
Lock icon that becomes functional when Pro:

```dart
ProLockButton(
  onUnlocked: () => exportToPDF(),
  tooltip: 'Export to PDF',
)
```

### 4. ProUpgradeBanner
Banner prompting upgrade:

```dart
ProUpgradeBanner(
  message: 'Get unlimited trips with Pro!',
)
```

### 5. Extension Methods
Quick Pro checks:

```dart
// Check if Pro
final isPro = ref.watch(isProProvider);

// Require Pro before action
final canProceed = await ref.requirePro(context);
if (!canProceed) return;
```

## 📊 Testing Checklist

Before going live, test these scenarios:

- [ ] Sign up → RevenueCat user created
- [ ] Sign in → RevenueCat user linked
- [ ] Sign out → RevenueCat user logged out
- [ ] Open Settings → See subscription tile
- [ ] Tap subscription tile → See management screen
- [ ] Tap upgrade → See paywall
- [ ] Purchase subscription (sandbox) → Become Pro
- [ ] Access Pro feature → Works without paywall
- [ ] Restore purchases → Subscription restored
- [ ] Test on second device → Same Pro status

## 🎯 Suggested Pro Features to Implement

Here are some features you might want to gate behind Pro:

1. **Trip Limits**
   - Free: 3 trips max
   - Pro: Unlimited trips

2. **Location Limits**
   - Free: 10 locations per trip
   - Pro: Unlimited locations

3. **Offline Maps**
   - Free: Not available
   - Pro: Download maps for offline use

4. **Export Features**
   - Free: Not available
   - Pro: Export trips to PDF, share itineraries

5. **Advanced Planning**
   - Free: Basic route planning
   - Pro: AI-powered route optimization

6. **Collaboration**
   - Free: Solo trips only
   - Pro: Invite friends to collaborate on trips

7. **Custom Branding**
   - Free: VoyZa branding on exports
   - Pro: Remove branding, custom logos

## 📖 Additional Resources

- [Complete Setup Guide](./REVENUECAT_SETUP.md) - Platform configuration details
- [Integration Examples](./REVENUECAT_INTEGRATION_EXAMPLES.md) - 7 real-world usage examples
- [RevenueCat Documentation](https://docs.revenuecat.com) - Official SDK docs
- [Flutter SDK Reference](https://pub.dev/packages/purchases_flutter) - Package documentation

## 🐛 Common Issues

### "No packages available"
**Solution**: Make sure you've created products in RevenueCat dashboard and App Store/Play Console.

### "Purchase failed"
**Solution**:
- Check that product IDs match exactly
- Verify sandbox account setup
- Check RevenueCat API key is correct

### "Not showing as Pro after purchase"
**Solution**:
- Check entitlement ID is exactly `voyza_pro`
- Verify product is attached to entitlement in RevenueCat
- Try refreshing: `ref.read(subscriptionProvider.notifier).refresh()`

### "User not linked after login"
**Solution**: Check auth_service.dart has RevenueCat login calls (already implemented).

## 💡 Next Steps

1. ✅ **You're ready to test!** Run the app and try the subscription flow
2. 📱 **Configure platforms** - Set up products in App Store Connect and Play Console
3. 🎨 **Start gating features** - Use the examples to add Pro features throughout your app
4. 🧪 **Test thoroughly** - Use the testing checklist above
5. 🚀 **Go live** - Submit to App Store and Play Store

---

**Questions?** Check the [Integration Examples](./REVENUECAT_INTEGRATION_EXAMPLES.md) or RevenueCat's documentation.

**Ready to add Pro features?** Start with the simple examples and gradually add more complex gating as needed.
