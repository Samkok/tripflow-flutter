import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show SharedPrefsCache;
import '../services/app_update_service.dart';

/// One store check per app session (the service adds its own 12 h on-disk
/// throttle across sessions). The initial delay keeps it clear of the
/// startup sync + first paint — the badge is allowed to arrive late.
final appUpdateProvider = FutureProvider<UpdateBadgeInfo?>((ref) async {
  await Future.delayed(const Duration(seconds: 4));
  try {
    return await AppUpdateService.checkForUpdate();
  } catch (_) {
    return null; // never let a store hiccup surface anywhere
  }
});

/// The version key the user dismissed the badge for — that one stays
/// hidden; the NEXT release shows the badge again. maybeInstance: this is
/// first read during the home page's first build, which can win the race
/// against the prefs cache warm-up on cold start (see SharedPrefsCache).
final updateBadgeDismissedProvider = StateProvider<String?>((ref) =>
    SharedPrefsCache.maybeInstance
        ?.getString(AppUpdateService.dismissedVersionKey));

Future<void> dismissUpdateBadge(WidgetRef ref, String versionKey) async {
  ref.read(updateBadgeDismissedProvider.notifier).state = versionKey;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(AppUpdateService.dismissedVersionKey, versionKey);
}
