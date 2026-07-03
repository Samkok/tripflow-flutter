import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/referral_provider.dart';
import '../services/analytics_service.dart';
import '../services/referral_service.dart';
import 'app_toast.dart';

/// The single action every referral surface calls. Resolves the user's code
/// (lazily creating it), records which surface drove the share, and opens the
/// OS share sheet. Never throws.
Future<void> inviteFriends(
  BuildContext context,
  WidgetRef ref, {
  required String source,
}) async {
  AnalyticsService.instance.referralPromptShown(source);
  // Prefer the already-loaded provider value; fall back to a fresh fetch.
  var code = ref.read(myReferralCodeProvider).asData?.value;
  code ??= await ReferralService.instance.getOrCreateMyCode();
  if (code == null) {
    if (context.mounted) {
      AppToast.info(context, 'Couldn\'t load your invite code — try again.');
    }
    return;
  }
  await ReferralService.instance.shareInvite(code);
}

/// A congrats dialog shown once right after a fresh Pro purchase — the
/// happiest moment. Returns after the user dismisses (share or "Maybe later").
Future<void> showReferralAfterPurchase(
    BuildContext context, WidgetRef ref) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🎉', style: TextStyle(fontSize: 44)),
              const SizedBox(height: 12),
              Text(
                'Welcome to VoyZa Pro!',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Know someone else planning a trip? Invite them — they get a '
                'free month, and so do you.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    inviteFriends(context, ref, source: 'post_purchase');
                  },
                  icon: const Icon(Icons.card_giftcard_rounded, size: 20),
                  label: const Text('Share your code',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Maybe later'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Persistent, dismissible "invite friends" card for the Trips home.
/// Self-suppresses for signed-out users and for advocates (already shared,
/// or already have referrals) so it never nags.
class ReferralHomeBanner extends ConsumerWidget {
  const ReferralHomeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(currentUserIdProvider) == null) {
      return const SizedBox.shrink();
    }
    if (ref.watch(referralBannerDismissedProvider)) {
      return const SizedBox.shrink();
    }
    // Advocates: already shared, or already have at least one referral.
    if (ref.watch(referralHasSharedProvider).asData?.value == true) {
      return const SizedBox.shrink();
    }
    if ((ref.watch(myReferralsProvider).asData?.value ?? const []).isNotEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.14),
              theme.colorScheme.secondary.withValues(alpha: 0.14),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.25)),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => inviteFriends(context, ref, source: 'home_banner'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
              child: Row(
                children: [
                  Text('🎁', style: TextStyle(fontSize: 24)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Give a month, get a month',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Invite a friend — you both get a free month of Pro.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    icon: Icon(Icons.close,
                        size: 18, color: theme.colorScheme.onSurfaceVariant),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => ref
                        .read(referralBannerDismissedProvider.notifier)
                        .state = true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
