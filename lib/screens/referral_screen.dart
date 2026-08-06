import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/referral.dart';
import '../providers/referral_provider.dart';
import '../services/referral_service.dart';
import '../services/supabase_service.dart';
import '../widgets/app_toast.dart';
import 'package:voyza/widgets/rotating_globe_background.dart';

/// "Invite friends" — the referral home. Share your code (give a month,
/// get a month), track earned months against the 12/yr cap, and — for
/// fresh accounts that signed up without a code — enter one late.
class ReferralScreen extends ConsumerStatefulWidget {
  const ReferralScreen({super.key});

  @override
  ConsumerState<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends ConsumerState<ReferralScreen> {
  final _codeController = TextEditingController();
  bool _redeeming = false;

  static const _capMonths = 12;
  static const _redemptionWindowDays = 14;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  bool get _accountYoungEnoughToRedeem {
    final createdAt =
        SupabaseService.instance.client.auth.currentUser?.createdAt;
    if (createdAt == null) return false;
    final created = DateTime.tryParse(createdAt);
    if (created == null) return false;
    return DateTime.now().difference(created).inDays < _redemptionWindowDays;
  }

  Future<void> _redeem() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() => _redeeming = true);
    final result = await ReferralService.instance.redeemCode(code);
    if (!mounted) return;
    setState(() => _redeeming = false);
    switch (result) {
      case RedeemResult.redeemed:
        AppToast.success(
            context, 'Code redeemed — enjoy your free month of Pro! 🎉');
        _codeController.clear();
      case RedeemResult.alreadyRedeemed:
        AppToast.info(context, 'A referral code was already used.');
      case RedeemResult.invalidCode:
        AppToast.error(context, 'That code doesn\'t look right.');
      case RedeemResult.selfReferral:
        AppToast.warning(context, 'You can\'t redeem your own code.');
      case RedeemResult.windowExpired:
        AppToast.info(
            context, 'Codes can only be redeemed within 14 days of signup.');
      case RedeemResult.rateLimited:
        AppToast.warning(context, 'Too many attempts — try again later.');
      case RedeemResult.transientFailure:
        AppToast.error(
            context, 'Couldn\'t redeem right now. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codeAsync = ref.watch(myReferralCodeProvider);
    final referralsAsync = ref.watch(myReferralsProvider);
    final monthsEarned = ref.watch(referralMonthsEarnedProvider);
    final monthsBanked = ref.watch(referralMonthsBankedProvider);

    // Client-side "reward earned" analytics moment (idempotent via prefs).
    ref.listen(myReferralsProvider, (prev, next) {
      final months = ref.read(referralMonthsEarnedProvider);
      if (months > 0) ReferralService.instance.noteRewardedMonths(months);
    });

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
          appBar: AppBar(title: const Text('Invite friends')),
          body: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(myReferralsProvider);
              await ref.read(myReferralsProvider.future);
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Offer + code card ─────────────────────────────────────
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.card_giftcard_rounded,
                              color: theme.colorScheme.primary, size: 28),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Give a month, get a month',
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Friends who join with your code get 1 month of VoyZa '
                        'Pro free. The moment they join, you earn +2 free '
                        'place slots — and when they upgrade to a paid plan, '
                        'you get a free month too.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                      Consumer(builder: (context, ref, _) {
                        final bonus = ref
                                .watch(referralBonusPlacesProvider)
                                .valueOrNull ??
                            0;
                        if (bonus <= 0) return const SizedBox.shrink();
                        const amber = Color(0xFFF5A623);
                        return Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Row(
                            children: [
                              const Icon(Icons.add_location_alt_rounded,
                                  size: 16, color: amber),
                              const SizedBox(width: 6),
                              Text(
                                '+$bonus bonus place slots earned',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: amber, fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                        );
                      }),
                      const SizedBox(height: 18),
                      codeAsync.when(
                        loading: () => const Center(
                            child: Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(),
                        )),
                        error: (_, __) => Text(
                          'Couldn\'t load your code — pull to refresh.',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        data: (code) => code == null
                            ? const SizedBox.shrink()
                            : Column(
                                children: [
                                  InkWell(
                                    borderRadius: BorderRadius.circular(14),
                                    onTap: () async {
                                      await Clipboard.setData(
                                          ClipboardData(text: code));
                                      if (context.mounted) {
                                        AppToast.success(context,
                                            'Code copied to clipboard');
                                      }
                                    },
                                    child: Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14, horizontal: 16),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.primary
                                            .withValues(alpha: 0.08),
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                            color: theme.colorScheme.primary
                                                .withValues(alpha: 0.4)),
                                      ),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            code,
                                            style: const TextStyle(
                                              fontFamily: 'monospace',
                                              fontSize: 20,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 1.5,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Icon(Icons.copy_rounded,
                                              size: 18,
                                              color: theme.colorScheme.primary),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      onPressed: () => ReferralService.instance
                                          .shareInvite(code),
                                      icon: const Icon(Icons.ios_share_rounded,
                                          size: 20),
                                      label: const Text(
                                        'Share your invite',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w700),
                                      ),
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // ── Earned meter ──────────────────────────────────────────
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$monthsEarned of $_capMonths free months earned this year',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: monthsEarned / _capMonths,
                          minHeight: 8,
                          backgroundColor: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.15),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // ── Banked months ─────────────────────────────────────────
                // Earned while the user was on active paid coverage — the
                // month starts automatically the moment their plan ends, so
                // nothing burns underneath a subscription they already paid
                // for. Hidden when there's nothing banked.
                if (monthsBanked > 0) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF38BDF8).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.45),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.savings_rounded,
                            color: Color(0xFF38BDF8), size: 28),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                monthsBanked == 1
                                    ? '1 free month banked'
                                    : '$monthsBanked free months banked',
                                style: theme.textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'You\'re already subscribed, so these start '
                                'automatically when your current plan ends — '
                                'no days wasted.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // ── Late code entry (fresh accounts only) ────────────────
                if (_accountYoungEnoughToRedeem) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.cardColor,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Have a referral code?',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _codeController,
                                textCapitalization:
                                    TextCapitalization.characters,
                                decoration: const InputDecoration(
                                  hintText: 'VOYZA-XXXXXX',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton(
                              onPressed: _redeeming ? null : _redeem,
                              child: _redeeming
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Text('Redeem'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // ── Referral history ──────────────────────────────────────
                Text('Your invites',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                referralsAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (_, __) => Text(
                    'Couldn\'t load your invites — pull to refresh.',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  data: (referrals) => referrals.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Text(
                            'No invites yet — share your code to start earning '
                            'free months.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        )
                      : Column(
                          children: referrals
                              .map((r) => _ReferralTile(entry: r))
                              .toList(),
                        ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ReferralTile extends StatelessWidget {
  final ReferralEntry entry;

  const _ReferralTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fmt = DateFormat('MMM d');
    final (label, color, icon) = switch (entry.status) {
      'rewarded' => (
          'Earned',
          const Color(0xFF22C55E),
          Icons.check_circle_rounded
        ),
      'banked' => ('Banked', const Color(0xFF38BDF8), Icons.savings_rounded),
      'qualified' => (
          'On the way',
          const Color(0xFFF59E0B),
          Icons.hourglass_top_rounded
        ),
      _ => ('Pending', theme.colorScheme.onSurfaceVariant, Icons.schedule),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.person_rounded, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'A friend joined · ${fmt.format(entry.createdAt)}',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w700, fontSize: 13)),
        ],
      ),
    );
  }
}
