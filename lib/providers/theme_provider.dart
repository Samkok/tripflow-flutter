import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    // PERFORMANCE: Use cached SharedPreferences - no async needed
    final prefs = SharedPrefsCache.instance;
    final isDarkMode = prefs.getBool(_themeKey) ?? true;
    state = isDarkMode ? ThemeMode.dark : ThemeMode.light;
  }

  Future<void> toggleTheme() async {
    state = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    final prefs = SharedPrefsCache.instance;
    await prefs.setBool(_themeKey, state == ThemeMode.dark);
  }
}