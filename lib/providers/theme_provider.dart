import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/main.dart';

final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeMode>((ref) {
  return ThemeNotifier();
});

class ThemeNotifier extends StateNotifier<ThemeMode> {
  ThemeNotifier() : super(ThemeMode.dark) {
    _loadTheme();
  }

  static const _themeKey = 'themeMode';

  void _loadTheme() {
    // This notifier is created during the very first frame's MyApp.build,
    // which can run BEFORE _bootstrap() has populated SharedPrefsCache (the
    // first-frame timer races the SharedPreferences platform-channel round
    // trip). Reading SharedPrefsCache.instance directly here would throw and
    // take MyApp.build down with it — rendering a blank screen on cold start.
    // So tolerate the not-ready case: keep the dark default and re-read once
    // bootstrap finishes.
    final prefs = SharedPrefsCache.maybeInstance;
    if (prefs == null) {
      Bootstrap.future.then(
        (_) => _applyFromPrefs(),
        onError: (_) => _applyFromPrefs(),
      );
      return;
    }
    _applyFromPrefs(prefs);
  }

  /// Applies the persisted theme onto [state]. No-op if the cache still isn't
  /// ready (e.g. bootstrap failed before _initSharedPrefs) — the dark default
  /// stays in place.
  void _applyFromPrefs([SharedPreferences? prefs]) {
    prefs ??= SharedPrefsCache.maybeInstance;
    if (prefs == null || !mounted) return;
    final isDarkMode = prefs.getBool(_themeKey) ?? true;
    state = isDarkMode ? ThemeMode.dark : ThemeMode.light;
  }

  Future<void> toggleTheme() async {
    state = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    final prefs = SharedPrefsCache.instance;
    await prefs.setBool(_themeKey, state == ThemeMode.dark);
  }
}
