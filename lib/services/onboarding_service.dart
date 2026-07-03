import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Milestones that get a one-time celebration/teach. Stored per-user in
/// SharedPreferences via [OnboardingService.markCelebrated].
enum OnboardingMilestone { firstTrip, firstOptimize, firstPlace, mapTutorial }

/// One-time first-run onboarding + activation-milestone bookkeeping.
///
/// Mirrors [AnalyticsConsentService]'s architecture (private ctor, singleton,
/// SharedPreferences, every method swallows errors and fails closed), with one
/// addition: **all keys are per-user** (`<base>_v1_<userId>`) so a second
/// account on the same device still gets onboarding, while sign-out/sign-in
/// on the same account never repeats it.
///
/// For the activation MILESTONES (place toast, optimize celebration) the
/// callers pass the persistent anonymous device UUID when no one is signed
/// in — anonymous users get the same goal-gradient feedback. Onboarding and
/// the first-trip celebration remain authenticated-only (trip creation
/// requires an account; onboarding fires right after signup instead).
///
/// `onboarding_done` values: 'completed' | 'skipped' | 'auto_existing_user'
/// (the last is written by [seedFromExistingState] so users who predate this
/// feature never see onboarding or stale "first!" celebrations).
class OnboardingService {
  OnboardingService._();
  static final instance = OnboardingService._();

  static const _kDone = 'onboarding_done_v1';
  static const _kTravelerType = 'onboarding_traveler_type_v1';
  static const _kDestinationCountry = 'onboarding_destination_country_v1';

  static String _milestoneKey(OnboardingMilestone m) => switch (m) {
        OnboardingMilestone.firstTrip => 'celebrated_first_trip_v1',
        OnboardingMilestone.firstOptimize => 'celebrated_first_optimize_v1',
        OnboardingMilestone.firstPlace => 'toasted_first_place_v1',
        OnboardingMilestone.mapTutorial => 'showed_map_tutorial_v1',
      };

  String _key(String base, String userId) => '${base}_$userId';

  /// True when this user has never completed/skipped/been-seeded past
  /// onboarding. The zero-trips check lives at the call site (it needs
  /// Riverpod access to userTripsProvider).
  Future<bool> shouldShowOnboarding(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key(_kDone, userId)) == null;
    } catch (e) {
      debugPrint('OnboardingService.shouldShowOnboarding: $e');
      return false; // fail closed — never block the app on a prefs error
    }
  }

  Future<void> markOnboardingCompleted(String userId) =>
      _setDone(userId, 'completed');

  Future<void> markOnboardingSkipped(String userId) =>
      _setDone(userId, 'skipped');

  /// Suppress onboarding for [userId] without them going through it —
  /// e.g. a fresh account on a device that already onboarded anonymously.
  Future<void> markOnboardingSuppressed(String userId, String reason) =>
      _setDone(userId, reason);

  Future<void> _setDone(String userId, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(_kDone, userId), value);
    } catch (e) {
      debugPrint('OnboardingService._setDone: $e');
    }
  }

  /// Persist the questionnaire answers. Either may be null (skipped page /
  /// "I'm not sure yet").
  Future<void> saveAnswers(
    String userId, {
    String? travelerType,
    String? countryCode,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (travelerType != null) {
        await prefs.setString(_key(_kTravelerType, userId), travelerType);
      }
      if (countryCode != null) {
        await prefs.setString(_key(_kDestinationCountry, userId), countryCode);
      }
    } catch (e) {
      debugPrint('OnboardingService.saveAnswers: $e');
    }
  }

  Future<String?> getTravelerType(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key(_kTravelerType, userId));
    } catch (_) {
      return null;
    }
  }

  Future<String?> getDestinationCountry(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key(_kDestinationCountry, userId));
    } catch (_) {
      return null;
    }
  }

  /// True when [milestone] was already celebrated for [userId]. Fails closed
  /// (true) so a prefs error can never double-fire a celebration.
  Future<bool> hasCelebrated(
      String userId, OnboardingMilestone milestone) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key(_milestoneKey(milestone), userId)) ?? false;
    } catch (e) {
      debugPrint('OnboardingService.hasCelebrated: $e');
      return true;
    }
  }

  Future<void> markCelebrated(
      String userId, OnboardingMilestone milestone) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key(_milestoneKey(milestone), userId), true);
    } catch (e) {
      debugPrint('OnboardingService.markCelebrated: $e');
    }
  }

  /// Seed flags for a user who was already active before this feature
  /// shipped, so they never see onboarding or hollow "first!" celebrations.
  /// Called once from the MainScreen hook when the user has existing trips.
  Future<void> seedFromExistingState(
    String userId, {
    required bool hasTrips,
    required int lifetimeOptimizes,
  }) async {
    try {
      if (hasTrips) {
        await _setDone(userId, 'auto_existing_user');
        await markCelebrated(userId, OnboardingMilestone.firstTrip);
        await markCelebrated(userId, OnboardingMilestone.firstPlace);
        // Users with trips already know the map — no spotlight tour.
        await markCelebrated(userId, OnboardingMilestone.mapTutorial);
      }
      if (lifetimeOptimizes > 0) {
        await markCelebrated(userId, OnboardingMilestone.firstOptimize);
      }
    } catch (e) {
      debugPrint('OnboardingService.seedFromExistingState: $e');
    }
  }
}
