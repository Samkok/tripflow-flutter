import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/services/first_run_coordinator.dart';

void main() {
  group('startupSteps', () {
    test('a fresh guest gets onboarding and nothing else', () {
      expect(
          FirstRunCoordinator.startupSteps(
              linkSeen: false,
              needsOnboarding: true,
              hasTrip: false,
              adsMeasurement: true),
          [StartupStep.onboarding]);
    });

    test('a trip link skips onboarding', () {
      expect(
          FirstRunCoordinator.startupSteps(
              linkSeen: true,
              needsOnboarding: true,
              hasTrip: false,
              adsMeasurement: true),
          isEmpty);
    });

    test('a returning user with a trip: consent, then tracking', () {
      expect(
          FirstRunCoordinator.startupSteps(
              linkSeen: false,
              needsOnboarding: false,
              hasTrip: true,
              adsMeasurement: true),
          [StartupStep.consent, StartupStep.tracking]);
    });

    test('a legacy build never asks about tracking', () {
      expect(
          FirstRunCoordinator.startupSteps(
              linkSeen: false,
              needsOnboarding: false,
              hasTrip: true,
              adsMeasurement: false),
          [StartupStep.consent]);
    });
  });

  test('tracking waits a session when consent was just asked', () {
    expect(
        FirstRunCoordinator.shouldAskTracking(
            adsMeasurement: true, hasTrip: true, consentShownThisSession: true),
        isFalse);
    expect(
        FirstRunCoordinator.shouldAskTracking(
            adsMeasurement: true,
            hasTrip: true,
            consentShownThisSession: false),
        isTrue);
    expect(
        FirstRunCoordinator.shouldAskTracking(
            adsMeasurement: true,
            hasTrip: false,
            consentShownThisSession: false),
        isFalse);
  });

  test('the first-trip consent fires once, on empty → non-empty, when armed',
      () {
    bool ask(
            {bool armed = true,
            bool wasEmpty = true,
            bool isNonEmpty = true,
            bool alreadyAsked = false}) =>
        FirstRunCoordinator.shouldAskConsentOnTrips(
            armed: armed,
            wasEmpty: wasEmpty,
            isNonEmpty: isNonEmpty,
            alreadyAsked: alreadyAsked);
    expect(ask(), isTrue);
    expect(ask(armed: false), isFalse, reason: 'startup already asked');
    expect(ask(wasEmpty: false), isFalse, reason: 'not the first trip');
    expect(ask(isNonEmpty: false), isFalse);
    expect(ask(alreadyAsked: true), isFalse);
  });

  test('a session that showed a prompt suppresses the map tour', () {
    final c = FirstRunCoordinator.instance..reset();
    expect(c.anyPromptShown, isFalse);
    c.consentShown = true;
    expect(c.anyPromptShown, isTrue);
    c.reset();
    c.onboardingShown = true;
    expect(c.anyPromptShown, isTrue);
    c.reset();
  });
}
