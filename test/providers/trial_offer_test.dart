import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:voyza/providers/trial_offer_provider.dart';

void main() {
  const eligible = IntroEligibilityStatus.introEligibilityStatusEligible;
  const ineligible = IntroEligibilityStatus.introEligibilityStatusIneligible;
  const unknown = IntroEligibilityStatus.introEligibilityStatusUnknown;

  TrialOffer decide({
    bool free = true,
    IntroEligibilityStatus? store,
    bool? used,
  }) =>
      decideTrialOffer(
          hasFreeIntro: free, storeStatus: store, usedElsewhere: used);

  test('nothing is promised while any source is still loading', () {
    expect(decide(store: null, used: false), TrialOffer.pending);
    expect(decide(store: eligible, used: null), TrialOffer.pending);
    expect(decide(store: null, used: null), TrialOffer.pending);
  });

  test('a known use settles it, whatever the store says or has not said', () {
    expect(decide(store: eligible, used: true), TrialOffer.used);
    expect(decide(store: unknown, used: true), TrialOffer.used);
    expect(decide(store: null, used: true), TrialOffer.used);
  });

  test('the store\'s "ineligible" settles it even before our own checks', () {
    expect(decide(store: ineligible, used: null), TrialOffer.used);
    expect(decide(store: ineligible, used: false), TrialOffer.used);
  });

  test('eligible or unknown with nothing against it is an offer', () {
    expect(decide(store: eligible, used: false), TrialOffer.available);
    // Android always answers unknown; Google enforces at purchase.
    expect(decide(store: unknown, used: false), TrialOffer.available);
  });

  test('a plan without a free period never offers one', () {
    expect(decide(free: false, store: eligible, used: false), TrialOffer.used);
    expect(decide(free: false, store: null, used: null), TrialOffer.used);
  });
}
