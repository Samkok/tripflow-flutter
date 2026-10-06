import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:voyza/providers/subscription_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/repositories/trip_repository.dart';
import 'package:voyza/screens/copy_trip_wizard.dart';
import 'package:voyza/services/analytics_service.dart';
import 'package:voyza/utils/trip_dates.dart';

typedef _Copy = ({String code, DateTime start});

/// Stands in for the server: answers the preview, records what the wizard
/// asked to be copied and which copies it asked to be left undated.
class FakeTrips extends Fake implements TripRepository {
  final copies = <_Copy>[];
  final undated = <String>[];
  bool failCopying = false;
  bool failMarkingUndated = false;

  @override
  Future<Map<String, dynamic>?> getPublicTripPreview(String code) async => {
        'name': 'Tokyo in five days',
        'description': null,
        'start_date': '2026-10-05T00:00:00+00:00',
        'end_date': '2026-10-09T00:00:00+00:00',
        'country_code': 'JP',
        'locations': [
          {
            'name': 'Senso-ji',
            'scheduled_date': '2026-10-05T00:00:00+00:00',
            'stay_duration': 3600,
          },
          {
            'name': 'Tsukiji Outer Market',
            'scheduled_date': '2026-10-06T00:00:00+00:00',
            'stay_duration': 5400,
          },
        ],
      };

  @override
  Future<String> duplicatePublicTrip(String code, DateTime startDate) async {
    if (failCopying) throw StateError('offline');
    copies.add((code: code, start: startDate));
    return 'new-trip';
  }

  @override
  Future<void> clearTripDatesRemote(String tripId) async {
    if (failMarkingUndated) throw StateError('offline');
    undated.add(tripId);
  }
}

const _noDates = "I don't know the dates yet";

Future<FakeTrips> openDateStep(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final trips = FakeTrips();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      tripRepositoryProvider.overrideWithValue(trips),
      isProProvider.overrideWithValue(true),
      tripCopiesUsedProvider.overrideWith((ref) async => 0),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const CopyTripWizard(initialCode: 'AB12CD'),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text('Tokyo in five days'), findsOneWidget);
  await tester.tap(find.text('Next — pick your dates'));
  await tester.pumpAndSettle();
  expect(find.text('When does YOUR trip start?'), findsOneWidget);
  return trips;
}

bool copyEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Copy this trip'))
        .onPressed !=
    null;

/// Lets the success toast run out, so no timer outlives the test.
Future<void> finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  // What the app reported to analytics during a test.
  final fired = <({String name, Map<String, Object>? params})>[];
  setUp(() {
    fired.clear();
    AnalyticsService.debugOnFire =
        (name, params) => fired.add((name: name, params: params));
  });
  tearDown(() => AnalyticsService.debugOnFire = null);

  testWidgets('a copied trip is reported as a created trip, once',
      (tester) async {
    await openDateStep(tester);
    await tester.tap(find.text(_noDates));
    await tester.pumpAndSettle();
    expect(fired, isEmpty, reason: 'nothing is copied yet');

    await tester.tap(find.text('Copy this trip'));
    await tester.pumpAndSettle();
    expect(fired, hasLength(1));
    expect(fired.single.name, 'trip_created');
    // Marked as a copy, so analytics can tell it from a trip made by hand.
    expect(fired.single.params, {'source': 'copy'});
    await finish(tester);
  });

  testWidgets('a copy that fails is not reported', (tester) async {
    final trips = await openDateStep(tester);
    trips.failCopying = true;
    await tester.tap(find.text(_noDates));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy this trip'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not copy the trip'), findsOneWidget);
    expect(fired, isEmpty);
    await finish(tester);
  });

  testWidgets('a copy is reported even when marking it undated fails',
      (tester) async {
    final trips = await openDateStep(tester);
    trips.failMarkingUndated = true;
    await tester.tap(find.text(_noDates));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy this trip'));
    await tester.pumpAndSettle();
    expect(fired.map((e) => e.name), ['trip_created']);
    await finish(tester);
  });

  testWidgets('nothing can be copied until a choice is made', (tester) async {
    final trips = await openDateStep(tester);
    expect(find.text('Choose a start date'), findsOneWidget);
    expect(find.text(_noDates), findsOneWidget);
    expect(copyEnabled(tester), isFalse);
    expect(trips.copies, isEmpty);
  });

  testWidgets('"no dates yet" copies the trip onto numbered days',
      (tester) async {
    final trips = await openDateStep(tester);
    await tester.tap(find.text(_noDates));
    await tester.pumpAndSettle();

    // The plan's own length, since there is no calendar to read it from.
    expect(find.text('No dates yet · 5 days'), findsOneWidget);
    expect(find.text('Choose a start date'), findsNothing);
    expect(find.textContaining('Day 1, Day 2'), findsOneWidget);
    expect(copyEnabled(tester), isTrue);

    await tester.tap(find.text('Copy this trip'));
    await tester.pumpAndSettle();

    expect(trips.copies, [(code: 'AB12CD', start: tripDatesTbdAnchor)]);
    expect(trips.copies.single.start, DateTime(2100, 1, 1));
    expect(trips.undated, ['new-trip']);
    // Back where the wizard was opened from, with the news.
    expect(find.text('open'), findsOneWidget);
    expect(find.text('When does YOUR trip start?'), findsNothing);
    expect(find.text('Trip copied — set its dates whenever you know them'),
        findsOneWidget);
    await finish(tester);
  });

  testWidgets('a copy still succeeds when marking it undated fails',
      (tester) async {
    final trips = await openDateStep(tester);
    trips.failMarkingUndated = true;
    await tester.tap(find.text(_noDates));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy this trip'));
    await tester.pumpAndSettle();

    // On the anchor the app reads it as undated either way.
    expect(trips.copies.single.start, tripDatesTbdAnchor);
    expect(trips.undated, isEmpty);
    expect(find.text('open'), findsOneWidget);
    expect(find.textContaining('Trip copied'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('a picked date copies onto that date and stays dated',
      (tester) async {
    final trips = await openDateStep(tester);
    await tester.tap(find.text('Choose a start date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    expect(
      find.textContaining(DateFormat('EEE, MMM d, yyyy').format(today)),
      findsOneWidget,
    );
    expect(copyEnabled(tester), isTrue);

    await tester.tap(find.text('Copy this trip'));
    await tester.pumpAndSettle();
    expect(trips.copies, [(code: 'AB12CD', start: today)]);
    expect(trips.undated, isEmpty);
    expect(find.text("Trip copied — it's yours now!"), findsOneWidget);
    await finish(tester);
  });

  testWidgets('switching back brings the picked date up again', (tester) async {
    final trips = await openDateStep(tester);
    await tester.tap(find.text('Choose a start date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dated = DateFormat('EEE, MMM d, yyyy').format(today);

    await tester.tap(find.text(_noDates));
    await tester.pumpAndSettle();
    expect(find.text('No dates yet · 5 days'), findsOneWidget);
    expect(find.textContaining(dated), findsNothing);

    await tester.tap(find.text(_noDates));
    await tester.pumpAndSettle();
    expect(find.textContaining(dated), findsOneWidget);
    expect(copyEnabled(tester), isTrue);

    await tester.tap(find.text('Copy this trip'));
    await tester.pumpAndSettle();
    expect(trips.copies.single.start, today);
    expect(trips.undated, isEmpty);
    await finish(tester);
  });

  testWidgets('switching off with no date picked leaves nothing to copy',
      (tester) async {
    await openDateStep(tester);
    await tester.tap(find.text(_noDates));
    await tester.pumpAndSettle();
    expect(copyEnabled(tester), isTrue);
    await tester.tap(find.text(_noDates));
    await tester.pumpAndSettle();
    expect(find.text('Choose a start date'), findsOneWidget);
    expect(copyEnabled(tester), isFalse);
  });

  testWidgets('picking a date after "no dates yet" is choosing a date',
      (tester) async {
    final trips = await openDateStep(tester);
    await tester.tap(find.text(_noDates));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No dates yet · 5 days'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('No dates yet · 5 days'), findsNothing);
    expect(
      tester.widget<Switch>(find.byType(Switch)).value,
      isFalse,
    );
    await tester.tap(find.text('Copy this trip'));
    await tester.pumpAndSettle();
    expect(trips.copies.single.start, isNot(tripDatesTbdAnchor));
    expect(trips.undated, isEmpty);
    await finish(tester);
  });
}
