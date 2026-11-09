import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/main.dart' show navigatorKey;

import '../providers/subscription_provider.dart';
import '../screens/paywall_screen.dart' show paywallVisibleProvider;
import '../screens/subscription_management_screen.dart';
import '../utils/pro_status_copy.dart';

/// Session-scoped dismissal flag for the top-of-app countdown banner.
/// Resets on app launch — the always-visible source of truth lives on the
/// settings screen.
final trialBannerDismissedProvider = StateProvider<bool>((_) => false);

/// Thin top-of-app banner showing remaining trial time. Visible only while
/// the user is in the store-managed introductory free trial period
/// (RevenueCat reports `periodType == trial` for the active entitlement).
class TrialCountdownBanner extends ConsumerStatefulWidget {
  const TrialCountdownBanner({super.key});

  @override
  ConsumerState<TrialCountdownBanner> createState() =>
      _TrialCountdownBannerState();
}

class _TrialCountdownBannerState extends ConsumerState<TrialCountdownBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Re-render every minute so the "X hours left" copy stays accurate.
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Banner is mounted above the Navigator, so a pushed paywall route can't
    // visually cover it. Hide manually while the paywall is open so the user
    // can't tap upgrade to stack duplicate paywalls.
    if (ref.watch(paywallVisibleProvider)) return const SizedBox.shrink();
    if (ref.watch(trialBannerDismissedProvider)) return const SizedBox.shrink();

    final entitlement = ref.watch(activeTrialEntitlementProvider);
    if (entitlement == null) return const SizedBox.shrink();

    final expiresAt = DateTime.tryParse(entitlement.expirationDate ?? '');
    if (expiresAt == null) return const SizedBox.shrink();
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining <= Duration.zero) return const SizedBox.shrink();

    return _TrialBannerView(
      remaining: remaining,
      onDismiss: () =>
          ref.read(trialBannerDismissedProvider.notifier).state = true,
    );
  }
}

class _TrialBannerView extends StatelessWidget {
  final Duration remaining;
  final VoidCallback onDismiss;

  const _TrialBannerView({required this.remaining, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUrgent = remaining < const Duration(hours: 24);
    final accent =
        isUrgent ? theme.colorScheme.error : theme.colorScheme.primary;

    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: InkWell(
          // The subscription screen, not the paywall: this is a status
          // surface, and that screen holds the trial's facts and actions.
          onTap: () => navigatorKey.currentState?.push(MaterialPageRoute<void>(
            builder: (_) => const SubscriptionManagementScreen(),
          )),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.dividerColor.withValues(alpha: 0.5),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isUrgent ? Icons.access_time_filled : Icons.access_time,
                  size: 18,
                  color: accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'Free trial: ',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        TextSpan(
                          text: formatRemaining(remaining),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Manage',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Stop the InkWell tap from also opening the paywall.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onDismiss,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
