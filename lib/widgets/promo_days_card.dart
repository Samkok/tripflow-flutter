import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/revenuecat_service.dart';
import '../providers/subscription_provider.dart';

/// Dismissible "you have N free days" card for the home tab, shown while the
/// user's Pro comes from a REFERRAL PROMO (RevenueCat promotional
/// entitlement — `store == promotional`) rather than a store subscription.
///
/// Dismissal is remembered PER PROMO (keyed by its expiry timestamp), so a
/// future, different promo shows the card again while this one stays gone.
class PromoDaysCard extends ConsumerStatefulWidget {
  const PromoDaysCard({super.key});

  @override
  ConsumerState<PromoDaysCard> createState() => _PromoDaysCardState();
}

class _PromoDaysCardState extends ConsumerState<PromoDaysCard> {
  String? _dismissedKey; // loaded from prefs; null = nothing dismissed yet

  @override
  void initState() {
    super.initState();
    _loadDismissed();
  }

  Future<void> _loadDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString('promo_card_dismissed');
      if (mounted && v != null) setState(() => _dismissedKey = v);
    } catch (_) {}
  }

  Future<void> _dismiss(String key) async {
    setState(() => _dismissedKey = key);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('promo_card_dismissed', key);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final customerInfo = ref.watch(
        subscriptionProvider.select((s) => s.customerInfo));
    final ent = customerInfo
        ?.entitlements.active[RevenueCatConfig.entitlementVoyZaPro];
    // Promotional grants only — a real store subscription (including its
    // trial) has its own surfaces (trial countdown banner, management).
    if (ent == null || ent.store != Store.promotional) {
      return const SizedBox.shrink();
    }
    final raw = ent.expirationDate;
    final expires = raw == null ? null : DateTime.tryParse(raw)?.toLocal();
    if (expires == null || !expires.isAfter(DateTime.now())) {
      return const SizedBox.shrink();
    }

    final key = expires.millisecondsSinceEpoch.toString();
    if (_dismissedKey == key) return const SizedBox.shrink();

    final daysLeft = expires.difference(DateTime.now()).inDays + 1;
    final theme = Theme.of(context);
    const green = Color(0xFF23A55A);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: green.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: green.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.card_giftcard_rounded, color: green, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  daysLeft == 1
                      ? 'Last free day of VoyZa Pro'
                      : '$daysLeft days of VoyZa Pro, free',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  'Your referral reward — everything unlocked until '
                  '${DateFormat('MMM d').format(expires)}. No payment, '
                  'nothing starts automatically.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Dismiss',
            color: theme.colorScheme.onSurfaceVariant,
            onPressed: () => _dismiss(key),
          ),
        ],
      ),
    );
  }
}
