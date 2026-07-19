import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Funnel instrumentation — the master unblock from the marketing plan.
///
/// Without these events the team cannot see where users leak (activation is
/// invisible) and the ad platforms cannot optimize for PAYERS instead of cheap
/// installs. Event names mirror the AARRR funnel exactly:
///   signup → trip_created → place_added → route_optimized (the activation aha)
///   → trial_started → purchase.
///
/// Safe to call from any path: every method is fire-and-forget and never throws.
/// Firebase initializes POST-first-frame (see main.dart), so calls before that
/// are silently dropped rather than crashing the caller — critically, we must
/// NOT touch `FirebaseAnalytics.instance` until the default app exists, because
/// that getter throws synchronously (`core/no-app`) and the throw would escape
/// into flows like signup or post-purchase navigation.
class AnalyticsService {
  AnalyticsService._();
  static final instance = AnalyticsService._();

  void _fire(String name, [Map<String, Object>? params]) {
    // `Firebase.apps` never throws; `FirebaseAnalytics.instance` does (before
    // init). Resolve lazily inside the guard + try/catch so nothing escapes.
    if (Firebase.apps.isEmpty) return;
    try {
      unawaited(
        FirebaseAnalytics.instance
            .logEvent(name: name, parameters: params)
            .catchError((Object e) {
          debugPrint('AnalyticsService $name: $e');
        }),
      );
    } catch (e) {
      debugPrint('AnalyticsService $name (pre-init): $e');
    }
  }

  /// A new account was created. [method] = 'email' (extend for OAuth later).
  void signup(String method) => _fire('signup', {'method': method});

  /// A trip was created (first real activation step).
  void tripCreated() => _fire('trip_created');

  /// A place was saved. [totalPlaces] feeds the 3–5 "aha" threshold analysis
  /// (approximate — derived from the current in-memory list).
  void placeAdded(int totalPlaces) =>
      _fire('place_added', {'total_places': totalPlaces});

  /// THE ACTIVATION AHA: a multi-stop route was optimized. [stops] = stop count.
  void routeOptimized(int stops) => _fire('route_optimized', {'stops': stops});

  /// A free trial was started.
  void trialStarted(String product) =>
      _fire('trial_started', {'product': product});

  /// A paid purchase completed (no eligible trial). [price]/[currency] come
  /// from the store product so ad-platform ROAS optimization gets real values.
  void purchase(String product, double price, String currency) => _fire(
        'purchase',
        {'product': product, 'value': price, 'currency': currency},
      );

  /// The paywall was shown to the user. [source] identifies the trigger
  /// (e.g. 'place_limit') so funnel analysis can tell gate-driven views
  /// apart from voluntary upgrade taps.
  void paywallViewed(String source) =>
      _fire('paywall_viewed', {'source': source});

  /// First-run onboarding flow appeared.
  void onboardingStarted() => _fire('onboarding_started');

  /// Onboarding finished via a CTA. [travelerType] is the page-1 answer
  /// (city|food|nature|mixed); [pickedCountry] whether page 2 got a pick.
  void onboardingCompleted(String travelerType, bool pickedCountry) => _fire(
        'onboarding_completed',
        {
          'traveler_type': travelerType,
          'picked_country': pickedCountry ? 'yes' : 'no',
        },
      );

  /// Onboarding dismissed via Skip/back. [step] = 0-based page index.
  void onboardingSkipped(int step) =>
      _fire('onboarding_skipped', {'step': step});

  /// Which onboarding CTA the user tapped to finish. [cta] = 'sample' (the
  /// seeded sample trip — the fastest path to the optimize aha) | 'plan'
  /// (create their own trip / start adding places). Measures sample-trip
  /// uptake, especially for anonymous users once they can see that CTA.
  void onboardingCta(String cta) => _fire('onboarding_cta', {'cta': cta});

  /// A sample trip's places were seeded (the one-tap path to the aha).
  /// [anonymous] distinguishes the no-account local seed from the
  /// authenticated Supabase-trip seed; [placeCount] = seeded place count.
  void sampleTripSeeded({required bool anonymous, required int placeCount}) =>
      _fire('sample_trip_seeded', {
        'anonymous': anonymous ? 'yes' : 'no',
        'place_count': placeCount,
      });

  /// The one-time map spotlight tour was completed ("Got it" on the last
  /// step).
  void mapTutorialCompleted() => _fire('map_tutorial_completed');

  /// The map spotlight tour was skipped. [step] = 0-based index of the
  /// step that was on screen when the user bailed.
  void mapTutorialSkipped(int step) =>
      _fire('map_tutorial_skipped', {'step': step});

  /// The referral share sheet was opened. Organic channel — NEVER imported
  /// into Google Ads (see marketing/analytics-events.md).
  void referralShare() => _fire('referral_share');

  /// A referral code was successfully redeemed (client-observed).
  void referralCodeRedeemed() => _fire('referral_code_redeemed');

  /// The referrer noticed a new earned month. [monthsTotal] = trailing-365d
  /// rewarded count at observation time.
  void referralRewardEarned(int monthsTotal) =>
      _fire('referral_reward_earned', {'months_total': monthsTotal});

  /// A referral invite action was taken from a specific surface. [source] =
  /// celebration | post_purchase | home_banner | collab_invite | settings.
  /// Lets us measure share-rate per placement. Organic — never Ads.
  void referralPromptShown(String source) =>
      _fire('referral_prompt_shown', {'source': source});
}
