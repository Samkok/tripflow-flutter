import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/supabase_service.dart';
import 'auth_provider.dart';

/// Truth for "has this account proven its inbox" — VoyZa's own flag
/// (user_profiles.email_verified_at, stamped only by the verify-email-otp
/// edge function). gotrue's email_confirmed_at is auto-stamped the moment
/// a user signs up (dashboard confirmations are off) and proves nothing.
///
/// Semantics: `false` only when the server positively reports unverified.
/// Signed-out and network-error states report `true` so the warning
/// surfaces never nag on bad data — every feature that actually matters
/// re-checks the flag server-side anyway.
///
/// Invalidate after a successful verification or email change (the
/// OtpEntrySheet does this itself).
final emailVerifiedProvider = FutureProvider<bool>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return true;
  try {
    final row = await SupabaseService.instance.client
        .from('user_profiles')
        .select('email_verified_at')
        .eq('user_id', userId)
        .maybeSingle();
    // A missing profile row is an unverified account (signup creates the
    // row with a null stamp; verify-email-otp creates it if even that
    // failed) — nag honestly so the user can fix it.
    return row != null && row['email_verified_at'] != null;
  } catch (_) {
    return true;
  }
});
