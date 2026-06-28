import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gating + plumbing around the native in-app review API
/// (`SKStoreReviewController` on iOS, In-App Review API on Android).
///
/// We never call the OS review prompt directly from a "delight moment."
/// Instead the flow is:
///   1. A delight moment (a successful route optimization, or finishing a
///      planned day) records a signal and asks [isEligibleForPrompt].
///   2. If eligible, the UI shows OUR OWN sentiment pre-gate dialog
///      ("Enjoying VoyZa?"). Happy users → [submitPositiveReview] (the real OS
///      prompt). Unhappy users → private feedback (mailto), never the public
///      store prompt. This keeps low ratings out of the App Store and avoids
///      burning Apple's limited annual prompt budget on detractors.
///
/// Eligibility layers (ALL must pass before we even show the sentiment dialog):
///   - OS-level availability ([InAppReview.isAvailable]) — false on Simulator,
///     sideloaded APKs, missing Play Store, etc.
///   - Engagement: at least [_minSessions] app sessions, [_minOptimizes]
///     successful route optimizations, and [_minSavedPlaces] saved places.
///   - Lifetime OS-prompt cap: never more than [_maxOsPrompts] real store
///     prompts (Apple itself caps the dialog ~3×/year and gives us no signal).
///   - Lifetime dialog cap: never show our sentiment dialog more than
///     [_maxDialogsShown] times, so a persistent "Not really" user isn't nagged.
///   - Cooldown: at least [_minCooldown] since we last showed anything.
///
/// Every method is self-contained and swallows its own errors so a delight
/// moment can never throw or block the caller.
class ReviewPromptService {
  ReviewPromptService._();
  static final instance = ReviewPromptService._();

  static const _kLastPromptedAt = 'review_prompt_last_at_ms';
  static const _kOsPromptCount = 'review_prompt_count'; // real OS prompts issued
  static const _kDialogShownCount = 'review_prompt_dialog_count'; // sentiment dialogs shown
  static const _kSuccessfulOptimizes = 'review_prompt_successful_optimizes';
  static const _kSessions = 'review_prompt_sessions';

  // Engagement thresholds — a user must have actually used the app before we ask.
  static const _minSessions = 2;
  static const _minOptimizes = 1;
  static const _minSavedPlaces = 3;

  // Frequency / lifetime caps.
  static const _minCooldown = Duration(days: 60);
  static const _maxOsPrompts = 3;
  static const _maxDialogsShown = 4;

  final InAppReview _api = InAppReview.instance;

  /// Increment the per-install session counter. Call once per app launch
  /// (from bootstrap). Fire-and-forget.
  Future<void> recordSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSessions, (prefs.getInt(_kSessions) ?? 0) + 1);
    } catch (e, st) {
      debugPrint('ReviewPromptService.recordSession: $e\n$st');
    }
  }

  /// Bump the lifetime "successful optimize" counter. This only counts a
  /// delight signal — it never shows the OS prompt by itself. Call on the
  /// optimization SUCCESS path only (never after an error/empty result).
  Future<void> recordSuccessfulOptimize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kSuccessfulOptimizes, (prefs.getInt(_kSuccessfulOptimizes) ?? 0) + 1);
    } catch (e, st) {
      debugPrint('ReviewPromptService.recordSuccessfulOptimize: $e\n$st');
    }
  }

  /// True when every non-UI gate passes and it's appropriate to show the
  /// sentiment pre-gate dialog. [savedPlacesCount] is the live count the caller
  /// already has in hand (e.g. the trip's pinned locations), so we don't couple
  /// this service to trip state.
  Future<bool> isEligibleForPrompt({required int savedPlacesCount}) async {
    try {
      if (savedPlacesCount < _minSavedPlaces) return false;
      if (!await _api.isAvailable()) return false;

      final prefs = await SharedPreferences.getInstance();

      if ((prefs.getInt(_kOsPromptCount) ?? 0) >= _maxOsPrompts) return false;
      if ((prefs.getInt(_kDialogShownCount) ?? 0) >= _maxDialogsShown) {
        return false;
      }
      if ((prefs.getInt(_kSessions) ?? 0) < _minSessions) return false;
      if ((prefs.getInt(_kSuccessfulOptimizes) ?? 0) < _minOptimizes) {
        return false;
      }

      final lastAtMs = prefs.getInt(_kLastPromptedAt);
      if (lastAtMs != null) {
        final lastAt = DateTime.fromMillisecondsSinceEpoch(lastAtMs);
        if (DateTime.now().difference(lastAt) < _minCooldown) return false;
      }

      return true;
    } catch (e, st) {
      debugPrint('ReviewPromptService.isEligibleForPrompt: $e\n$st');
      return false; // fail-closed: never prompt on uncertainty
    }
  }

  /// Record that the sentiment dialog was shown (starts the cooldown and counts
  /// toward the lifetime dialog cap). Call for EVERY outcome of the sentiment
  /// dialog except the positive branch, which uses [submitPositiveReview].
  Future<void> markPromptShown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kLastPromptedAt, DateTime.now().millisecondsSinceEpoch);
      await prefs.setInt(
          _kDialogShownCount, (prefs.getInt(_kDialogShownCount) ?? 0) + 1);
    } catch (e, st) {
      debugPrint('ReviewPromptService.markPromptShown: $e\n$st');
    }
  }

  /// The user said they're happy → issue the real OS review prompt. Records the
  /// cooldown + both lifetime counters BEFORE calling (Apple may silently no-op
  /// and gives us no feedback, so we must not retry on the next delight moment).
  /// Returns true if the OS request was issued.
  Future<bool> submitPositiveReview() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kLastPromptedAt, DateTime.now().millisecondsSinceEpoch);
      await prefs.setInt(
          _kDialogShownCount, (prefs.getInt(_kDialogShownCount) ?? 0) + 1);
      await prefs.setInt(
          _kOsPromptCount, (prefs.getInt(_kOsPromptCount) ?? 0) + 1);

      await _api.requestReview();
      return true;
    } catch (e, st) {
      debugPrint('ReviewPromptService.submitPositiveReview: $e\n$st');
      return false;
    }
  }

  /// Manual entry point for a "Rate VoyZa" button in Settings. Bypasses our
  /// cooldown/engagement gates since the user explicitly asked, but still goes
  /// through the OS — which may silently no-op (Apple annual cap, Simulator,
  /// sideloaded build). A `false` return means "nothing visible happened,
  /// surface a fallback."
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
