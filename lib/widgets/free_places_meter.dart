import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/location_provider.dart';
import '../providers/subscription_provider.dart';
import '../services/subscription_limit_service.dart';

/// Segmented "N of 5 free places used" goal-gradient meter. Pure UI —
/// used inside the first-trip celebration and the map-screen progress chip.
class FreePlacesMeter extends StatelessWidget {
  final int used;

  const FreePlacesMeter({super.key, required this.used});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const total = SubscriptionLimitService.freePlaceAllowance;
    return Column(
      children: [
        Row(
          children: List.generate(total, (i) {
            final filled = i < used;
            return Expanded(
              child: Container(
                height: 8,
                margin: EdgeInsets.only(right: i == total - 1 ? 0 : 6),
                decoration: BoxDecoration(
                  color: filled
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 8),
        Text(
          '$used of $total free places used',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Compact, always-visible free-places progress pill for the map screen
/// (sits under the search bar). Free users only — hidden for Pro. Watches
/// the live location stream so it updates the moment a place lands.
///
/// Counts OWN places only (same rule as the paywall gate): collaborators'
/// shared-trip rows must not appear to eat the allowance.
class FreePlacesProgressChip extends ConsumerWidget {
  const FreePlacesProgressChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(isProProvider)) return const SizedBox.shrink();

    final all = ref.watch(savedLocationsProvider).asData?.value;
    if (all == null) return const SizedBox.shrink(); // stream not ready yet

    final userId = ref.watch(currentUserIdProvider);
    final used = (userId == null
            ? all.length
            : all.where((l) => l.userId == userId).length)
        .clamp(0, SubscriptionLimitService.freePlaceAllowance);
    const total = SubscriptionLimitService.freePlaceAllowance;

    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.2),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...List.generate(total, (i) {
            final filled = i < used;
            return Container(
              width: 16,
              height: 6,
              margin: EdgeInsets.only(right: i == total - 1 ? 8 : 4),
              decoration: BoxDecoration(
                color: filled
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
          Text(
            '$used of $total free places',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
