import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/abuse_check_device_id.dart';
import '../services/revenuecat_service.dart';
import 'auth_provider.dart';
import 'subscription_provider.dart';

/// Whether the paywall may promise a free trial.
///
/// The old rule asked StoreKit alone and said "yes" while the answer was
/// still loading or came back unknown — so every paywall opened on "Start
/// free trial" and then flipped to "Subscribe" when the store answered, and
/// a user who had used the trial kept being offered one whenever the store
/// was unsure (always, on Android). This decision is pessimistic instead:
/// nothing is promised until every source has spoken, and anything that
/// says the trial was used settles it.
enum TrialOffer {
  /// Some source has not answered yet — show the plain subscribe copy.
  pending,

  /// A free trial is on the table.
  available,

  /// No trial: used before, or the plan has none.
  used,
}

/// The one decision, kept pure for the tests.
///
/// - [hasFreeIntro]: the plan has a FREE introductory period at all.
/// - [storeStatus]: StoreKit's per-product answer; null while loading.
/// - [usedElsewhere]: what the app knows on its own (RevenueCat history,
///   our database, this device); null while still loading.
TrialOffer decideTrialOffer({
  required bool hasFreeIntro,
  required IntroEligibilityStatus? storeStatus,
  required bool? usedElsewhere,
}) {
  if (!hasFreeIntro) return TrialOffer.used;
  if (usedElsewhere == true) return TrialOffer.used;
  if (storeStatus == IntroEligibilityStatus.introEligibilityStatusIneligible) {
    return TrialOffer.used;
  }
  if (usedElsewhere == null || storeStatus == null) return TrialOffer.pending;
  // Eligible, or unknown (Android always; iOS without subscription-group
  // info): nothing says it was used, so the offer stands — the store still
  // enforces eligibility at purchase.
  return TrialOffer.available;
}

const _usedPrefsKey = 'trial_used_v1';

/// True once anything the app can see says this person or this device has
/// already had the trial:
///   - RevenueCat: any Pro entitlement in the customer's history (active,
///     expired, trial or paid — a store grants one intro offer per group);
///   - our database: a subscription row, or `trial_started_at` on the
///     profile;
///   - this device: the `trial_devices` record (through the server
///     function; the table itself is closed to clients);
///   - a remembered answer from an earlier run.
/// A "yes" is remembered on the device, so the next cold start opens the
/// paywall on the right words with no flip. Each network source is given a
/// few seconds and then counts as "no" rather than blocking the paywall.
final trialUsedProvider = FutureProvider<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_usedPrefsKey) == true) return true;

  final rcHistory = ref.watch(subscriptionProvider.select((s) {
    final info = s.customerInfo;
    if (info == null) return false;
    return info.entitlements.all
            .containsKey(RevenueCatConfig.entitlementVoyZaPro) ||
        info.allPurchasedProductIdentifiers.isNotEmpty;
  }));
  final dbRow =
      ref.watch(subscriptionProvider.select((s) => s.databaseStatus != null));
  if (rcHistory || dbRow) {
    await _remember(prefs);
    return true;
  }

  final userId = ref.watch(currentUserIdProvider);
  final repo = ref.read(userProfileRepositoryProvider);
  const patience = Duration(seconds: 4);

  Future<bool> profileSaysUsed() async {
    if (userId == null) return false;
    try {
      final profile =
          await repo.getUserProfile(userId).timeout(patience, onTimeout: () {
        debugPrint('trialUsedProvider: profile read timed out');
        return null;
      });
      return profile?.trialStartAt != null;
    } catch (e) {
      debugPrint('trialUsedProvider: profile read failed - $e');
      return false;
    }
  }

  Future<bool> deviceSaysUsed() async {
    try {
      final deviceId = await abuseCheckDeviceId();
      if (deviceId == null) return false;
      final started = await repo.getTrialForDevice(deviceId).timeout(patience,
          onTimeout: () {
        debugPrint('trialUsedProvider: device read timed out');
        return null;
      });
      return started != null;
    } catch (e) {
      debugPrint('trialUsedProvider: device read failed - $e');
      return false;
    }
  }

  final answers = await Future.wait([profileSaysUsed(), deviceSaysUsed()]);
  final used = answers.any((a) => a);
  if (used) await _remember(prefs);
  return used;
});

Future<void> _remember(SharedPreferences prefs) async {
  try {
    await prefs.setBool(_usedPrefsKey, true);
  } catch (_) {}
}

/// Call right after a trial starts, then invalidate [trialUsedProvider]:
/// from now on this device never offers another, whatever the store says
/// in the meantime.
Future<void> rememberTrialUsed() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await _remember(prefs);
  } catch (_) {}
}
