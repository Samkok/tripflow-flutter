import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_update/in_app_update.dart' as iau;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A newer build exists on this platform's store.
///
/// [versionKey] identifies THE update for dismissal purposes (the badge
/// hides for one version and returns for the next): the marketing version on
/// iOS ("1.7.32"), the Play version code on Android ("available:214").
/// [storeVersion] is displayable ("1.7.32") — null on Android, where the
/// Play API exposes only version codes, not names.
@immutable
class UpdateBadgeInfo {
  final String versionKey;
  final String? storeVersion;

  const UpdateBadgeInfo({required this.versionKey, this.storeVersion});
}

/// Detects whether a newer app version is live on the current platform's
/// store. Deliberately passive and cheap:
///   • ONE check per cold start at most, and the result is cached for
///     [_checkInterval] — relaunches inside the window make no network call;
///   • iOS asks the public iTunes Lookup API (one ~3 KB GET, no key);
///   • Android asks Google's official in-app-update API (Play-installed
///     builds only — dev sideloads answer "unknown" and the check no-ops);
///   • every failure path returns null: the badge simply doesn't show.
class AppUpdateService {
  static const appStoreId = '6758559163';
  static const _lastCheckKey = 'update_check_last_ms';
  static const _lastResultKey = 'update_check_last_result';
  static const _lastInstalledKey = 'update_check_installed_version';
  static const dismissedVersionKey = 'update_badge_dismissed_version';
  static const _checkInterval = Duration(hours: 12);

  /// Dev-only escape hatch: set true temporarily to preview the badge in a
  /// debug/profile run (which the release gate below otherwise suppresses).
  static bool debugPreview = false;

  /// Null = up to date / can't tell / store unreachable.
  static Future<UpdateBadgeInfo?> checkForUpdate() async {
    // RELEASE BUILDS ONLY. Dev builds carry the un-bumped pubspec version
    // (CI stamps the real one at release), so they permanently trail the
    // store and the badge would show in every debug session — the
    // "appears all the time" failure, and pure noise for the developer.
    // Release installs compare truthfully: equal or ahead → no badge.
    if (!kReleaseMode && !debugPreview) return null;

    final installed = (await PackageInfo.fromPlatform()).version;
    final prefs = await SharedPreferences.getInstance();

    // Serve the cached verdict while it's fresh — but never across an app
    // update: a new installed version invalidates the cache immediately,
    // so the badge can't linger after the user already updated.
    final lastMs = prefs.getInt(_lastCheckKey) ?? 0;
    final cacheFresh = prefs.getString(_lastInstalledKey) == installed &&
        DateTime.now().millisecondsSinceEpoch - lastMs <
            _checkInterval.inMilliseconds;
    String? result = cacheFresh ? prefs.getString(_lastResultKey) : null;

    if (result == null) {
      result = Platform.isIOS
          ? await _fetchAppStoreVersion() ?? ''
          : await _fetchPlayVerdict() ?? '';
      await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);
      await prefs.setString(_lastResultKey, result);
      await prefs.setString(_lastInstalledKey, installed);
    }
    if (result.isEmpty) return null;

    if (Platform.isIOS) {
      // One-directional on purpose: TestFlight/dev builds run AHEAD of the
      // store and must never see a badge.
      if (!_isNewer(result, installed)) return null;
      return UpdateBadgeInfo(versionKey: result, storeVersion: result);
    }
    // Android: 'available:<versionCode>' straight from Play — authoritative.
    return UpdateBadgeInfo(versionKey: result);
  }

  /// iTunes Lookup — tries the device storefront first (a version can be
  /// live in one country and still propagating in another), then the
  /// default (US) storefront.
  static Future<String?> _fetchAppStoreVersion() async {
    final country = PlatformDispatcher.instance.locale.countryCode;
    for (final suffix in [
      if (country != null && country.isNotEmpty) '&country=$country',
      '',
    ]) {
      try {
        final res = await http
            .get(Uri.parse(
                'https://itunes.apple.com/lookup?id=$appStoreId$suffix'))
            .timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) continue;
        final data = json.decode(res.body) as Map<String, dynamic>;
        final results = data['results'] as List?;
        if (results == null || results.isEmpty) continue;
        final version = (results.first as Map)['version'] as String?;
        if (version != null && version.isNotEmpty) return version;
      } catch (e) {
        debugPrint('AppUpdateService: lookup failed: $e');
      }
    }
    return null;
  }

  static Future<String?> _fetchPlayVerdict() async {
    try {
      final info = await iau.InAppUpdate.checkForUpdate()
          .timeout(const Duration(seconds: 8));
      if (info.updateAvailability == iau.UpdateAvailability.updateAvailable) {
        return 'available:${info.availableVersionCode ?? 0}';
      }
      return null;
    } catch (e) {
      // Not installed from Play (dev build), Play unavailable, etc.
      debugPrint('AppUpdateService: Play check failed: $e');
      return null;
    }
  }

  /// Semantic segment-wise compare: is [store] strictly newer than [local]?
  /// Handles unequal lengths ("1.8" vs "1.7.32") and non-numeric junk.
  static bool _isNewer(String store, String local) {
    List<int> parse(String v) => v
        .split('.')
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final s = parse(store), l = parse(local);
    for (var i = 0; i < (s.length > l.length ? s.length : l.length); i++) {
      final a = i < s.length ? s[i] : 0;
      final b = i < l.length ? l[i] : 0;
      if (a != b) return a > b;
    }
    return false;
  }
}
