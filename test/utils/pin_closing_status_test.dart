import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/saved_location.dart' show OpeningPeriod;
import 'package:voyza/services/timing_simulation.dart';
import 'package:voyza/utils/pin_closing_status.dart';

/// Wednesday 2026-10-14 (Google weekday 3).
final wed = DateTime(2026, 10, 14);
DateTime at(int h, [int m = 0]) => DateTime(2026, 10, 14, h, m);

LocationModel place({
  List<OpeningPeriod>? hours,
  int? closingOverride,
  bool accommodation = false,
}) =>
    LocationModel(
      id: 'p',
      name: 'Museum',
      address: '',
      coordinates: const LatLng(22.28, 114.17),
      addedAt: wed,
      scheduledDate: wed,
      googleOpeningHours: hours,
      userClosingMinuteOverride: closingOverride,
      isAccommodation: accommodation,
    );

/// Open Wednesday 10:00–18:00.
final dayHours = [
  const OpeningPeriod(
      openDay: 3, openMinutes: 600, closeDay: 3, closeMinutes: 1080),
];

/// Bar: Wednesday 18:00 – Thursday 02:00.
final lateHours = [
  const OpeningPeriod(
      openDay: 3, openMinutes: 1080, closeDay: 4, closeMinutes: 120),
];

/// DateFormat.jm() puts a narrow no-break space before AM/PM on recent ICU
/// data; compare on plain spaces.
String norm(String s) => s.replaceAll('\u202F', ' ').replaceAll('\u00A0', ' ');

void main() {
  group('now (today view, no arrival)', () {
    test('open with time to spare: nothing', () {
      final s = pinClosingStatus(
          loc: place(hours: dayHours), now: at(15), todayView: true);
      expect(s, PinClosingStatus.none);
    });

    test('closing within 30 min: yellow "Closes in N min"', () {
      final s = pinClosingStatus(
          loc: place(hours: dayHours), now: at(17, 35), todayView: true);
      expect(s.kind, PinClosingKind.closingSoon);
      expect(s.line, 'Closes in 25 min');
      expect(s.isRed, isFalse);
      expect(s.color, PinClosingStatus.closingYellow);
    });

    test('after closing: red "Already closed at … · Opens at …"', () {
      // Open Wed and Thu 10–18: closed tonight, opens tomorrow morning.
      final wedThu = [
        ...dayHours,
        const OpeningPeriod(
            openDay: 4, openMinutes: 600, closeDay: 4, closeMinutes: 1080),
      ];
      final s = pinClosingStatus(
          loc: place(hours: wedThu), now: at(19), todayView: true);
      expect(s.kind, PinClosingKind.closed);
      expect(s.line, startsWith('Already closed at '));
      expect(s.line, contains('6:00'));
      expect(norm(s.line), endsWith(' · Opens at 10:00 AM'));
      expect(s.isRed, isTrue);
      expect(s.color, PinClosingStatus.closedRed);
    });

    test('closed for days: "Opens <weekday> at …"', () {
      // Wednesday only: closed tonight until next Wednesday.
      final s = pinClosingStatus(
          loc: place(hours: dayHours), now: at(19), todayView: true);
      expect(norm(s.line), endsWith(' · Opens Wed at 10:00 AM'));
    });

    test('no period on this weekday: red "Closed today · Opens …"', () {
      final monOnly = [
        const OpeningPeriod(
            openDay: 1, openMinutes: 600, closeDay: 1, closeMinutes: 1080),
      ];
      final s = pinClosingStatus(
          loc: place(hours: monOnly), now: at(12), todayView: true);
      expect(s.kind, PinClosingKind.closed);
      expect(norm(s.line), 'Closed today · Opens Mon at 10:00 AM');
    });

    test('next opening looks a week ahead through the same hours', () {
      expect(nextOpeningAfter(place(hours: dayHours), at(19)),
          DateTime(2026, 10, 21, 10));
      expect(nextOpeningAfter(place(), at(19)), isNull);
      // A closing override does not hide tomorrow's opening.
      expect(
          nextOpeningAfter(
              place(hours: dayHours, closingOverride: 960), at(19)),
          DateTime(2026, 10, 21, 10));
    });

    test('before the first opening: yellow "Opens at …"', () {
      final s = pinClosingStatus(
          loc: place(hours: dayHours), now: at(8), todayView: true);
      expect(s.kind, PinClosingKind.notOpenYet);
      expect(norm(s.line), 'Opens at 10:00 AM');
      expect(s.isRed, isFalse);
      expect(s.color, PinClosingStatus.closingYellow);
    });

    test('a midday break: yellow with the afternoon opening', () {
      final split = [
        const OpeningPeriod(
            openDay: 3, openMinutes: 600, closeDay: 3, closeMinutes: 780),
        const OpeningPeriod(
            openDay: 3, openMinutes: 840, closeDay: 3, closeMinutes: 1080),
      ];
      final s = pinClosingStatus(
          loc: place(hours: split), now: at(13, 30), todayView: true);
      expect(s.kind, PinClosingKind.notOpenYet);
      expect(norm(s.line), 'Opens at 2:00 PM');
    });

    test('24/7, unknown hours and accommodations: nothing', () {
      expect(
          pinClosingStatus(
              loc: place(
                  hours: const [OpeningPeriod(openDay: 0, openMinutes: 0)]),
              now: at(23, 50),
              todayView: true),
          PinClosingStatus.none);
      expect(pinClosingStatus(loc: place(), now: at(23), todayView: true),
          PinClosingStatus.none);
      expect(
          pinClosingStatus(
              loc: place(hours: dayHours, accommodation: true),
              now: at(23),
              todayView: true),
          PinClosingStatus.none);
    });

    test('not today\'s view: the clock does not apply', () {
      final s = pinClosingStatus(
          loc: place(hours: dayHours), now: at(19), todayView: false);
      expect(s, PinClosingStatus.none);
    });

    test('an after-midnight close counts past midnight', () {
      final s = pinClosingStatus(
          loc: place(hours: lateHours),
          now: DateTime(2026, 10, 15, 1, 45),
          todayView: true);
      expect(s.kind, PinClosingKind.closingSoon);
      expect(s.line, 'Closes in 15 min');
    });

    test('the user\'s closing override is the closing time', () {
      final s = pinClosingStatus(
          loc: place(hours: dayHours, closingOverride: 16 * 60),
          now: at(15, 50),
          todayView: true);
      expect(s.line, 'Closes in 10 min');
    });
  });

  group('arrival known', () {
    test('arriving after closing: red "Closed on arrival"', () {
      final s = pinClosingStatus(
          loc: place(hours: dayHours),
          now: at(15),
          arrival: at(18, 30),
          todayView: true);
      expect(
          s,
          const PinClosingStatus(
              PinClosingKind.closedOnArrival, 'Closed on arrival'));
    });

    test('arriving within 30 min of closing: yellow, minutes after arrival',
        () {
      final s = pinClosingStatus(
          loc: place(hours: dayHours),
          now: at(15),
          arrival: at(17, 35),
          todayView: true);
      expect(s.kind, PinClosingKind.closingSoonAfterArrival);
      expect(s.line, 'Closes 25 min after arrival');
      expect(s.isRed, isFalse);
    });

    test('arriving with time to spare: nothing, even if closing soon now', () {
      final s = pinClosingStatus(
          loc: place(hours: dayHours),
          now: at(17, 50),
          arrival: at(17, 55),
          todayView: true);
      // 5 minutes left on arrival → still a warning.
      expect(s.line, 'Closes 5 min after arrival');
      final early = pinClosingStatus(
          loc: place(hours: dayHours),
          now: at(9),
          arrival: at(10, 30),
          todayView: true);
      expect(early, PinClosingStatus.none);
    });

    test('a future day is judged by its planned arrival', () {
      final s = pinClosingStatus(
          loc: place(hours: dayHours),
          now: DateTime(2026, 10, 13, 20),
          arrival: at(18, 10),
          todayView: false);
      expect(s.kind, PinClosingKind.closedOnArrival);
    });

    test('a planned arrival already behind the clock falls back to now', () {
      final s = pinClosingStatus(
          loc: place(hours: dayHours),
          now: at(17, 40),
          arrival: at(16),
          todayView: true);
      expect(s.line, 'Closes in 20 min');
    });

    test('arriving before the doors open: yellow, with the opening time', () {
      final s = pinClosingStatus(
          loc: place(hours: dayHours),
          now: at(8),
          arrival: at(9),
          todayView: true);
      expect(s.kind, PinClosingKind.notOpenYet);
      expect(norm(s.line), 'Not open on arrival · Opens at 10:00 AM');
      expect(s.isRed, isFalse);
    });
  });

  test('the planner and the pins read the same hours', () {
    final iv = effectiveHoursIntervalsOn(place(hours: dayHours), at(12))!;
    expect(iv.single.open, at(10));
    expect(iv.single.close, at(18));
    expect(iv.single.covers(at(17, 59)), isTrue);
    expect(iv.single.covers(at(18)), isFalse);
  });
}
