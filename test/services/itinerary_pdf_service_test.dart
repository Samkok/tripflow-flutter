import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/services/itinerary_pdf_service.dart';
import 'package:voyza/utils/itinerary_document.dart';
import 'package:voyza/utils/store_links.dart';
import 'package:voyza/utils/trip_dates.dart';

ByteData _font(String name) =>
    ByteData.sublistView(File('assets/fonts/$name').readAsBytesSync());

ItineraryFonts _fonts() => ItineraryFonts(
      regular: _font('Roboto-Regular.ttf'),
      medium: _font('Roboto-Medium.ttf'),
      bold: _font('Roboto-Bold.ttf'),
    );

SavedLocation _loc(
  String name, {
  DateTime? day,
  DateTime? end,
  String? tag,
  int stayMin = 0,
  bool done = false,
  bool skipped = false,
  bool accommodation = false,
  List<OpeningPeriod>? hours,
  int order = 0,
}) =>
    SavedLocation(
      id: name,
      userId: 'u',
      name: name,
      lat: 22.3,
      lng: 114.17,
      createdAt: DateTime(2026, 9, 1).add(Duration(minutes: order)),
      fingerprint: name,
      scheduledDate: day,
      scheduledEndDate: end,
      tripId: 't',
      tag: tag,
      stayDuration: stayMin * 60,
      isDone: done,
      isSkipped: skipped,
      isAccommodation: accommodation,
      googleOpeningHours: hours,
      placeId: 'ChIJ$name',
    );

const _daily = [
  OpeningPeriod(openDay: 0, openMinutes: 600, closeDay: 0, closeMinutes: 1320),
  OpeningPeriod(openDay: 1, openMinutes: 600, closeDay: 1, closeMinutes: 1320),
  OpeningPeriod(openDay: 2, openMinutes: 600, closeDay: 2, closeMinutes: 1320),
  OpeningPeriod(openDay: 3, openMinutes: 600, closeDay: 3, closeMinutes: 1320),
  OpeningPeriod(openDay: 4, openMinutes: 600, closeDay: 4, closeMinutes: 1320),
  OpeningPeriod(openDay: 5, openMinutes: 600, closeDay: 5, closeMinutes: 1320),
  OpeningPeriod(openDay: 6, openMinutes: 600, closeDay: 6, closeMinutes: 1320),
];

void main() {
  final start = DateTime(2026, 10, 5); // a Monday
  DateTime d(int n) => shiftTripDay(start, n);

  Trip trip({bool undated = false}) => Trip(
        id: 't',
        userId: 'u',
        name: 'Hong Kong with Mum & Dad',
        countryCode: 'HK',
        startDate: undated ? tripDatesTbdAnchor : start,
        endDate: undated ? shiftTripDay(tripDatesTbdAnchor, 3) : d(3),
        datesTbd: undated,
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime(2026, 9, 1),
      );

  List<SavedLocation> places(DateTime Function(int) day) => [
        _loc('The Peninsula Hong Kong',
            day: day(0), end: day(3), accommodation: true, tag: 'stay'),
        _loc('Tim Ho Wan, Sham Shui Po',
            day: day(0), tag: 'food', stayMin: 60, hours: _daily, order: 1),
        _loc('Victoria Peak',
            day: day(0), tag: 'sights', stayMin: 120, done: true, order: 2),
        _loc('Temple Street Night Market',
            day: day(0), tag: 'shopping', stayMin: 90, order: 3),
        _loc('Chợ Bến Thành (accent check)',
            day: day(1), tag: 'shopping', skipped: true, order: 4),
        _loc('Hong Kong Museum of Art',
            day: day(1),
            tag: 'culture',
            stayMin: 150,
            order: 5,
            hours: const [
              OpeningPeriod(
                  openDay: 3,
                  openMinutes: 600,
                  closeDay: 3,
                  closeMinutes: 1080),
            ]),
        _loc('Star Ferry Pier', day: day(1), tag: 'transport', order: 6),
        _loc('Dragon\'s Back Trail',
            day: day(3), tag: 'nature', stayMin: 240, order: 7),
        _loc('Lan Kwai Fong', day: day(3), tag: 'nightlife', order: 8),
        _loc('Ngong Ping 360', tag: 'sights', order: 9),
      ];

  test('Roboto draws Vietnamese; CJK, Thai and emoji need the raster path', () {
    final font = TtfParser(_font('Roboto-Bold.ttf'));
    expect(
        ItineraryPdfService.needsRaster('Chợ Bến Thành · 09:00 – 18:00', font),
        isFalse);
    expect(ItineraryPdfService.needsRaster('Café de Flore', font), isFalse);
    expect(ItineraryPdfService.needsRaster('九份老街', font), isTrue);
    expect(ItineraryPdfService.needsRaster('วัดพระแก้ว', font), isTrue);
    expect(ItineraryPdfService.needsRaster('Ramen 🍜', font), isTrue);
  });

  test('only the strings the font cannot draw are rasterised', () {
    final font = TtfParser(_font('Roboto-Bold.ttf'));
    final doc = buildItineraryDocument(
      trip: trip(),
      locations: [
        ...places(d),
        _loc('添好運 Tim Ho Wan', day: d(2), tag: 'food', order: 10),
      ],
    );
    final needs = ItineraryPdfService.rasterNeeds(doc, font);
    expect(needs, {(RasterRole.stopName, '添好運 Tim Ho Wan')});
  });

  test('builds a multi-day PDF (dated and undated)', () async {
    for (final undated in [false, true]) {
      final t = trip(undated: undated);
      DateTime day(int n) =>
          shiftTripDay(undated ? tripDatesTbdAnchor : start, n);
      final doc = buildItineraryDocument(
        trip: t,
        locations: places(day),
        now: DateTime(2026, 9, 21),
      );
      final bytes = await ItineraryPdfService.buildPdf(doc, fonts: _fonts());
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(20000));
      // Kept for a visual check of the template (not asserted on).
      final out = Platform.environment['ITINERARY_PDF_OUT'];
      if (out != null) {
        File('$out/itinerary_${undated ? 'undated' : 'dated'}.pdf')
            .writeAsBytesSync(bytes);
      }
    }
  });

  test('a long trip paginates', () async {
    final many = [
      for (var i = 0; i < 90; i++)
        _loc('Place number ${i + 1}',
            day: d(i % 4), tag: 'food', stayMin: 45, order: i),
    ];
    final doc = buildItineraryDocument(trip: trip(), locations: many);
    final bytes = await ItineraryPdfService.buildPdf(doc, fonts: _fonts());
    final pages = RegExp(r'/Type\s*/Page[^s]')
        .allMatches(String.fromCharCodes(bytes))
        .length;
    expect(pages, greaterThan(2));
  });

  test('every page leads back to the app; the closing band offers each store',
      () async {
    final many = [
      for (var i = 0; i < 90; i++)
        _loc('Place number ${i + 1}', day: d(i % 4), tag: 'food', order: i),
    ];
    final doc = buildItineraryDocument(trip: trip(), locations: many);
    final raw = String.fromCharCodes(
        await ItineraryPdfService.buildPdf(doc, fonts: _fonts()));
    final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(raw).length;
    expect(pages, greaterThan(2));

    // Link annotations carry their address as plain text.
    int linksTo(String url) => url.allMatches(raw).length;
    // "Powered by VoyZa": the footer of every page, plus the closing band.
    expect(linksTo(voyzaGetAppUrl), pages + 1);
    // A PDF can't tell which phone is reading it, so each store gets its own
    // button — once, in the closing band.
    expect(linksTo(voyzaAppStoreUrl), 1);
    expect(linksTo(voyzaPlayStoreUrl), 1);
  });

  test('the link in the document resolves without any website change', () {
    // The label's address is the site's root (always there) plus a tag the
    // site may act on and a section it already has — never a path that
    // would 404 until someone deploys it.
    final uri = Uri.parse(voyzaGetAppUrl);
    expect(uri.scheme, 'https');
    expect(uri.path, '/');
    expect(uri.queryParameters, {'ref': 'itinerary'});
    expect(uri.fragment, 'download');
  });

  test('file names survive awkward trip names', () {
    expect(ItineraryPdfService.fileNameFor('Hong Kong: Food/Fun?'),
        'Hong Kong FoodFun itinerary.pdf');
    expect(ItineraryPdfService.fileNameFor('   '), 'VoyZa trip itinerary.pdf');
  });
}
