import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/email_verified_provider.dart';
import 'app_toast.dart';
import 'otp_entry_sheet.dart';

/// Settings-page nudge for accounts that haven't proven their inbox yet.
///
/// NOT dismissible (owner call, 2026-08-15): an unverified email leaves
/// invites, referrals and account recovery locked, so "later" is never the
/// right answer — verifying is. The banner clears the moment
/// [emailVerifiedProvider] flips true (the OTP sheet invalidates it on
/// success), and renders nothing when signed out, verified, or still
/// loading.
class EmailVerifyBanner extends ConsumerWidget {
  const EmailVerifyBanner({super.key});

  Future<void> _verifyNow(BuildContext context) async {
    final ok = await showOtpEntrySheet(
      context,
      mode: OtpSheetMode.verifyEmail,
      sendOnOpen: true,
    );
    if (ok == true && context.mounted) {
      AppToast.success(
          context, 'Email verified! Invites and referrals are unlocked.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(currentUserIdProvider) == null) {
      return const SizedBox.shrink();
    }
    // `false` only when the server positively reports unverified — a
    // loading or errored read stays quiet rather than nagging on bad data.
    if (ref.watch(emailVerifiedProvider).valueOrNull != false) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final amber = Colors.amber.shade800;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.amber.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: amber, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Your email isn't verified yet",
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: amber,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Verify to secure your account and unlock invites '
                    'and referral rewards.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  TextButton(
                    onPressed: () => _verifyNow(context),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      foregroundColor: amber,
                    ),
                    child: const Text(
                      'Verify now',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
