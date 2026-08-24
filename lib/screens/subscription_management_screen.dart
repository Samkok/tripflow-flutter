import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/subscription_provider.dart';
import '../widgets/app_toast.dart';
import 'paywall_screen.dart';
import 'package:voyza/widgets/rotating_globe_background.dart';

/// Screen for managing subscription and accessing customer center
class SubscriptionManagementScreen extends ConsumerStatefulWidget {
  const SubscriptionManagementScreen({super.key});

  @override
  ConsumerState<SubscriptionManagementScreen> createState() =>
      _SubscriptionManagementScreenState();
}

class _SubscriptionManagementScreenState
    extends ConsumerState<SubscriptionManagementScreen> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    final subscriptionState = ref.watch(subscriptionProvider);

    return Stack(
      children: [
        // Ambient rotating globe behind the page (app-wide treatment).
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const RotatingGlobeBackground(),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('Subscription'),
          ),
          body: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: () async {
                    await ref.read(subscriptionProvider.notifier).refresh();
                  },
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Current subscription status card
                        _buildStatusCard(context, subscriptionState),
                        const SizedBox(height: 24),

                        // Action buttons
                        if (subscriptionState.isPro) ...[
                          _buildManageSubscriptionSection(context),
                        ] else ...[
                          _buildUpgradeSection(context),
                        ],

                        const SizedBox(height: 24),

                        // Customer Center button
                        // _buildCustomerCenterButton(context),

                        // const SizedBox(height: 24),

                        // Help section
                        _buildHelpSection(context),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildStatusCard(BuildContext context, SubscriptionState state) {
    final theme = Theme.of(context);
    final expirationAsync = ref.watch(subscriptionExpirationProvider);
    final willRenewAsync = ref.watch(willRenewProvider);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: state.isPro
            ? LinearGradient(
                colors: [
                  theme.colorScheme.primary,
                  theme.colorScheme.secondary,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: state.isPro ? null : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(
            state.isPro ? Icons.star_rounded : Icons.star_outline_rounded,
            size: 56,
            color: state.isPro ? Colors.white : theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            state.isPro ? 'VoyZa Pro' : 'Free Plan',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: state.isPro ? Colors.white : null,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            state.isPro
                ? 'You have access to all premium features'
                : 'Upgrade to unlock all features',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: state.isPro
                  ? Colors.white.withValues(alpha: 0.9)
                  : theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          if (state.isPro) ...[
            const SizedBox(height: 16),
            expirationAsync.when(
              data: (expiration) {
                if (expiration == null) {
                  // Only a lifetime unlock has an active entitlement with no
                  // expiration (trials, promos and subscriptions all carry
                  // one) — say so instead of showing nothing.
                  final ent =
                      ref.watch(voyZaProEntitlementProvider).asData?.value;
                  if (ent != null && ent.expirationDate == null) {
                    return Text(
                      'Lifetime access — pay once, yours forever',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.8),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                }
                final formattedDate =
                    '${expiration.day}/${expiration.month}/${expiration.year}';
                return willRenewAsync.when(
                  data: (willRenew) => Text(
                    willRenew
                        ? 'Renews on $formattedDate'
                        : 'Expires on $formattedDate',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUpgradeSection(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Upgrade Your Plan',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: () => _showPaywall(),
          icon: const Icon(Icons.star_rounded),
          label: const Text('Upgrade to VoyZa Pro'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _restorePurchases,
          child: const Text('Restore Purchases'),
        ),
      ],
    );
  }

  Widget _buildManageSubscriptionSection(BuildContext context) {
    final theme = Theme.of(context);
    final managementUrlAsync = ref.watch(managementUrlProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Manage Subscription',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),

        // Plan change buttons
        // isMonthlyAsync.when(
        //   data: (isMonthly) {
        //     return isYearlyAsync.when(
        //       data: (isYearly) {
        //         if (isMonthly) {
        //           // User is on monthly, offer yearly upgrade
        //           return _buildChangePlanButton(
        //             context,
        //             'Upgrade to Yearly Plan',
        //             'Save money with annual billing',
        //             Icons.trending_up,
        //             () => _changePlanToYearly(),
        //           );
        //         } else if (isYearly) {
        //           // User is on yearly, offer monthly option
        //           return _buildChangePlanButton(
        //             context,
        //             'Switch to Monthly Plan',
        //             'More flexibility with monthly billing',
        //             Icons.swap_horiz,
        //             () => _changePlanToMonthly(),
        //           );
        //         }
        //         return const SizedBox.shrink();
        //       },
        //       loading: () => const SizedBox.shrink(),
        //       error: (_, __) => const SizedBox.shrink(),
        //     );
        //   },
        //   loading: () => const SizedBox.shrink(),
        //   error: (_, __) => const SizedBox.shrink(),
        // ),
        const SizedBox(height: 12),

        // App Store management button
        managementUrlAsync.when(
          data: (url) => url != null
              ? OutlinedButton.icon(
                  onPressed: () => _openManagementUrl(url),
                  icon: const Icon(Icons.settings),
                  label: Text(Platform.isIOS
                      ? 'Manage in App Store'
                      : 'Manage in Play Store'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                )
              : const SizedBox.shrink(),
          loading: () => const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          error: (_, __) => const SizedBox.shrink(),
        ),
      ],
    );
  }

  // Widget _buildCustomerCenterButton(BuildContext context) {
  //   final theme = Theme.of(context);

  //   return Column(
  //     crossAxisAlignment: CrossAxisAlignment.stretch,
  //     children: [
  //       Text(
  //         'Need Help?',
  //         style: theme.textTheme.titleMedium?.copyWith(
  //           fontWeight: FontWeight.bold,
  //         ),
  //       ),
  //       const SizedBox(height: 12),
  //       OutlinedButton.icon(
  //         onPressed: _showCustomerCenter,
  //         icon: const Icon(Icons.help_outline),
  //         label: const Text('Open Customer Center'),
  //         style: OutlinedButton.styleFrom(
  //           padding: const EdgeInsets.symmetric(vertical: 16),
  //         ),
  //       ),
  //     ],
  //   );
  // }

  Widget _buildHelpSection(BuildContext context) {
    final theme = Theme.of(context);

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
            'Frequently Asked Questions',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          _buildFaqItem(
            context,
            'How do I cancel my subscription?',
            // Platform-aware store naming: App Review rejected the binary
            // for mentioning Google Play on iOS (Guideline 2.3.10) — each
            // platform's users see only their own store. Also fixed the
            // stale reference to a "Customer Center" button that no longer
            // exists on this screen.
            'Tap "Manage in ${Platform.isIOS ? 'App Store' : 'Play Store'}" '
                'above to manage your subscription, including cancellation. '
                'You can also manage it in your '
                '${Platform.isIOS ? 'App Store' : 'Play Store'} settings. '
                'Your subscription will remain active until the end of the '
                'billing period.',
          ),
          const Divider(height: 24),
          _buildFaqItem(
            context,
            'Will I lose my data if I cancel?',
            'No, your trips and data are saved to your account. '
                'You\'ll only lose access to Pro features.',
          ),
          const Divider(height: 24),
          _buildFaqItem(
            context,
            'How do I restore my purchase?',
            'Tap "Restore Purchases" above if you\'ve previously subscribed. '
                'Make sure you\'re using the same '
                '${Platform.isIOS ? 'App Store' : 'Play Store'} account.',
          ),
        ],
      ),
    );
  }

  Widget _buildFaqItem(BuildContext context, String question, String answer) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          question,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          answer,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _showPaywall() async {
    final result = await showPaywall(context);
    if (result && mounted) {
      // Refresh subscription state after purchase
      ref.read(subscriptionProvider.notifier).refresh();
    }
  }

  Future<void> _restorePurchases() async {
    setState(() => _isLoading = true);

    final success =
        await ref.read(subscriptionProvider.notifier).restorePurchases();

    setState(() => _isLoading = false);

    if (mounted) {
      if (success) {
        AppToast.success(context, 'Purchases restored successfully!');
      } else {
        AppToast.warning(context, 'No purchases found to restore.');
      }
    }
  }

  // Future<void> _showCustomerCenter() async {
  //   try {
  //     await RevenueCatUI.presentCustomerCenter();

  //     // Refresh subscription state in case user made changes
  //     if (mounted) {
  //       ref.read(subscriptionProvider.notifier).refresh();
  //     }
  //   } catch (e) {
  //     debugPrint('Error showing customer center: $e');
  //     if (mounted) {
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         const SnackBar(
  //           content: Text('Unable to open Customer Center. Please try again.'),
  //           backgroundColor: Colors.red,
  //         ),
  //       );
  //     }
  //   }
  // }

  Future<void> _openManagementUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

/// Helper function to navigate to subscription management
/// Returns a Future that completes when user returns from the screen
Future<void> navigateToSubscriptionManagement(BuildContext context) async {
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (context) => const SubscriptionManagementScreen(),
    ),
  );
}
