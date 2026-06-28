import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_service.dart';

/// A/B experiment: does giving free users a small saved-place allowance before
/// the hard paywall (so they can reach the route-optimization "aha") convert
/// better than the all-or-nothing gate?
///
///   • control     — today's behavior: the paywall is shown immediately to any
///                   non-Pro user who tries to create/add.
///   • freePlaces  — the non-Pro user may save up to [freePlaceAllowance] places
///                   first; the paywall only appears once they exceed it.
///
/// Assignment is deterministic from the Supabase user id (a hash parity), so:
///   1. a given user is ALWAYS in the same arm, on every device, with no
///      stored state to drift, and
///   2. the arm is reproducible in SQL for measurement — no schema change and
///      no client write needed:
///
///        select
///          case when get_byte(decode(md5(up.user_id::text),'hex'),0) % 2 = 0
///               then 'control' else 'free_places' end as variant,
///          count(*)                                              as users,
///          count(s.user_id) filter (where s.status = 'active')   as converted
///        from user_profiles up
///        left join user_subscriptions s on s.user_id = up.user_id
///        group by 1;
///
/// Anonymous users (no account yet) get a persisted coin-flip purely for
/// in-app gating; they aren't part of the measured cohort until they sign up,
/// at which point the deterministic rule takes over.
enum PaywallVariant { control, freePlaces }

class PaywallExperimentService {
  PaywallExperimentService._();
  static final instance = PaywallExperimentService._();

  /// Saved-place allowance for the treatment arm. Keep in sync with the
  /// `5` documented in the measurement notes if you change it.
  static const int freePlaceAllowance = 5;

  static const _kAnonVariant = 'paywall_anon_variant_v1';

  /// Resolve the variant for the current user. Async only because the
  /// anonymous path reads SharedPreferences; the authenticated path is a pure
  /// hash. Falls back to [PaywallVariant.control] (the safe, current behavior)
  /// on any error.
  Future<PaywallVariant> variant() async {
    try {
      final userId = SupabaseService.instance.client.auth.currentUser?.id;
      if (userId != null && userId.isNotEmpty) {
        return _deterministicForUser(userId);
      }
      return await _anonVariant();
    } catch (_) {
      return PaywallVariant.control;
    }
  }

  /// Parity of the first MD5 byte of the user id → 50/50 split. Mirrors the
  /// SQL `get_byte(decode(md5(user_id::text),'hex'),0) % 2` exactly.
  PaywallVariant _deterministicForUser(String userId) {
    final firstByte = md5.convert(utf8.encode(userId)).bytes.first;
    return firstByte.isEven ? PaywallVariant.control : PaywallVariant.freePlaces;
  }

  Future<PaywallVariant> _anonVariant() async {
    final prefs = await SharedPreferences.getInstance();
    var stored = prefs.getString(_kAnonVariant);
    if (stored == null) {
      stored = Random().nextBool() ? 'free_places' : 'control';
      await prefs.setString(_kAnonVariant, stored);
    }
    return stored == 'free_places'
        ? PaywallVariant.freePlaces
        : PaywallVariant.control;
  }
}
