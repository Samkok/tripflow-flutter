import 'package:flutter/foundation.dart';

/// What startup may show, in order.
enum StartupStep { onboarding, consent, tracking }

/// Who goes first on a fresh install, decided in one place.
///
/// Fresh guest: onboarding, nothing before it; the consent/notice only once
/// a trip exists (~0.6 s after the list turns non-empty); no map tour, no
/// automatic location prompt and no tracking question in a session that
/// showed onboarding or consent. Existing installs with a trip: consent if
/// still pending, then (ads builds) the tracking question, as before.
///
/// The decisions are pure functions; the session facts live on
/// [instance] and are set by whoever showed the thing.
class FirstRunCoordinator {
  FirstRunCoordinator._();
  static final instance = FirstRunCoordinator._();

  bool onboardingShown = false;
  bool consentShown = false;

  /// Startup found no trip: the consent/notice waits for the first one.
  bool consentArmedForFirstTrip = false;

  /// The first-trip consent ran (or is running) this session.
  bool firstTripConsentAsked = false;

  /// A session that opened with onboarding or consent shows no map tour and
  /// asks for location only when the user taps My location.
  bool get anyPromptShown => onboardingShown || consentShown;

  @visibleForTesting
  void reset() {
    onboardingShown = false;
    consentShown = false;
    consentArmedForFirstTrip = false;
    firstTripConsentAsked = false;
  }

  /// The startup chain for this launch, in order. Each step still checks
  /// its own "already answered" flag when it runs.
  static List<StartupStep> startupSteps({
    required bool linkSeen,
    required bool needsOnboarding,
    required bool hasTrip,
    required bool adsMeasurement,
  }) {
    return [
      if (!linkSeen && needsOnboarding) StartupStep.onboarding,
      if (hasTrip) StartupStep.consent,
      if (hasTrip && adsMeasurement) StartupStep.tracking,
    ];
  }

  /// Apple's tracking question: ads builds, a trip, and never in the same
  /// session as the consent prompt.
  static bool shouldAskTracking({
    required bool adsMeasurement,
    required bool hasTrip,
    required bool consentShownThisSession,
  }) {
    return adsMeasurement && hasTrip && !consentShownThisSession;
  }

  /// The consent/notice on the trips list: only when startup armed it (no
  /// trip then), the list just went from empty to non-empty, and it has not
  /// run this session.
  static bool shouldAskConsentOnTrips({
    required bool armed,
    required bool wasEmpty,
    required bool isNonEmpty,
    required bool alreadyAsked,
  }) {
    return armed && wasEmpty && isNonEmpty && !alreadyAsked;
  }
}
