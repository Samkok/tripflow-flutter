import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/utils/trip_day_labels.dart';
import 'package:voyza/widgets/optimized_location_card.dart';

import '../helpers/fakes.dart';
import '../helpers/pump.dart';

final _today = DateTime.now();
final _past = DateTime(2020, 1, 1);
final _trip = sampleTrip(id: 't1', start: DateTime(2020, 1, 1), days: 3000);

LocationModel _loc({bool done = false}) => LocationModel(
      id: 'l1',
      name: 'Din Tai Fung',
      address: 'Xinyi',
      coordinates: const LatLng(25.033, 121.53),
      addedAt: _past,
      scheduledDate: _past,
      tripId: 't1',
      isDone: done,
    );

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  bool canWrite = true,
  DateTime? day,
  DateTime? mapDay,
}) async {
  await useMockPrefs();
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  final container = await pumpVoyza(
    tester,
    SingleChildScrollView(
      child: OptimizedLocationCard(
        location: _loc(),
        number: 1,
        scrollController: scroll,
        sheetController: null,
        onLocationTap: null,
        tripId: 't1',
        day: day,
        labeler: DayLabeler.forTrip(_trip),
      ),
    ),
    overrides: [
      tripProvider.overrideWith(
          (ref) => FakeTripNotifier(TripState(pinnedLocations: [_loc()]))),
      hasWriteAccessProvider.overrideWith((ref, id) async => canWrite),
      localActiveTripIdProvider
          .overrideWith((ref) => FakeLocalActiveTripNotifier('t1')),
    ],
  );
  if (mapDay != null) {
    container.read(selectedDateProvider.notifier).state = mapDay;
  }
  await container.read(hasWriteAccessProvider('t1').future);
  await tester.pumpAndSettle();
  return container;
}

bool _itemEnabled(WidgetTester tester, String label) => tester
    .widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, label))
    .enabled;

void main() {
  testWidgets('the row is Done · Options · Map; the menu holds the six',
      (tester) async {
    await _pump(tester, day: _today);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Options'), findsOneWidget);
    expect(find.byIcon(Icons.map_rounded), findsOneWidget);

    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    for (final label in [
      'Skip',
      'Move to another day',
      'Move to another trip',
      'Copy to another day',
      'Remove from trip',
      'Delete',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Mark as Done'), findsNothing,
        reason: 'Done is the button, not a menu item');
  });

  testWidgets('without write access Done and Delete are off', (tester) async {
    await _pump(tester, canWrite: false, day: _today);
    // FilledButton.icon builds a private subclass, so match by predicate.
    final done = tester.widget<FilledButton>(find.ancestor(
        of: find.text('Done'),
        matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(done.onPressed, isNull);

    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    expect(_itemEnabled(tester, 'Delete'), isFalse);
    expect(_itemEnabled(tester, 'Skip'), isFalse);
  });

  testWidgets("the row's own day gates editing, not the map's day",
      (tester) async {
    // The map sits on a long-gone day; this row is today's.
    await _pump(tester, day: _today, mapDay: _past);
    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    expect(_itemEnabled(tester, 'Skip'), isTrue);
    expect(_itemEnabled(tester, 'Move to another day'), isTrue);
  });

  testWidgets('a past day of the trip is read-only', (tester) async {
    await _pump(tester, day: _past);
    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    expect(_itemEnabled(tester, 'Skip'), isFalse);
    expect(_itemEnabled(tester, 'Copy to another day'), isTrue,
        reason: 'copying out of a past day is always allowed');
  });
}
