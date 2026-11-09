import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/onboarding_checklist_provider.dart';
import 'package:voyza/providers/onboarding_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/utils/open_trip_on_map.dart';
import 'package:voyza/widgets/switch_trip_sheet.dart';

import '../helpers/fakes.dart';

class _Checklist extends StateNotifier<ChecklistState>
    implements ChecklistNotifier {
  _Checklist() : super(const ChecklistState());
  @override
  Future<void> mark(ChecklistStep step, {bool silent = false}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Trips extends FakeTripNotifier {
  @override
  void clearTrip() => state = TripState();
}

Future<({FakeLocalActiveTripNotifier mapTrip, ProviderContainer container})>
    _open(WidgetTester tester,
        {required List<Trip> trips, String? onMap}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final mapTrip = FakeLocalActiveTripNotifier(onMap);
  final container = ProviderContainer(overrides: [
    userTripsProvider.overrideWith((ref) async => trips),
    sharedTripsProvider.overrideWith((ref) async => <Map<String, dynamic>>[]),
    localActiveTripIdProvider.overrideWith((ref) => mapTrip),
    tripProvider.overrideWith((ref) => _Trips()),
    checklistProvider.overrideWith((ref) => _Checklist()),
    savedLocationsProvider.overrideWith((ref) => Stream.value(const [])),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showSwitchTripSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (mapTrip: mapTrip, container: container);
}

void main() {
  testWidgets('lists the trips, marks the one on the map, and switches',
      (tester) async {
    final a = sampleTrip(id: 'a', name: 'Taipei');
    final b = sampleTrip(id: 'b', name: 'Tokyo', start: DateTime(2026, 11, 2));
    final h = await _open(tester, trips: [a, b], onMap: 'a');

    expect(find.text('Taipei'), findsOneWidget);
    expect(find.text('Tokyo'), findsOneWidget);
    expect(find.text('On the map'), findsOneWidget);

    await tester.tap(find.text('Tokyo'));
    await tester.pumpAndSettle();

    expect(h.mapTrip.state, 'b');
    expect(h.container.read(mainTabRequestProvider), mapTabIndex);
    expect(find.text('Show on the map'), findsNothing,
        reason: 'the sheet closes after the switch');
  });

  testWidgets('with no trips it sends the user to the Trips tab',
      (tester) async {
    final h = await _open(tester, trips: const []);
    expect(find.textContaining('Create a trip first'), findsOneWidget);

    await tester.tap(find.text('Create a trip'));
    await tester.pumpAndSettle();

    expect(h.container.read(mainTabRequestProvider), 0);
    expect(h.mapTrip.state, isNull);
  });
}
