import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/utils/trip_times.dart';
import 'package:voyza/widgets/trip_times_lines.dart';

Trip _trip({int? arrival, int? departure, DateTime? end}) => Trip(
      id: 't',
      userId: 'u',
      name: 'Taipei',
      startDate: DateTime(2026, 10, 12),
      endDate: end ?? DateTime(2026, 10, 16),
      arrivalMinute: arrival,
      departureMinute: departure,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

Future<void> _show(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(home: Scaffold(body: SizedBox(width: 360, child: child))));

const _arrivalLine = Key('day-arrival-time');
const _departureLine = Key('day-departure-time');

void main() {
  group('header row', () {
    testWidgets('owner, nothing set: an invitation to add the times',
        (tester) async {
      var taps = 0;
      await _show(
          tester,
          TripTimesHeaderRow(
              trip: _trip(), canEdit: true, onEdit: () => taps++));
      expect(find.text('Arrival and departure times'), findsOneWidget);
      await tester.tap(find.text('Add'));
      expect(taps, 1);
    });

    testWidgets('times set: says them, and the owner can edit', (tester) async {
      var taps = 0;
      await _show(
          tester,
          TripTimesHeaderRow(
              trip: _trip(arrival: 900, departure: 840),
              canEdit: true,
              onEdit: () => taps++));
      expect(find.text('Arrive 3:00 PM · Leave 2:00 PM'), findsOneWidget);
      await tester.tap(find.text('Edit'));
      expect(taps, 1);
    });

    testWidgets('someone else on the trip sees the times, no button',
        (tester) async {
      await _show(
          tester,
          TripTimesHeaderRow(
              trip: _trip(arrival: 900), canEdit: false, onEdit: () {}));
      expect(find.text('Arrive 3:00 PM'), findsOneWidget);
      expect(find.byKey(const Key('trip-times-edit')), findsNothing);
    });

    testWidgets('someone else, nothing set: no line at all', (tester) async {
      await _show(tester,
          TripTimesHeaderRow(trip: _trip(), canEdit: false, onEdit: () {}));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('lines under the first and last day', () {
    final first = DateTime(2026, 10, 12);
    final middle = DateTime(2026, 10, 14);
    final last = DateTime(2026, 10, 16);

    test('only the first and the last day carry one', () {
      final trip = _trip();
      expect(TripDayTimeLines.appliesTo(trip, first), isTrue);
      expect(TripDayTimeLines.appliesTo(trip, last), isTrue);
      expect(TripDayTimeLines.appliesTo(trip, middle), isFalse);
      // The time of day on the date does not matter.
      expect(
          TripDayTimeLines.appliesTo(trip, DateTime(2026, 10, 16, 18)), isTrue);
    });

    testWidgets('first day, owner, not set: "Add arrival time"',
        (tester) async {
      final taps = <TripTimeField>[];
      await _show(
          tester,
          TripDayTimeLines(
              trip: _trip(), day: first, canEdit: true, onEdit: taps.add));
      expect(find.text('Add arrival time'), findsOneWidget);
      expect(find.text('Add departure time'), findsNothing);
      await tester.tap(find.byKey(_arrivalLine));
      expect(taps, [TripTimeField.arrival]);
      // Comfortable to hit with a thumb.
      expect(tester.getSize(find.byKey(_arrivalLine)).height,
          greaterThanOrEqualTo(40));
    });

    testWidgets('last day, owner, not set: "Add departure time"',
        (tester) async {
      await _show(
          tester,
          TripDayTimeLines(
              trip: _trip(), day: last, canEdit: true, onEdit: (_) {}));
      expect(find.text('Add departure time'), findsOneWidget);
      expect(find.text('Add arrival time'), findsNothing);
    });

    testWidgets('once set, the line states the time and opens the editor',
        (tester) async {
      final taps = <TripTimeField>[];
      await _show(
          tester,
          TripDayTimeLines(
              trip: _trip(arrival: 900, departure: 840),
              day: last,
              canEdit: true,
              onEdit: taps.add));
      expect(find.text('Leave 2:00 PM'), findsOneWidget);
      expect(find.text('Arrive 3:00 PM'), findsNothing,
          reason: 'that is the first day');
      await tester.tap(find.byKey(_departureLine));
      expect(taps, [TripTimeField.departure]);
    });

    testWidgets('a day in the middle shows nothing', (tester) async {
      await _show(
          tester,
          TripDayTimeLines(
              trip: _trip(arrival: 900, departure: 840),
              day: middle,
              canEdit: true,
              onEdit: (_) {}));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('a one-day trip shows both on its only day', (tester) async {
      await _show(
          tester,
          TripDayTimeLines(
              trip: _trip(arrival: 600, end: first),
              day: first,
              canEdit: true,
              onEdit: (_) {}));
      expect(find.text('Arrive 10:00 AM'), findsOneWidget);
      expect(find.text('Add departure time'), findsOneWidget);
    });

    testWidgets('someone else on the trip: set times only, not tappable',
        (tester) async {
      final taps = <TripTimeField>[];
      await _show(
          tester,
          TripDayTimeLines(
              trip: _trip(arrival: 900, end: first),
              day: first,
              canEdit: false,
              onEdit: taps.add));
      expect(find.text('Arrive 3:00 PM'), findsOneWidget);
      expect(find.text('Add departure time'), findsNothing);
      await tester.tap(find.byKey(_arrivalLine), warnIfMissed: false);
      expect(taps, isEmpty);
    });
  });
}
