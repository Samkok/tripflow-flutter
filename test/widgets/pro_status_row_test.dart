import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/providers/subscription_provider.dart';
import 'package:voyza/utils/pro_status_copy.dart';
import 'package:voyza/widgets/pro_status_row.dart';

import '../helpers/fakes.dart';
import '../helpers/pump.dart';

final _now = DateTime.now();

Future<FakeSubscriptionNotifier> _pump(
    WidgetTester tester, ProStatus status) async {
  await useMockPrefs();
  final subs = FakeSubscriptionNotifier();
  await pumpVoyza(
    tester,
    const Padding(padding: EdgeInsets.all(16), child: ProStatusRow()),
    overrides: [
      proStatusProvider.overrideWithValue(status),
      subscriptionProvider.overrideWith((ref) => subs),
      // The subscription screen the row opens asks these.
      subscriptionExpirationProvider.overrideWith((ref) async => null),
      willRenewProvider.overrideWith((ref) async => false),
      voyZaProEntitlementProvider.overrideWith((ref) async => null),
    ],
  );
  await tester.pumpAndSettle();
  return subs;
}

void main() {
  testWidgets('free sells, with an Upgrade pill', (tester) async {
    await _pump(tester, ProStatus.free);
    expect(find.text('VoyZa Pro'), findsOneWidget);
    expect(find.text('Unlock unlimited places'), findsOneWidget);
    expect(find.text('Upgrade'), findsOneWidget);
  });

  testWidgets('a trial says when it ends', (tester) async {
    await _pump(
        tester,
        ProStatus(
            tier: ProTier.trial,
            expiresAt: _now.add(const Duration(days: 2, hours: 2))));
    expect(find.text('VoyZa Pro trial'), findsOneWidget);
    expect(find.text('Ends in 3 days'), findsOneWidget);
    expect(find.text('Upgrade'), findsNothing);
  });

  testWidgets('pro says when it renews', (tester) async {
    await _pump(
        tester,
        ProStatus(
            tier: ProTier.pro,
            expiresAt: DateTime(2027, 3, 9),
            willRenew: true));
    expect(find.text('Renews 9 Mar 2027'), findsOneWidget);
  });

  testWidgets('lifetime says so', (tester) async {
    await _pump(tester, const ProStatus(tier: ProTier.pro));
    expect(find.text('Lifetime'), findsOneWidget);
  });

  testWidgets('a tap opens the subscription screen and refreshes on return',
      (tester) async {
    final subs = await _pump(tester, ProStatus.free);
    await tester.tap(find.text('Upgrade'));
    await tester.pumpAndSettle();
    expect(find.text('Subscription'), findsOneWidget, reason: 'the screen');
    expect(find.text('Free Plan'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(subs.refreshes, 1);
  });
}
