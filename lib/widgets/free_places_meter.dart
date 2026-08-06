import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/location_provider.dart';
import '../providers/subscription_provider.dart';
import '../providers/referral_provider.dart';
import '../services/subscription_limit_service.dart';

/// Colour of a FILLED allowance segment. The last two escalate — amber at the
/// second-to-last, red at the last — so running out is telegraphed a place in
/// advance instead of arriving as a surprise at the paywall.
///
/// Shared by both meters below so the two can't drift apart.
Color freePlaceSegmentColor(BuildContext context, int index,
    {int total = SubscriptionLimitService.freePlaceAllowance}) {
  if (index >= total - 1) return const Color(0xFFE5484D); // last → red
  if (index == total - 2) return const Color(0xFFF5A623); // second-last → amber
  return Theme.of(context).colorScheme.primary;
}

/// Session-scoped dismissal for the at-limit chip. The ✕ only appears once the
/// allowance is spent — before that the chip is live progress, not a nag, so
/// there's nothing to dismiss. Resets on relaunch by design: still being at
/// the limit is worth surfacing again next session.
final freePlacesChipDismissedProvider = StateProvider<bool>((_) => false);

/// Segmented "N of 5 free places used" goal-gradient meter. Pure UI —
/// used inside the first-trip celebration and the map-screen progress chip.
class FreePlacesMeter extends StatelessWidget {
  final int used;

  /// Effective allowance (base + referral bonus slots). Callers with a ref
  /// pass SubscriptionLimitService.effectiveAllowanceOf; the default keeps
  /// ref-less call sites compiling on the base allowance.
  final int total;

  const FreePlacesMeter({
    super.key,
    required this.used,
    this.total = SubscriptionLimitService.freePlaceAllowance,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = this.total;
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
                      ? freePlaceSegmentColor(context, i, total: total)
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
    // Base 5 + permanent referral bonus slots (loads async; base until then).
    final totalAllowance = SubscriptionLimitService.freePlaceAllowance +
        (ref.watch(referralBonusPlacesProvider).valueOrNull ?? 0);
    final used = (userId == null
            ? all.length
            : all.where((l) => l.userId == userId).length)
        .clamp(0, totalAllowance);
    final total = totalAllowance;
    final atLimit = used >= total;

    // Only dismissible once spent — and staying dismissed only matters while
    // it's still at the limit (delete a place and the live meter returns).
    if (atLimit && ref.watch(freePlacesChipDismissedProvider)) {
      return const SizedBox.shrink();
    }

    const limitRed = Color(0xFFE5484D);
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: atLimit ? 4 : 12,
        top: 7,
        bottom: 7,
      ),
      decoration: BoxDecoration(
        // At the limit the whole chip goes red — it's no longer progress,
        // it's a blocker, and it should read as one at a glance.
        color: atLimit
            ? Color.alphaBlend(
                limitRed.withValues(alpha: 0.16),
                theme.colorScheme.surface,
              ).withValues(alpha: 0.96)
            : theme.colorScheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: atLimit
              ? limitRed.withValues(alpha: 0.85)
              : theme.dividerColor.withValues(alpha: 0.2),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: atLimit
                ? limitRed.withValues(alpha: 0.28)
                : Colors.black.withValues(alpha: 0.12),
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
                    ? freePlaceSegmentColor(context, i, total: total)
                    : theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
          Text(
            atLimit ? 'Free limit reached' : '$used of $total free places',
            style: theme.textTheme.bodySmall?.copyWith(
              color: atLimit ? limitRed : theme.colorScheme.onSurfaceVariant,
              fontWeight: atLimit ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          if (atLimit)
            Semantics(
              button: true,
              label: 'Dismiss free limit notice',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => ref
                    .read(freePlacesChipDismissedProvider.notifier)
                    .state = true,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.close_rounded, size: 15, color: limitRed),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
