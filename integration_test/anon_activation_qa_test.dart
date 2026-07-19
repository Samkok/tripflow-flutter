import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:voyza/main.dart' as app;

/// End-to-end QA of the ANONYMOUS activation flow (the audit-gap work):
/// fresh install → onboarding → "Try a sample trip" (primary CTA) → 4 seeded
/// places on the Map tab → one-tap Optimize (no start-point chooser on the
/// first run) → route + time-saved reveal → celebration.
///
/// Run via:
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/anon_activation_qa_test.dart -d <simulator>
///
/// Screenshots land in build/qa_shots/ (see the driver). Written for a LIVE
/// app with real async: every advance is marker-based (wait for the next
/// screen's text) and taps RETRY, because a tap fired during a route/page
/// transition is silently absorbed. Screenshots are taken only at settled
/// states — capturing mid-transition produces blank frames on iOS.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Pump until [finder] matches or [timeout] passes.
  Future<bool> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 20),
    Duration step = const Duration(milliseconds: 250),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(step);
      if (finder.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  /// Tap [target] and wait for [marker] (the next state's text). Retries the
  /// tap: a first tap can be swallowed by an in-flight transition.
  Future<bool> tapAndAwait(
    WidgetTester tester,
    Finder target,
    Finder marker, {
    int attempts = 3,
    Duration waitPerAttempt = const Duration(seconds: 6),
  }) async {
    for (var i = 0; i < attempts; i++) {
      if (target.evaluate().isNotEmpty) {
        await tester.tap(target.first, warnIfMissed: false);
      }
      if (await pumpUntil(tester, marker, timeout: waitPerAttempt)) {
        return true;
      }
    }
    return marker.evaluate().isNotEmpty;
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pump(const Duration(milliseconds: 400));
    try {
      await binding.takeScreenshot(name);
    } catch (e) {
      debugPrint('QA screenshot "$name" failed: $e');
    }
  }

  testWidgets('anonymous sample-trip → optimize aha', (tester) async {
    app.main();

    // Cold start (Firebase/RevenueCat init is post-first-frame).
    await tester.pump(const Duration(seconds: 2));
    // NB: the title contains a hard \n — match a fragment, not the full line.
    final sawOnboarding = await pumpUntil(
      tester,
      find.textContaining('What kind of traveler'),
      timeout: const Duration(seconds: 25),
    );
    await shot(tester, '01-first-run');
    expect(sawOnboarding, isTrue,
        reason: 'Fresh install should land on onboarding page 1');

    // Page 1 → traveler type; page 2 arrives ("Where to next?").
    final onPage2 = await tapAndAwait(
      tester,
      find.text('City explorer'),
      find.textContaining('Where to next'),
    );
    await shot(tester, '02-destination-page');
    expect(onPage2, isTrue, reason: 'Traveler tap should advance to page 2');

    // Page 2 → skip country; page 3 arrives (anon primary CTA visible).
    final onPage3 = await tapAndAwait(
      tester,
      find.textContaining('not sure'),
      find.text('Try a sample trip'),
    );
    await shot(tester, '03-value-page');
    expect(onPage3, isTrue,
        reason: 'Anonymous page 3 should offer "Try a sample trip" (primary)');

    // Page 3 → sample seed → Map tab with Optimize available.
    final onMap = await tapAndAwait(
      tester,
      find.text('Try a sample trip'),
      find.text('Optimize Route'),
      attempts: 2,
      waitPerAttempt: const Duration(seconds: 15),
    );
    await shot(tester, '04-map-seeded');
    expect(onMap, isTrue,
        reason: 'Sample seed should land on the map with Optimize available');

    // Regression guard: the map spotlight tour must NOT cover a seeded
    // board — it teaches "add your first place" and eats the Optimize tap.
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Add your first place'), findsNothing,
        reason: 'Map tutorial must not appear over a seeded sample board');

    // One-tap optimize: first run must NOT open the start-point chooser.
    await tester.tap(find.text('Optimize Route').first, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    final chooserOpened =
        find.text('Choose starting point').evaluate().isNotEmpty;
    await shot(tester, '05-after-optimize-tap');
    expect(chooserOpened, isFalse,
        reason: 'First optimize should skip the start-point chooser');

    // Real Directions round-trip → celebration (or straight to summary).
    final sawCelebration = await pumpUntil(
      tester,
      find.textContaining('smartest order'),
      timeout: const Duration(seconds: 45),
    );
    await shot(tester, '06-celebration');
    debugPrint('QA: celebration copy seen = $sawCelebration');

    // Dismiss any dialog (barrier tap) and capture the summary state.
    await tester.tapAt(const Offset(20, 90));
    await tester.pump(const Duration(seconds: 1));
    final sawSummary = await pumpUntil(tester, find.text('Travel Time'),
        timeout: const Duration(seconds: 15));
    await shot(tester, '07-route-summary');

    // The whole point: an anonymous user reached the aha in two taps.
    expect(sawCelebration || sawSummary, isTrue,
        reason: 'Optimize should produce a route (celebration or summary)');
  });
}
