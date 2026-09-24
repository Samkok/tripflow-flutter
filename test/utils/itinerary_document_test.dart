import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/utils/itinerary_document.dart';
import 'package:voyza/utils/place_tags.dart';
import 'package:voyza/utils/trip_dates.dart';

SavedLocation _loc(
  String name, {
  DateTime? day,
  DateTime? end,
  String? tag,
  int staySec = 0,
  bool done = false,
  bool skipped = false,
  bool accommodation = false,
  List<OpeningPeriod>? hours,
  int order = 0,
  String? placeId,
}) =>
    SavedLocation(
      id: name,
      userId: 'u',
      name: name,
      lat: 1.5,
      lng: 2.5,
      createdAt: DateTime(2026, 9, 1).add(Duration(minutes: order)),
      fingerprint: name,
      scheduledDate: day,
      scheduledEndDate: end,
      tripId: 't',
      tag: tag,
      stayDuration: staySec,
      isDone: done,
      isSkipped: skipped,
      isAccommodation: accommodation,
      googleOpeningHours: hours,
      placeId: placeId,
    );

void main() {
  final start = DateTime(2026, 10, 5); // Monday
  DateTime d(int n) => shiftTripDay(start, n);

  Trip trip({bool undated = false, DateTime? s, DateTime? e}) => Trip(
        id: 't',
        userId: 'u',
        name: 'Hong Kong',
        countryCode: 'HK',
        startDate: undated ? tripDatesTbdAnchor : (s ?? start),
        endDate: undated ? shiftTripDay(tripDatesTbdAnchor, 2) : (e ?? d(2)),
        datesTbd: undated,
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime(2026, 9, 1),
      );

  test('every day of the trip gets a section, empty ones included', () {
    final doc = buildItineraryDocument(
      trip: trip(),
      locations: [_loc('A', day: d(0)), _loc('B', day: d(2))],
    );
    expect(doc.days.map((x) => x.title), ['Day 1', 'Day 2', 'Day 3']);
    expect(doc.days[1].stops, isEmpty);
    expect(doc.days[0].subtitle, 'Mon, Oct 5, 2026');
    expect(doc.dateLine, 'Oct 5 – Oct 7, 2026');
    expect(doc.dayCount, 3);
    expect(doc.placeCount, 2);
    expect(doc.countryName, 'Hong Kong');
  });

  test('within a day: to-do first, then done, then skipped, by when added', () {
    final doc = buildItineraryDocument(trip: trip(), locations: [
      _loc('skipped', day: d(0), skipped: true, order: 0),
      _loc('done', day: d(0), done: true, order: 1),
      _loc('second', day: d(0), order: 3),
      _loc('first', day: d(0), order: 2),
    ]);
    expect(doc.days.first.stops.map((s) => s.name),
        ['first', 'second', 'done', 'skipped']);
  });

  test('accommodation is where you stay on every day it covers, not a stop',
      () {
    final doc = buildItineraryDocument(trip: trip(), locations: [
      _loc('Hotel', day: d(0), end: d(2), accommodation: true),
      _loc('Museum', day: d(1)),
    ]);
    for (final day in doc.days) {
      expect(day.stays.single.name, 'Hotel');
      expect(day.stays.single.spanLabel, 'Oct 5 – Oct 7');
    }
    expect(doc.days[1].stops.single.name, 'Museum');
    expect(doc.stayCount, 1);
  });

  test('places with no day are listed separately', () {
    final doc = buildItineraryDocument(
        trip: trip(), locations: [_loc('Later'), _loc('A', day: d(0))]);
    expect(doc.unscheduled.single.name, 'Later');
    expect(doc.days.expand((x) => x.stops).map((s) => s.name), ['A']);
  });

  test('a trip without dates prints day numbers and no weekday', () {
    final a = tripDatesTbdAnchor;
    final doc = buildItineraryDocument(trip: trip(undated: true), locations: [
      _loc('Hotel', day: a, end: shiftTripDay(a, 2), accommodation: true),
      _loc('A', day: shiftTripDay(a, 1)),
    ]);
    expect(doc.dateLine, 'No dates yet');
    expect(doc.days.map((x) => x.subtitle), everyElement(isNull));
    expect(doc.days.first.stays.single.spanLabel, 'Day 1 – Day 3');
  });

  test('a Transport stop is labelled by its mode; the key still says Transport',
      () {
    final doc = buildItineraryDocument(
      trip: trip(),
      locations: [
        _loc('HKG', day: d(0), tag: 'transport')
            .copyWith(placeTypes: ['airport', 'point_of_interest']),
        _loc('Star Ferry', day: d(0), tag: 'transport', order: 1)
            .copyWith(placeTypes: ['ferry_terminal']),
        _loc('Some stop', day: d(0), tag: 'transport', order: 2),
        _loc('Museum', day: d(0), tag: 'culture', order: 3)
            .copyWith(placeTypes: ['museum', 'train_station']),
      ],
    );
    final stops = doc.days.first.stops;
    expect([for (final s in stops) s.tagLabel],
        ['Airport', 'Ferry', 'Transport', 'Culture']);
    expect(doc.usedTags, [PlaceTag.culture, PlaceTag.transport]);
  });

  test('tags used anywhere make up the colour key, in the fixed order', () {
    final doc = buildItineraryDocument(trip: trip(), locations: [
      _loc('A', day: d(0), tag: 'stay'),
      _loc('B', day: d(0), tag: 'food'),
      _loc('C', tag: 'food'),
      _loc('D', day: d(1), tag: 'not-a-tag'),
    ]);
    expect(doc.usedTags, [PlaceTag.food, PlaceTag.stay]);
    expect(
        doc.days.first.stops.map((s) => s.tag), [PlaceTag.stay, PlaceTag.food]);
  });

  group('opening hours', () {
    const monOnly = [
      OpeningPeriod(
          openDay: 1, openMinutes: 540, closeDay: 1, closeMinutes: 1080),
    ];
    test('the planned weekday decides the line', () {
      expect(openingHoursLine(monOnly, day: d(0)),
          (text: '09:00 – 18:00', caution: false));
      expect(openingHoursLine(monOnly, day: d(1)),
          (text: 'May be closed this day', caution: true));
      expect(openingHoursLine(null, day: d(0)), isNull);
      expect(
          openingHoursLine(const [OpeningPeriod(openDay: 0, openMinutes: 0)],
              day: d(0)),
          (text: 'Open 24 hours', caution: false));
    });

    test('without dates, hours show only when every day shares them', () {
      expect(openingHoursLine(monOnly, day: null), isNull);
      final daily = [
        for (var i = 0; i < 7; i++)
          OpeningPeriod(
              openDay: i, openMinutes: 600, closeDay: i, closeMinutes: 1320),
      ];
      expect(openingHoursLine(daily, day: null),
          (text: '10:00 – 22:00', caution: false));
    });
  });

  test('stay minutes and the maps link', () {
    expect(formatStayMinutes(0), '');
    expect(formatStayMinutes(45), '45m');
    expect(formatStayMinutes(120), '2h');
    expect(formatStayMinutes(150), '2h 30m');
    final withId = googleMapsUrlFor(_loc('A', placeId: 'ChIJabc'));
    expect(withId, contains('query=1.5%2C2.5'));
    expect(withId, contains('query_place_id=ChIJabc'));
    expect(googleMapsUrlFor(_loc('B')), isNot(contains('query_place_id')));
  });
}
