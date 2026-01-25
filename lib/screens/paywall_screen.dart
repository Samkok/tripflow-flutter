import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/subscription_provider.dart';
import '../services/revenuecat_service.dart';
import '../services/supabase_service.dart';

/// Paywall screen that displays subscription options using RevenueCat Paywall UI
class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  bool _isLoading = false;
  Package? _selectedPackage;

  @override
  Widget build(BuildContext context) {
    final subscriptionState = ref.watch(subscriptionProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('VoyZa Pro'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading || subscriptionState.isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Hero section
                    _buildHeroSection(context),
                    const SizedBox(height: 32),

                    // Features list
                    _buildFeaturesList(context),
                    const SizedBox(height: 32),

                    // Subscription options
                    _buildSubscriptionOptions(context),
                    const SizedBox(height: 24),

                    // Subscribe button
                    _buildSubscribeButton(context),
                    const SizedBox(height: 16),

                    // Restore purchases button
                    _buildRestoreButton(context),
                    const SizedBox(height: 16),

                    // Terms and privacy
                    _buildLegalLinks(context),

                    // Error message if any
                    if (subscriptionState.errorMessage != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          subscriptionState.errorMessage!,
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildHeroSection(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primary,
                theme.colorScheme.secondary,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Icon(
            Icons.star_rounded,
            size: 56,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Upgrade to VoyZa Pro',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Unlock all premium features and take your trip planning to the next level',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildFeaturesList(BuildContext context) {
    final theme = Theme.of(context);

    final features = [
      ('Unlimited trips', Icons.all_inclusive),
      ('Offline maps access', Icons.download_for_offline),
      ('Priority support', Icons.support_agent),
      ('Trip collaboration', Icons.group),
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pro Features',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          ...features.map((feature) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        feature.$2,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        feature.$1,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    Icon(
                      Icons.check_circle,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildSubscriptionOptions(BuildContext context) {
    final monthlyPackageAsync = ref.watch(monthlyPackageProvider);
    final yearlyPackageAsync = ref.watch(yearlyPackageProvider);

    // Auto-select yearly package if nothing is selected
    yearlyPackageAsync.whenData((package) {
      if (package != null && _selectedPackage == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedPackage == null) {
            setState(() {
              _selectedPackage = package;
            });
          }
        });
      }
    });

    return Column(
      children: [
        // Yearly option (recommended)
        yearlyPackageAsync.when(
          data: (package) => package != null
              ? _buildPackageCard(
                  context,
                  package: package,
                  isRecommended: true,
                  title: 'Yearly',
                  subtitle: 'Best value - Save 40%',
                )
              : const SizedBox.shrink(),
          loading: () => _buildLoadingCard(),
          error: (_, __) => const SizedBox.shrink(),
        ),
        const SizedBox(height: 12),

        // Monthly option
        monthlyPackageAsync.when(
          data: (package) => package != null
              ? _buildPackageCard(
                  context,
                  package: package,
                  isRecommended: false,
                  title: 'Monthly',
                  subtitle: 'Flexible billing',
                )
              : const SizedBox.shrink(),
          loading: () => _buildLoadingCard(),
          error: (_, __) => const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildPackageCard(
    BuildContext context, {
    required Package package,
    required bool isRecommended,
    required String title,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    final priceString = package.storeProduct.priceString;
    final period = package.packageType == PackageType.annual ? '/year' : '/month';
    final isSelected = _selectedPackage?.identifier == package.identifier;

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedPackage = package;
        });
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer
              : (isRecommended
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                  : theme.colorScheme.surfaceContainerHighest),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : (isRecommended
                    ? theme.colorScheme.primary.withValues(alpha: 0.5)
                    : theme.colorScheme.outline.withValues(alpha: 0.3)),
            width: isSelected ? 2 : (isRecommended ? 2 : 1),
          ),
        ),
        child: Row(
          children: [
            // Selection indicator
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                  width: 2,
                ),
                color: isSelected ? theme.colorScheme.primary : Colors.transparent,
              ),
              child: isSelected
                  ? Icon(
                      Icons.check,
                      size: 16,
                      color: theme.colorScheme.onPrimary,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (isRecommended) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'BEST VALUE',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onPrimary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  priceString,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  period,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingCard() {
    return Container(
      height: 80,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  Widget _buildSubscribeButton(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: _selectedPackage != null ? _purchaseSelectedPackage : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 2,
        ),
        child: Text(
          _selectedPackage != null
              ? 'Subscribe to ${_selectedPackage!.packageType == PackageType.annual ? 'Yearly' : 'Monthly'} Plan'
              : 'Select a Plan',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildRestoreButton(BuildContext context) {
    return TextButton(
      onPressed: _restorePurchases,
      child: const Text('Restore Purchases'),
    );
  }

  Widget _buildLegalLinks(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TextButton(
          onPressed: () => _openUrl('https://voyza.app/terms'),
          child: Text(
            'Terms of Service',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Text(
          ' | ',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        TextButton(
          onPressed: () => _openUrl('https://voyza.app/privacy'),
          child: Text(
            'Privacy Policy',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _purchaseSelectedPackage() async {
    if (_selectedPackage == null) return;

    setState(() => _isLoading = true);

    final success =
        await ref.read(subscriptionProvider.notifier).purchasePackage(_selectedPackage!);

    setState(() => _isLoading = false);

    if (success && mounted) {
      // Store email to RevenueCat for authenticated users
      final user = SupabaseService.instance.client.auth.currentUser;
      if (user?.email != null) {
        try {
          await RevenueCatService().setUserAttributes(email: user!.email);
          debugPrint('PaywallScreen: Stored email to RevenueCat after purchase');
        } catch (e) {
          debugPrint('PaywallScreen: Failed to store email to RevenueCat: $e');
        }
      }

      // Force a refresh to ensure all providers update
      debugPrint('PaywallScreen: Forcing subscription refresh after purchase');
      await ref.read(subscriptionProvider.notifier).refresh();

      // Invalidate customer info provider to force rebuild
      debugPrint('PaywallScreen: Invalidating customer info provider');
      ref.invalidate(customerInfoProvider);

      // Small delay to ensure state propagates
      await Future.delayed(const Duration(milliseconds: 300));

      debugPrint('PaywallScreen: Current isPro state: ${ref.read(isProProvider)}');

      Navigator.of(context).pop(true);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Welcome to VoyZa Pro!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  Future<void> _restorePurchases() async {
    setState(() => _isLoading = true);

    final success =
        await ref.read(subscriptionProvider.notifier).restorePurchases();

    setState(() => _isLoading = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Purchases restored successfully!'
                : 'No purchases found to restore.',
          ),
          backgroundColor: success ? Colors.green : Colors.orange,
        ),
      );

      if (success) {
        Navigator.of(context).pop(true);
      }
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

/// Shows the RevenueCat native paywall
/// This uses RevenueCat's built-in paywall UI that you can configure in the dashboard
Future<bool> showRevenueCatPaywall(BuildContext context) async {
  try {
    final paywallResult = await RevenueCatUI.presentPaywallIfNeeded(
      RevenueCatConfig.entitlementVoyZaPro,
    );

    debugPrint('Paywall result: $paywallResult');

    return paywallResult == PaywallResult.purchased ||
        paywallResult == PaywallResult.restored;
  } catch (e) {
    debugPrint('Error showing RevenueCat paywall: $e');
    return false;
  }
}

/// Shows the custom paywall screen
Future<bool?> showCustomPaywall(BuildContext context) async {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (context) => const PaywallScreen(),
    ),
  );
}

/// Helper function to show the appropriate paywall
/// Tries RevenueCat native paywall first, falls back to custom paywall
Future<bool> showPaywall(BuildContext context, {bool preferNative = true}) async {
  if (preferNative) {
    // Try RevenueCat native paywall first
    final result = await showRevenueCatPaywall(context);
    if (result) return true;

    // If native paywall couldn't be shown (no offering configured), show custom
    return await showCustomPaywall(context) ?? false;
  } else {
    return await showCustomPaywall(context) ?? false;
  }
}
