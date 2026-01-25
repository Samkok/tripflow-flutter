import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/subscription_provider.dart';
import 'paywall_screen.dart';

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

    return Scaffold(
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
                    _buildCustomerCenterButton(context),

                    const SizedBox(height: 24),

                    // Help section
                    _buildHelpSection(context),
                  ],
                ),
              ),
            ),
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
                if (expiration == null) return const SizedBox.shrink();
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
    final isMonthlyAsync = ref.watch(isMonthlyPlanProvider);
    final isYearlyAsync = ref.watch(isYearlyPlanProvider);

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
        isMonthlyAsync.when(
          data: (isMonthly) {
            return isYearlyAsync.when(
              data: (isYearly) {
                if (isMonthly) {
                  // User is on monthly, offer yearly upgrade
                  return _buildChangePlanButton(
                    context,
                    'Upgrade to Yearly Plan',
                    'Save money with annual billing',
                    Icons.trending_up,
                    () => _changePlanToYearly(),
                  );
                } else if (isYearly) {
                  // User is on yearly, offer monthly option
                  return _buildChangePlanButton(
                    context,
                    'Switch to Monthly Plan',
                    'More flexibility with monthly billing',
                    Icons.swap_horiz,
                    () => _changePlanToMonthly(),
                  );
                }
                return const SizedBox.shrink();
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        ),
        const SizedBox(height: 12),

        // App Store management button
        managementUrlAsync.when(
          data: (url) => url != null
              ? OutlinedButton.icon(
                  onPressed: () => _openManagementUrl(url),
                  icon: const Icon(Icons.settings),
                  label: const Text('Manage in App Store'),
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

  Widget _buildChangePlanButton(
    BuildContext context,
    String title,
    String subtitle,
    IconData icon,
    VoidCallback onPressed,
  ) {
    final theme = Theme.of(context);

    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.all(16),
        side: BorderSide(color: theme.colorScheme.primary),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: theme.colorScheme.primary),
        ],
      ),
    );
  }

  Widget _buildCustomerCenterButton(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Need Help?',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _showCustomerCenter,
          icon: const Icon(Icons.help_outline),
          label: const Text('Open Customer Center'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ],
    );
  }

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
            'Tap "Open Customer Center" above to manage your subscription, including cancellation. '
                'You can also manage through App Store/Google Play settings. Your subscription will remain active until the end of the billing period.',
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
                'Make sure you\'re using the same App Store/Google Play account.',
          ),
          const Divider(height: 24),
          _buildFaqItem(
            context,
            'Can I switch between monthly and yearly plans?',
            'Yes! You can change your plan anytime. Use the "Switch to Monthly Plan" or '
                '"Upgrade to Yearly Plan" button above. Your new billing cycle will start according to store policies.',
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
    }
  }

  Future<void> _changePlanToYearly() async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Upgrade to Yearly Plan'),
        content: const Text(
          'You will be charged for the yearly plan and your current monthly subscription will be adjusted accordingly.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Upgrade'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);

    try {
      // Get yearly package
      final yearlyPackageAsync = await ref.read(yearlyPackageProvider.future);

      if (yearlyPackageAsync == null) {
        throw Exception('Yearly package not available');
      }

      final success = await ref
          .read(subscriptionProvider.notifier)
          .changePlan(yearlyPackageAsync);

      setState(() => _isLoading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? 'Successfully upgraded to yearly plan!'
                  : 'Failed to change plan. Please try again.',
            ),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('An error occurred. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _changePlanToMonthly() async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Switch to Monthly Plan'),
        content: const Text(
          'You can switch to monthly billing. Your yearly subscription benefits will remain until the end of the current billing period.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);

    try {
      // Get monthly package
      final monthlyPackageAsync = await ref.read(monthlyPackageProvider.future);

      if (monthlyPackageAsync == null) {
        throw Exception('Monthly package not available');
      }

      final success = await ref
          .read(subscriptionProvider.notifier)
          .changePlan(monthlyPackageAsync);

      setState(() => _isLoading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? 'Successfully switched to monthly plan!'
                  : 'Failed to change plan. Please try again.',
            ),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('An error occurred. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showCustomerCenter() async {
    try {
      await RevenueCatUI.presentCustomerCenter();

      // Refresh subscription state in case user made changes
      if (mounted) {
        ref.read(subscriptionProvider.notifier).refresh();
      }
    } catch (e) {
      debugPrint('Error showing customer center: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to open Customer Center. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

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
