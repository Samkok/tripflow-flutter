import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/widgets/place_selection_actions.dart';

import '../helpers/fakes.dart';

/// Records what the bulk actions ask the trip notifier to do.
class _Trips extends FakeTripNotifier {
  final removed = <String>[];
  final removedFromDay = <(Set<String>, DateTime)>[];
  final done = <Set<String>>[];
  final skipped = <Set<String>>[];

  @override
  Future<void> removeLocation(String id) async => removed.add(id);

  @override
  Future<void> removeLocationsFromDay(Set<String> ids, DateTime day) async =>
      removedFromDay.add((ids, day));

  @override
  Future<void> markLocationsAsDone(Set<String> ids) async => done.add(ids);

  @override
  Future<void> skipMultipleLocations(Set<String> ids) async => skipped.add(ids);
}

typedef _H = ({BuildContext context, WidgetRef ref, _Trips trips});

Future<_H> _pump(WidgetTester tester) async {
  final trips = _Trips();
  late BuildContext ctx;
  late WidgetRef r;
  await tester.pumpWidget(ProviderScope(
    overrides: [tripProvider.overrideWith((ref) => trips)],
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(builder: (context, ref, _) {
          ctx = context;
          r = ref;
          return const SizedBox();
        }),
      ),
    ),
  ));
  r.read(isSelectionModeProvider.notifier).state = true;
  r.read(selectedLocationsProvider.notifier).state = {'a', 'b'};
  return (context: ctx, ref: r, trips: trips);
}

void main() {
  testWidgets('delete without a day removes the rows and clears the selection',
      (tester) async {
    final h = await _pump(tester);
    final pending = deleteSelectedPlaces(h.context, h.ref);
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 Locations?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await pending;

    expect(h.trips.removed, unorderedEquals(['a', 'b']));
    expect(h.trips.removedFromDay, isEmpty);
    expect(h.ref.read(selectedLocationsProvider), isEmpty);
    expect(h.ref.read(isSelectionModeProvider), isFalse);
  });

  testWidgets('delete with a day only takes the rows off that day',
      (tester) async {
    final h = await _pump(tester);
    final day = DateTime(2026, 10, 6);
    final pending = deleteSelectedPlaces(h.context, h.ref, day: day);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await pending;

    expect(h.trips.removed, isEmpty);
    expect(h.trips.removedFromDay, hasLength(1));
    expect(h.trips.removedFromDay.single.$1, {'a', 'b'});
    expect(h.trips.removedFromDay.single.$2, day);
  });

  testWidgets('cancelling the delete keeps everything', (tester) async {
    final h = await _pump(tester);
    final pending = deleteSelectedPlaces(h.context, h.ref);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await pending;

    expect(h.trips.removed, isEmpty);
    expect(h.ref.read(selectedLocationsProvider), {'a', 'b'});
    expect(h.ref.read(isSelectionModeProvider), isTrue);
  });

  testWidgets('mark done and skip act on the set, then clear it',
      (tester) async {
    final h = await _pump(tester);
    markSelectedPlacesDone(h.ref);
    expect(h.trips.done, [
      {'a', 'b'}
    ]);
    expect(h.ref.read(isSelectionModeProvider), isFalse);

    h.ref.read(isSelectionModeProvider.notifier).state = true;
    h.ref.read(selectedLocationsProvider.notifier).state = {'c'};
    final pending = skipSelectedPlaces(h.context, h.ref);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    await pending;
    expect(h.trips.skipped, [
      {'c'}
    ]);
    expect(h.ref.read(selectedLocationsProvider), isEmpty);
  });
}
