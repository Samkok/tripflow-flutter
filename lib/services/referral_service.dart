import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

import 'analytics_service.dart';
import 'supabase_service.dart';

/// Outcome of a referral-code redemption attempt, shaped for UI decisions.
enum RedeemResult {
  redeemed,
  alreadyRedeemed,
  invalidCode,
  selfReferral,
  windowExpired,
  rateLimited,
  transientFailure, // network / grant_failed — keep the code, retry later
}

/// Client side of the referral system ("Give a month, get a month").
///
/// Signup has NO session (email verification is on), so a code entered at
/// signup is saved locally as a PENDING code and redeemed on the first
/// verified sign-in via [redeemPendingCodeIfAny] (hooked in main.dart's
/// auth listener). Terminal server verdicts clear the pending code;
/// transient ones keep it for the next attempt.
///
/// Never throws into callers — mirrors AnalyticsService's fire-and-forget
/// discipline for everything except the typed [redeemCode] path the
/// referral screen awaits for UI feedback.
class ReferralService {
  ReferralService._();
  static final instance = ReferralService._();

  static const _kPendingCode = 'pending_referral_code';
  static const _kPendingSavedAt = 'pending_referral_code_saved_at_ms';
  static const _kRewardedSeen = 'referral_rewarded_seen_count';
  static const _kHasShared = 'referral_has_shared';

  /// True once the user has ever opened the invite share sheet. Used to
  /// suppress the persistent home banner for people who already advocate.
  Future<bool> hasEverShared() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kHasShared) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Client-side approximation of the server grant moment: when the
  /// referral screen sees more rewarded months than last time, fire the
  /// analytics event once for the delta.
  Future<void> noteRewardedMonths(int monthsTotal) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getInt(_kRewardedSeen) ?? 0;
      if (monthsTotal > seen) {
        AnalyticsService.instance.referralRewardEarned(monthsTotal);
        await prefs.setInt(_kRewardedSeen, monthsTotal);
      }
    } catch (e) {
      debugPrint('ReferralService.noteRewardedMonths: $e');
    }
  }

  Future<void> savePendingCode(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPendingCode, code.trim().toUpperCase());
      await prefs.setInt(
          _kPendingSavedAt, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('ReferralService.savePendingCode: $e');
    }
  }

  Future<void> clearPendingCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kPendingCode);
      await prefs.remove(_kPendingSavedAt);
    } catch (e) {
      debugPrint('ReferralService.clearPendingCode: $e');
    }
  }

  /// Redeem the locally saved pending code, if any and if signed in.
  /// Safe to call repeatedly (idempotent server-side).
  Future<void> redeemPendingCodeIfAny() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString(_kPendingCode);
      if (code == null || code.isEmpty) return;
      final session = SupabaseService.instance.client.auth.currentSession;
      if (session == null) return;

      final result = await redeemCode(code);
      switch (result) {
        case RedeemResult.redeemed:
        case RedeemResult.alreadyRedeemed:
        case RedeemResult.invalidCode:
        case RedeemResult.selfReferral:
        case RedeemResult.windowExpired:
          await clearPendingCode(); // terminal — stop retrying
        case RedeemResult.rateLimited:
        case RedeemResult.transientFailure:
          break; // keep the code; next sign-in / session retries
      }
    } catch (e) {
      debugPrint('ReferralService.redeemPendingCodeIfAny: $e');
    }
  }

  /// Direct redemption (referral screen's "Have a code?" field). Returns a
  /// typed result for user-facing messaging. Requires a signed-in session.
  Future<RedeemResult> redeemCode(String code) async {
    try {
      final client = SupabaseService.instance.client;
      if (client.auth.currentSession == null) {
        return RedeemResult.transientFailure;
      }

      final response = await client.functions.invoke(
        'redeem-referral',
        body: {
          'code': code.trim().toUpperCase(),
          'device_id': await _deviceId(),
        },
      );

      final data = response.data is Map ? response.data as Map : const {};
      if (data['ok'] == true) {
        if (data['status'] != 'already_redeemed') {
          // Analytics only for a FRESH redemption — an already_redeemed
          // verdict just means the client's pending code can be cleared.
          AnalyticsService.instance.referralCodeRedeemed();
          return RedeemResult.redeemed;
        }
        return RedeemResult.alreadyRedeemed;
      }
      return switch (data['reason']) {
        'invalid_code' => RedeemResult.invalidCode,
        'self_referral' => RedeemResult.selfReferral,
        'window_expired' => RedeemResult.windowExpired,
        'already_redeemed' => RedeemResult.alreadyRedeemed,
        'rate_limited' => RedeemResult.rateLimited,
        _ => RedeemResult.transientFailure, // grant_failed / server_error
      };
    } on FunctionException catch (e) {
      // functions.invoke throws on non-2xx (429 rate limit, 502 grant
      // failure, ...). Surface the rate limit; everything else is transient.
      debugPrint('ReferralService.redeemCode fn error: ${e.status}');
      if (e.status == 429) return RedeemResult.rateLimited;
      final details = e.details;
      if (details is Map && details['reason'] == 'rate_limited') {
        return RedeemResult.rateLimited;
      }
      return RedeemResult.transientFailure;
    } catch (e) {
      debugPrint('ReferralService.redeemCode: $e');
      return RedeemResult.transientFailure;
    }
  }

  /// Auto-join any trips this user's email was invited to as a non-user,
  /// and reward both sides. Idempotent server-side; safe to call on every
  /// sign-in. No-op without a session.
  Future<void> claimInvites() async {
    try {
      final client = SupabaseService.instance.client;
      if (client.auth.currentSession == null) return;
      // device_id powers the server's self-referral check (same-device
      // second account farming) — identical to the redeemCode path.
      await client.functions.invoke('claim-invites', body: {
        'device_id': await _deviceId(),
      });
    } catch (e) {
      debugPrint('ReferralService.claimInvites: $e');
    }
  }

  /// The user's stable share code (lazily created server-side).
  Future<String?> getOrCreateMyCode() async {
    try {
      final client = SupabaseService.instance.client;
      if (client.auth.currentSession == null) return null;
      final code = await client.rpc('get_or_create_referral_code');
      return code is String && code.isNotEmpty ? code : null;
    } catch (e) {
      debugPrint('ReferralService.getOrCreateMyCode: $e');
      return null;
    }
  }

  /// Open the OS share sheet with the invite message (covers Messages,
  /// WhatsApp, email — everything the OS offers).
  Future<void> shareInvite(String code) async {
    try {
      AnalyticsService.instance.referralShare();
      // Remember they've shared so we stop nagging them with the banner.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kHasShared, true);
      } catch (_) {}
      await SharePlus.instance.share(ShareParams(
        text: 'I plan my trips with VoyZa — smart routes, zero backtracking. '
            'This code gives you 1 month of Pro free: $code\n'
            'https://voyza.xtremon.com/r/$code',
        subject: 'A free month of VoyZa Pro for you',
      ));
    } catch (e) {
      debugPrint('ReferralService.shareInvite: $e');
    }
  }

  /// Same device-id derivation as the trial-abuse logging in
  /// paywall_screen.dart, so the server's fraud check joins real data.
  Future<String?> _deviceId() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        return (await deviceInfo.androidInfo).id;
      } else if (Platform.isIOS) {
        return (await deviceInfo.iosInfo).identifierForVendor;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
