import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/referral.dart';
import '../services/referral_service.dart';
import '../services/supabase_service.dart';
import 'auth_provider.dart';

/// The signed-in user's stable referral code (lazily created server-side).
/// Null when signed out — and for instant (anonymous) accounts: referral
/// identity requires a linked email, and minting codes for throwaway
/// sessions would litter the codes table.
final myReferralCodeProvider = FutureProvider<String?>((ref) async {
  if (!ref.watch(hasLinkedEmailProvider)) return null;
  return ReferralService.instance.getOrCreateMyCode();
});

/// The user's referrals (as referrer), newest first. RLS scopes the select.
final myReferralsProvider = FutureProvider<List<ReferralEntry>>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null || !ref.watch(hasLinkedEmailProvider)) return const [];
  final rows = await SupabaseService.instance.client
      .from('referrals')
      .select('id, status, created_at, qualified_at, banked_at, rewarded_at')
      .eq('referrer_user_id', userId)
      .order('created_at', ascending: false);
  return (rows as List)
      .map((r) => ReferralEntry.fromJson(Map<String, dynamic>.from(r as Map)))
      .toList();
});

/// Months earned but BANKED: the referrer was on active paid coverage when
/// the referee converted, so the free month starts automatically when their
/// current plan ends. Drives the "banked" card on the referral screen.
final referralMonthsBankedProvider = Provider<int>((ref) {
  final referrals = ref.watch(myReferralsProvider).asData?.value ?? const [];
  return referrals.where((r) => r.isBanked).length;
});

/// Months earned in the trailing 365 days (the 12/yr cap window).
final referralMonthsEarnedProvider = Provider<int>((ref) {
  final referrals = ref.watch(myReferralsProvider).asData?.value ?? const [];
  final since = DateTime.now().subtract(const Duration(days: 365));
  return referrals
      .where((r) => r.isRewarded && (r.rewardedAt?.isAfter(since) ?? false))
      .length;
});

/// True once the user has ever opened the invite share sheet (persisted).
final referralHasSharedProvider =
    FutureProvider<bool>((ref) => ReferralService.instance.hasEverShared());

/// Session-scoped dismissal for the persistent home referral banner.
/// Resets on app launch — Settings → Invite friends is the always-on entry.
final referralBannerDismissedProvider = StateProvider<bool>((_) => false);

/// Permanent bonus place slots earned from successful referrals (+2 per
/// redemption, capped at +10 server-side). Granted by the redeem-referral
/// edge function; this is a plain read of the profile row. Guests: 0.
final referralBonusPlacesProvider = FutureProvider<int>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return 0;
  try {
    final row = await SupabaseService.instance.client
        .from('user_profiles')
        .select('referral_bonus_places')
        .eq('user_id', userId)
        .maybeSingle();
    return (row?['referral_bonus_places'] as int?) ?? 0;
  } catch (e) {
    debugPrint('referralBonusPlacesProvider: $e');
    return 0;
  }
});
