import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';

import '../helpers/fakes.dart';
import '../helpers/pump.dart';

final _day = DateTime(2026, 10, 6);
final _trip = sampleTrip(id: 't1', start: DateTime(2026, 10, 5));

LocationModel _loc() => LocationModel(
      id: 'l1',
      name: 'Din Tai Fung',
      address: 'Xinyi',
      coordinates: const LatLng(25.033, 121.53),
      addedAt: _day,
      scheduledDate: _day,
      tripId: 't1',
      tag: 'food',
      stayDuration: const Duration(minutes: 90),
    );

Future<ProviderContainer> _pump(WidgetTester tester,
    {bool canWrite = true}) async {
  await useMockPrefs();
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  final container = await pumpVoyza(
    tester,
    SingleChildScrollView(
      child: LocationDetailSheet(
        location: _loc(),
        number: 1,
        parentScrollController: scroll,
        tripId: 't1',
        locationsForDate: [_loc()],
      ),
    ),
    overrides: [
      tripProvider.overrideWith(
          (ref) => FakeTripNotifier(TripState(pinnedLocations: [_loc()]))),
      hasWriteAccessProvider.overrideWith((ref, id) async => canWrite),
      localActiveTripIdProvider
          .overrideWith((ref) => FakeLocalActiveTripNotifier('t1')),
      userTripsProvider.overrideWith((ref) async => [_trip]),
      realtimeActiveTripProvider.overrideWith((ref) => Stream.value(_trip)),
    ],
  );
  await container.read(hasWriteAccessProvider('t1').future);
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('the top row is Done · Skip · Route · Schedule; the rest folds',
      (tester) async {
    await _pump(tester);
    for (final label in ['Done', 'Skip', 'Route', 'Schedule']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Details'), findsOneWidget);
    expect(find.textContaining('Stay 1h 30m'), findsOneWidget,
        reason: 'the folded row still tells the stay');
    expect(find.text('Edit'), findsNothing, reason: 'folded');
    expect(find.text('Delete'), findsOneWidget, reason: 'once, at the end');
  });

  testWidgets('Details opens the tag, stay, accommodation and range rows',
      (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('Stay · 1h 30m'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
  });

  testWidgets('read-only members keep Route but lose Done and Delete',
      (tester) async {
    await _pump(tester, canWrite: false);
    final delete = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('Delete'),
        matching: find.byWidgetPredicate((w) => w is OutlinedButton)));
    expect(delete.onPressed, isNull);
    expect(find.text('Route'), findsOneWidget);
  });
}
