import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/main.dart';

/// Remembers the email addresses this device has actually used to sign in or
/// sign up, so the auth screens can offer them back instead of making the
/// user retype.
///
/// Scope note: this is the app's OWN history. The device password manager's
/// saved credentials (iOS Keychain / Google Password Manager) are deliberately
/// off limits to apps — only the platform's autofill UI may surface those, and
/// it does, via the `autofillHints` already set on the email fields. So the
/// user sees BOTH: the OS QuickType bar above the keyboard, and this in-app
/// list below the field.
///
/// Emails only. Passwords are never stored here.
class EmailHistoryService {
  EmailHistoryService._();
  static final EmailHistoryService instance = EmailHistoryService._();

  static const _key = 'email_history';
  static const _maxEntries = 5;

  /// Cached copy so the auth screens can filter synchronously while typing.
  List<String> _cache = const [];
  List<String> get emails => _cache;

  /// Loads the stored list into [emails]. Safe to call repeatedly.
  Future<List<String>> load() async {
    try {
      final prefs = SharedPrefsCache.maybeInstance;
      if (prefs == null) {
        _cache = const [];
        return _cache;
      }
      _cache = prefs.getStringList(_key) ?? const [];
      return _cache;
    } catch (e) {
      debugPrint('EmailHistoryService.load: $e');
      _cache = const [];
      return _cache;
    }
  }

  /// Records [email] as most-recently-used. No-ops on blank input; de-dupes
  /// case-insensitively and keeps the list capped at [_maxEntries].
  Future<void> remember(String email) async {
    final value = email.trim().toLowerCase();
    if (value.isEmpty || !value.contains('@')) return;
    try {
      final prefs = SharedPrefsCache.maybeInstance ??
          await SharedPreferences.getInstance();
      final current = List<String>.from(prefs.getStringList(_key) ?? const []);
      current.removeWhere((e) => e.toLowerCase() == value);
      current.insert(0, value);
      if (current.length > _maxEntries) {
        current.removeRange(_maxEntries, current.length);
      }
      await prefs.setStringList(_key, current);
      _cache = current;
    } catch (e) {
      debugPrint('EmailHistoryService.remember: $e');
    }
  }

  /// Removes a single entry (the ✕ on a suggestion row).
  Future<void> forget(String email) async {
    try {
      final prefs = SharedPrefsCache.maybeInstance ??
          await SharedPreferences.getInstance();
      final current = List<String>.from(prefs.getStringList(_key) ?? const []);
      current.removeWhere((e) => e.toLowerCase() == email.toLowerCase());
      await prefs.setStringList(_key, current);
      _cache = current;
    } catch (e) {
      debugPrint('EmailHistoryService.forget: $e');
    }
  }

  /// Entries matching [query]. Empty query returns everything, which is what
  /// makes the list appear the moment the field is focused.
  List<String> suggestionsFor(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return _cache;
    // Exact match adds nothing — the user has already typed it in full.
    return _cache
        .where((e) => e.toLowerCase().contains(q) && e.toLowerCase() != q)
        .toList();
  }
}
