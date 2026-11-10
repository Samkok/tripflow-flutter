import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/subscription_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/services/places_gateway.dart';
import 'package:voyza/services/subscription_limit_service.dart';
import 'package:voyza/widgets/add_place_sheet.dart';

import '../helpers/fakes.dart';
import '../helpers/pump.dart';

final _trip = sampleTrip(id: 't1', name: 'Taipei', countryCode: 'TW');
final _day = DateTime(2026, 10, 6);

typedef _H = ({ProviderContainer container, List<int> paywalls});

/// A page with three doors: the add-place sheet, a single add and a batch.
Future<_H> _pump(
  WidgetTester tester, {
  required bool pro,
  bool buys = false,
  bool canWrite = true,
}) async {
  await useMockPrefs();
  final paywalls = <int>[];
  SubscriptionLimitService.paywallOverride = (_) async {
    paywalls.add(1);
    return buys;
  };
  addTearDown(() => SubscriptionLimitService.paywallOverride = null);

  final container = await pumpVoyza(
    tester,
    Consumer(
      builder: (ctx, ref, _) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(
            onPressed: () => showAddPlaceSheet(ctx, trip: _trip, day: _day),
            child: const Text('open'),
          ),
          TextButton(
            onPressed: () async {
              final ok = await SubscriptionLimitService(ref).canAddPlace(ctx);
              _answers.add(ok ? 1 : 0);
            },
            child: const Text('one'),
          ),
          TextButton(
            onPressed: () async => _answers
                .add(await SubscriptionLimitService(ref).canAddPlaces(ctx, 3)),
            child: const Text('three'),
          ),
        ],
      ),
    ),
    overrides: [
      isProProvider.overrideWithValue(pro),
      hasWriteAccessProvider.overrideWith((ref, id) async => canWrite),
      placesGatewayProvider.overrideWithValue(FakePlacesGateway()),
      savedLocationsProvider.overrideWith((ref) => Stream.value(const [])),
      localActiveTripIdProvider
          .overrideWith((ref) => FakeLocalActiveTripNotifier('t1')),
      tripProvider.overrideWith((ref) => FakeTripNotifier()),
      currentUserIdProvider.overrideWithValue('u1'),
      userTripsProvider.overrideWith((ref) async => [_trip]),
      realtimeActiveTripProvider.overrideWith((ref) => Stream.value(null)),
    ],
  );
  // The door reads the member's access synchronously: have it arrived.
  await container.read(hasWriteAccessProvider('t1').future);
  await tester.pumpAndSettle();
  return (container: container, paywalls: paywalls);
}

final _answers = <int>[];

void main() {
  setUp(_answers.clear);

  testWidgets('Pro adds without ever seeing the paywall', (tester) async {
    final h = await _pump(tester, pro: true);
    await tester.tap(find.text('one'));
    await tester.tap(find.text('three'));
    await tester.pumpAndSettle();
    expect(_answers, [1, 3]);

    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(AddPlaceSheet), findsOneWidget);
    expect(h.paywalls, isEmpty);
  });

  testWidgets(
      'a free user meets the paywall on every add; declining adds nothing',
      (tester) async {
    final h = await _pump(tester, pro: false);
    await tester.tap(find.text('one'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('three'));
    await tester.pumpAndSettle();
    expect(_answers, [0, 0], reason: 'no free allowance, single or batch');
    expect(h.paywalls, hasLength(2), reason: 'one paywall per attempt');
  });

  testWidgets(
      'the add-place sheet asks at the door and stays shut when declined',
      (tester) async {
    final h = await _pump(tester, pro: false);
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(h.paywalls, hasLength(1));
    expect(find.byType(AddPlaceSheet), findsNothing);
  });

  testWidgets('subscribing at the door opens the sheet', (tester) async {
    final h = await _pump(tester, pro: false, buys: true);
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(h.paywalls, hasLength(1));
    expect(find.byType(AddPlaceSheet), findsOneWidget);
  });

  testWidgets('a view-only member is not sold Pro for a trip they cannot edit',
      (tester) async {
    final h = await _pump(tester, pro: false, canWrite: false);
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(h.paywalls, isEmpty);
    expect(find.byType(AddPlaceSheet), findsOneWidget,
        reason: 'the sheet explains the view-only role');
  });
}
