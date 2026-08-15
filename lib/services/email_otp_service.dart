import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

import 'supabase_service.dart';

/// Outcome of asking the server to mail a 6-digit code.
enum OtpSendStatus {
  sent,
  cooldown, // a code went out <60s ago — it's still valid, check the inbox
  rateLimited, // 5 sends in the past hour — try later
  emailTaken, // email_change only: address already on a VoyZa account
  sameEmail, // email_change only: same as the current address
  invalidEmail, // email_change only: not an email
  failed, // send_failed / server_error / network
}

/// Outcome of submitting a code.
enum OtpVerifyStatus {
  verified,
  invalidCode,
  expired,
  noCode, // nothing live for this purpose — resend
  tooManyAttempts, // code killed after 5 wrong tries — resend
  emailTaken, // email_change only: address got claimed since the send
  failed,
}

class OtpVerifyResult {
  final OtpVerifyStatus status;
  final int? attemptsLeft;

  /// email_change success: the address the account now lives on.
  final String? email;

  const OtpVerifyResult(this.status, {this.attemptsLeft, this.email});
}

/// Client for the send-email-otp / verify-email-otp edge functions —
/// VoyZa's own verification layer (dashboard "Confirm email" is off, so
/// inbox ownership is proven here and recorded in
/// user_profiles.email_verified_at).
class EmailOtpService {
  EmailOtpService._();

  /// Mails a code. purpose 'verify' proves the account's current email;
  /// 'email_change' (with [newEmail]) proves a new address before the
  /// account is switched onto it.
  static Future<OtpSendStatus> sendCode({
    String purpose = 'verify',
    String? newEmail,
  }) async {
    try {
      final client = SupabaseService.instance.client;
      if (client.auth.currentSession == null) return OtpSendStatus.failed;
      final res = await client.functions.invoke('send-email-otp', body: {
        'purpose': purpose,
        if (newEmail != null) 'new_email': newEmail.trim(),
      });
      final data = res.data is Map ? res.data as Map : const {};
      if (data['ok'] == true) return OtpSendStatus.sent;
      return _sendStatusFromReason(data['reason']);
    } on FunctionException catch (e) {
      // invoke throws on non-2xx; the 429s carry our reason in the body.
      final details = e.details;
      final reason = details is Map ? details['reason'] : null;
      debugPrint('EmailOtpService.sendCode fn error ${e.status}: $reason');
      if (reason != null) return _sendStatusFromReason(reason);
      if (e.status == 429) return OtpSendStatus.cooldown;
      return OtpSendStatus.failed;
    } catch (e) {
      debugPrint('EmailOtpService.sendCode: $e');
      return OtpSendStatus.failed;
    }
  }

  static OtpSendStatus _sendStatusFromReason(Object? reason) {
    return switch (reason) {
      'cooldown' => OtpSendStatus.cooldown,
      'rate_limited' => OtpSendStatus.rateLimited,
      'email_taken' => OtpSendStatus.emailTaken,
      'same_email' => OtpSendStatus.sameEmail,
      'invalid_email' => OtpSendStatus.invalidEmail,
      _ => OtpSendStatus.failed, // no_email / email_disabled / send_failed
    };
  }

  /// Submits [code]. On 'verify' success the server stamps
  /// user_profiles.email_verified_at; on 'email_change' success it swaps
  /// the auth email — the caller must refresh the session afterwards (the
  /// local JWT still carries the old address).
  static Future<OtpVerifyResult> verifyCode({
    String purpose = 'verify',
    required String code,
  }) async {
    try {
      final client = SupabaseService.instance.client;
      if (client.auth.currentSession == null) {
        return const OtpVerifyResult(OtpVerifyStatus.failed);
      }
      final res = await client.functions.invoke('verify-email-otp', body: {
        'purpose': purpose,
        'code': code.trim(),
      });
      final data = res.data is Map ? res.data as Map : const {};
      if (data['ok'] == true) {
        return OtpVerifyResult(
          OtpVerifyStatus.verified,
          email: data['email'] as String?,
        );
      }
      final status = switch (data['reason']) {
        'invalid_code' => OtpVerifyStatus.invalidCode,
        'expired' => OtpVerifyStatus.expired,
        'no_code' => OtpVerifyStatus.noCode,
        'too_many_attempts' => OtpVerifyStatus.tooManyAttempts,
        'email_taken' => OtpVerifyStatus.emailTaken,
        _ => OtpVerifyStatus.failed,
      };
      return OtpVerifyResult(
        status,
        attemptsLeft: (data['attempts_left'] as num?)?.toInt(),
      );
    } catch (e) {
      debugPrint('EmailOtpService.verifyCode: $e');
      return const OtpVerifyResult(OtpVerifyStatus.failed);
    }
  }
}
