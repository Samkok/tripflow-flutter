import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thin wrapper around the native in-app review API (`SKStoreReviewController`
/// on iOS, In-App Review API on Android) that adds our own gating so we don't
/// even ask the OS to consider showing the prompt outside of "delight moments."
///
/// Gating layers (all must pass):
///   1. OS-level availability (`isAvailable`). Returns false on Simulator,
///      sideloaded APKs, etc.
///   2. Lifetime cap: never more than [_maxLifetimePrompts] requests for the
///      whole install.
///   3. Cooldown: at least [_minCooldown] since the last request.
///
/// Note we record the attempt **before** calling [requestReview] so a single
/// delight moment can't burn through the lifetime cap if the OS silently
/// no-ops (Apple has its own annual cap on the system dialog and gives us no
/// feedback either way).
class ReviewPromptService {
  ReviewPromptService._();
  static final instance = ReviewPromptService._();

  static const _kLastPromptedAt = 'review_prompt_last_at_ms';
  static const _kPromptCount = 'review_prompt_count';
  static const _kSuccessfulOptimizes = 'review_prompt_successful_optimizes';

  static const _minCooldown = Duration(days: 60);
  static const _maxLifetimePrompts = 3;
  static const _optimizeThreshold = 10;

  final InAppReview _api = InAppReview.instance;

  /// Call from a delight moment (e.g. trip day completed). Safe to call
  /// from any path: gating + try/catch means it never throws or interrupts
  /// the caller. Returns true when the OS request was actually issued.
  Future<bool> maybeRequestReview() async {
    try {
      if (!await _api.isAvailable()) return false;

      final prefs = await SharedPreferences.getInstance();

      final count = prefs.getInt(_kPromptCount) ?? 0;
      if (count >= _maxLifetimePrompts) return false;

      final lastAtMs = prefs.getInt(_kLastPromptedAt);
      if (lastAtMs != null) {
        final lastAt = DateTime.fromMillisecondsSinceEpoch(lastAtMs);
        if (DateTime.now().difference(lastAt) < _minCooldown) return false;
      }

      // Persist BEFORE calling — the OS may silently skip the dialog
      // (Apple caps it ~3×/year per user) but we don't want to retry on
      // every subsequent delight moment within the cooldown window.
      await prefs.setInt(
          _kLastPromptedAt, DateTime.now().millisecondsSinceEpoch);
      await prefs.setInt(_kPromptCount, count + 1);

      await _api.requestReview();
      return true;
    } catch (e, st) {
      debugPrint('ReviewPromptService: $e\n$st');
      return false;
    }
  }

  /// Bumps the lifetime "successful optimize" counter and fires the review
  /// prompt the first time it crosses [_optimizeThreshold]. The counter keeps
  /// growing past the threshold but only triggers once at the crossing — the
  /// trip-day completion path and the [_minCooldown] in [maybeRequestReview]
  /// handle any later asks.
  Future<void> recordSuccessfulOptimize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final count = (prefs.getInt(_kSuccessfulOptimizes) ?? 0) + 1;
      await prefs.setInt(_kSuccessfulOptimizes, count);
      if (count == _optimizeThreshold) {
        await maybeRequestReview();
      }
    } catch (e, st) {
      debugPrint('ReviewPromptService.recordSuccessfulOptimize: $e\n$st');
    }
  }

  /// Manual entry point for a "Rate this app" button in settings. Bypasses
  /// our cooldown/lifetime caps since the user explicitly asked, but still
  /// goes through the OS — which may silently no-op if Apple's annual cap
  /// is hit. Caller should treat a `false` return as "nothing visible
  /// happened, surface a fallback (e.g. mailto)."
  Future<bool> requestReviewManually() async {
    try {
      if (!await _api.isAvailable()) return false;
      await _api.requestReview();
      return true;
    } catch (e, st) {
      debugPrint('ReviewPromptService.requestReviewManually: $e\n$st');
      return false;
    }
  }
}
