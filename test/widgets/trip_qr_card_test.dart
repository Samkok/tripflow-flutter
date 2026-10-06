import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/services/trip_qr_text_store.dart';
import 'package:voyza/utils/trip_qr_text.dart';
import 'package:voyza/utils/trip_share_link.dart';
import 'package:voyza/widgets/trip_qr_card.dart';

/// Real letterforms instead of the test font's boxes, so an exported card
/// can be looked at. Roboto ships with the app for the PDF export.
Future<void> loadFonts() async {
  for (final family in ['Roboto', 'monospace']) {
    final loader = FontLoader(family);
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      final bytes = File('assets/fonts/Roboto-$weight.ttf').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}

Future<GlobalKey> pumpCard(
  WidgetTester tester, {
  required TripQrText text,
  String shareCode = 'AB12CD',
  String? countryCode = 'JP',
}) async {
  // A phone-sized surface: the card is taller than the default 800×600.
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final key = GlobalKey();
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'Roboto'),
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: key,
          child: TripQrCard(
            link: tripShareLink(shareCode)!,
            shareCode: shareCode,
            text: text,
            countryCode: countryCode,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  return key;
}

void main() {
  setUpAll(loadFonts);

  group('TripQrText', () {
    test('a trip with a country leads with the country', () {
      final text = TripQrText.forTrip(
        tripName: 'Tokyo 2026',
        countryName: 'Japan',
        placeCount: 12,
        dayCount: 5,
      );
      expect(text.lead, 'Places to visit in');
      expect(text.title, 'Japan');
      expect(text.tripName, 'Tokyo 2026');
      expect(text.stats, '12 places · 5 days');
      expect(text.sentence, 'Places to visit in Japan');
    });

    test('a trip without a country leads with its own name', () {
      for (final country in [null, '', '   ']) {
        final text =
            TripQrText.forTrip(tripName: ' Road trip ', countryName: country);
        expect(text.lead, 'Places to visit');
        expect(text.title, 'Road trip');
        expect(text.tripName, isNull);
        expect(text.sentence, 'Places to visit Road trip');
      }
    });

    test('a trip named after its country does not say it twice', () {
      final text = TripQrText.forTrip(tripName: 'japan', countryName: 'Japan');
      expect(text.title, 'Japan');
      expect(text.tripName, isNull);
    });

    test('a nameless trip still has a title', () {
      expect(TripQrText.forTrip(tripName: '').title, 'My trip');
      expect(
        TripQrText.forTrip(tripName: '', countryName: 'Peru').tripName,
        isNull,
      );
    });

    test('counts read naturally and unknown ones are left out', () {
      String? stats({int? places, int? days}) => TripQrText.forTrip(
            tripName: 'x',
            placeCount: places,
            dayCount: days,
          ).stats;
      expect(stats(places: 1, days: 1), '1 place · 1 day');
      expect(stats(places: 8), '8 places');
      expect(stats(days: 3), '3 days');
      expect(stats(places: 0, days: 0), isNull);
      expect(stats(), isNull);
    });
  });

  group('a headline of the traveller\'s own', () {
    final original = TripQrText.forTrip(
      tripName: 'Tokyo 2026',
      countryName: 'Japan',
      placeCount: 12,
      dayCount: 5,
    );

    test('replaces both lines and keeps everything else', () {
      final text =
          original.withHeadline(lead: 'Best ramen spots in', title: 'Tokyo');
      expect(text.lead, 'Best ramen spots in');
      expect(text.title, 'Tokyo');
      expect(text.sentence, 'Best ramen spots in Tokyo');
      expect(text.tripName, 'Tokyo 2026');
      expect(text.stats, '12 places · 5 days');
      expect(text.isCustom, isTrue);
      expect(original.isCustom, isFalse);
    });

    test('may drop the small line', () {
      final text = original.withHeadline(lead: '   ', title: 'Our honeymoon');
      expect(text.lead, isEmpty);
      expect(text.sentence, 'Our honeymoon');
    });

    test('a blank big line is no headline at all', () {
      for (final blank in ['', '   ', '\n\t ']) {
        final text = original.withHeadline(lead: 'Anything', title: blank);
        expect(text.title, 'Japan');
        expect(text.lead, 'Places to visit in');
        expect(text.isCustom, isFalse);
      }
    });

    test('is tidied: one line, single spaces, no loose ends', () {
      final text = original.withHeadline(
        lead: '  Where   we\nare  going ',
        title: '\tHong   Kong\n',
      );
      expect(text.lead, 'Where we are going');
      expect(text.title, 'Hong Kong');
    });

    test('is cut at the limit without splitting a character', () {
      final long = 'Hong Kong ' * 10;
      final text = original.withHeadline(lead: long, title: long);
      expect(text.title.characters.length,
          lessThanOrEqualTo(TripQrText.maxTitleLength));
      expect(text.lead.characters.length,
          lessThanOrEqualTo(TripQrText.maxLeadLength));
      expect(text.title, isNot(endsWith(' ')));

      // Forty flags are eighty code points and 160 UTF-16 units: a cut by
      // units would leave half a flag behind.
      final flags = '🇯🇵' * 60;
      final cut = cleanHeadlinePart(flags, 40);
      expect(cut.characters.length, 40);
      expect(cut, '🇯🇵' * 40);
    });

    test('the trip\'s name is printed once, whatever the headline', () {
      // Headline says the trip's name → the line under it goes away…
      final named =
          original.withHeadline(lead: 'Come along to', title: 'tokyo 2026');
      expect(named.tripName, isNull);
      // …and comes back when the headline stops saying it.
      expect(
        named.withHeadline(lead: 'Come along to', title: 'Japan').tripName,
        'Tokyo 2026',
      );
      // A trip with no country leads with its name; a new headline brings
      // the name back underneath.
      final noCountry = TripQrText.forTrip(tripName: 'Road trip');
      expect(noCountry.tripName, isNull);
      expect(
        noCountry.withHeadline(lead: '', title: 'Two weeks west').tripName,
        'Road trip',
      );
    });
  });

  group('TripQrTextStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('remembers a headline per trip and forgets it on request', () async {
      final store = TripQrTextStore();
      expect(await store.load('trip1'), isNull);

      await store.save('trip1', (lead: 'Food crawl in', title: 'Hong Kong'));
      await store.save('trip2', (lead: '', title: 'Our honeymoon'));
      expect(await store.load('trip1'),
          (lead: 'Food crawl in', title: 'Hong Kong'));
      expect(await store.load('trip2'), (lead: '', title: 'Our honeymoon'));

      await store.clear('trip1');
      expect(await store.load('trip1'), isNull);
      expect(await store.load('trip2'), isNotNull);
    });

    test('what cannot be read is treated as nothing saved', () async {
      SharedPreferences.setMockInitialValues({
        '${TripQrTextStore.keyPrefix}broken': '{not json',
        '${TripQrTextStore.keyPrefix}list': '["a","b"]',
        '${TripQrTextStore.keyPrefix}blank': '{"lead":"Hello","title":"  "}',
        '${TripQrTextStore.keyPrefix}numbers': '{"lead":1,"title":2}',
      });
      final store = TripQrTextStore();
      expect(await store.load('broken'), isNull);
      expect(await store.load('list'), isNull);
      expect(await store.load('blank'), isNull);
      expect(await store.load('numbers'), (lead: '1', title: '2'));
    });

    test('an over-long stored headline is cut like a typed one', () async {
      SharedPreferences.setMockInitialValues({
        '${TripQrTextStore.keyPrefix}t':
            '{"lead":"${'a' * 90}","title":"${'b ' * 90}"}',
      });
      final saved = await TripQrTextStore().load('t');
      expect(saved!.lead.length, TripQrText.maxLeadLength);
      expect(saved.title.length, lessThanOrEqualTo(TripQrText.maxTitleLength));
    });
  });

  group('qrModulesFor', () {
    final link = tripShareLink('AB12CD')!;

    test('a trip link fits the 29-module grid', () {
      final grid = qrModulesFor(link);
      expect(grid, hasLength(29));
      expect(grid.every((row) => row.length == 29), isTrue);
    });

    test('the three corner markers are where scanners look for them', () {
      final grid = qrModulesFor(link);
      final n = grid.length;
      for (final (row, col) in [(0, 0), (0, n - 7), (n - 7, 0)]) {
        // Dark frame, light ring, dark centre.
        expect(grid[row][col], isTrue);
        expect(grid[row + 6][col + 6], isTrue);
        expect(grid[row + 1][col + 1], isFalse);
        expect(grid[row + 3][col + 3], isTrue);
      }
      // The fourth corner carries data, not a marker.
      expect(
        [for (var i = 0; i < 7; i++) grid[n - 1 - i][n - 1]].every((d) => d),
        isFalse,
      );
    });

    test('different trips give different codes', () {
      expect(qrModulesFor(tripShareLink('K7QM2X')!), isNot(qrModulesFor(link)));
      expect(qrModulesFor(link), qrModulesFor(link));
    });
  });

  group('TripQrCard', () {
    testWidgets('shows the destination, the trip and the code', (tester) async {
      await pumpCard(
        tester,
        text: TripQrText.forTrip(
          tripName: 'Tokyo 2026',
          countryName: 'Japan',
          placeCount: 12,
          dayCount: 5,
        ),
      );
      expect(find.text('Places to visit in'), findsOneWidget);
      expect(find.text('Japan'), findsOneWidget);
      expect(find.text('Tokyo 2026'), findsOneWidget);
      expect(find.text('12 places · 5 days'), findsOneWidget);
      expect(find.text('TRIP-AB12CD'), findsOneWidget);
      expect(find.text('Scan to get your own copy'), findsOneWidget);
      // The link is inside the code, not printed on the card.
      expect(find.textContaining('voyza.xtremon.com'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the QR code holds the trip link and nothing else',
        (tester) async {
      await pumpCard(
        tester,
        shareCode: 'K7QM2X',
        text: TripQrText.forTrip(tripName: 'Lisbon', countryName: 'Portugal'),
        countryCode: 'PT',
      );
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<TripQrPainter>()
          .single;
      expect(
        painter.modules,
        qrModulesFor('https://voyza.xtremon.com/c/K7QM2X'),
      );
    });

    testWidgets('long names and missing details still fit', (tester) async {
      for (final text in [
        TripQrText.forTrip(
          tripName: 'A very long trip name that keeps going and going '
              'well past the edge of any card',
          countryName: 'Saint Vincent and the Grenadines',
          placeCount: 148,
          dayCount: 31,
        ),
        TripQrText.forTrip(
          tripName: 'Overland from Cairo to Cape Town by train and bus',
        ),
        TripQrText.forTrip(tripName: 'Rome'),
      ]) {
        await pumpCard(tester, text: text, countryCode: null);
        expect(tester.takeException(), isNull, reason: text.title);
        // The code itself never shrinks or gets pushed off the card.
        final qr = find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is TripQrPainter);
        expect(tester.getSize(qr), const Size(196, 196), reason: text.title);
      }
    });

    testWidgets('large system text does not change the card', (tester) async {
      Future<Size> cardSize(double scale) async {
        tester.view.physicalSize = const Size(1170, 2532);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(390, 844),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: Center(
                child: TripQrCard(
                  link: tripShareLink('AB12CD')!,
                  shareCode: 'AB12CD',
                  text: TripQrText.forTrip(
                    tripName: 'Tokyo 2026',
                    countryName: 'Japan',
                    placeCount: 12,
                    dayCount: 5,
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.pump();
        return tester.getSize(find.byType(TripQrCard));
      }

      final normal = await cardSize(1);
      final large = await cardSize(2);
      expect(large, normal);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reads as one sentence to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCard(
        tester,
        text: TripQrText.forTrip(tripName: 'Tokyo 2026', countryName: 'Japan'),
      );
      expect(
        find.bySemanticsLabel(RegExp(
            r'^Places to visit in Japan\. QR code that opens this trip in '
            r'VoyZa\. Code TRIP-AB12CD\.$')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('the sheet shows the whole card on small and large phones',
        (tester) async {
      for (final screen in const [
        Size(320, 568), // the smallest phone still in use
        Size(360, 640),
        Size(430, 932),
      ]) {
        tester.view.physicalSize = screen * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showTripQrSheet(
                    context,
                    link: tripShareLink('AB12CD')!,
                    shareCode: 'AB12CD',
                    countryCode: 'VC',
                    text: TripQrText.forTrip(
                      tripName: 'Island hopping with the whole family',
                      countryName: 'Saint Vincent and the Grenadines',
                      placeCount: 23,
                      dayCount: 9,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$screen');

        expect(find.text('Trip QR code'), findsOneWidget);
        expect(find.text('Share card'), findsOneWidget);
        final qr = tester.getRect(find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is TripQrPainter));
        final share = tester.getRect(find.text('Share card'));
        expect(qr.top, greaterThanOrEqualTo(0), reason: '$screen');
        expect(qr.left, greaterThanOrEqualTo(0), reason: '$screen');
        expect(qr.right, lessThanOrEqualTo(screen.width), reason: '$screen');
        expect(qr.bottom, lessThan(share.top), reason: '$screen');
        expect(share.bottom, lessThanOrEqualTo(screen.height),
            reason: '$screen');
        // Shrunk to fit, never stretched — and still a square.
        expect(qr.width, lessThanOrEqualTo(196.01), reason: '$screen');
        expect(qr.width, closeTo(qr.height, 0.01), reason: '$screen');
        // Big enough to scan from a hand's distance on the smallest phone.
        expect(qr.width, greaterThan(118), reason: '$screen');

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.text('Trip QR code'), findsNothing);
      }
    });

    group('editing the text', () {
      setUp(() => SharedPreferences.setMockInitialValues({}));

      Future<void> openSheet(WidgetTester tester, {String? tripId}) async {
        tester.view.physicalSize = const Size(1170, 2532);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showTripQrSheet(
                    context,
                    link: tripShareLink('AB12CD')!,
                    shareCode: 'AB12CD',
                    countryCode: 'HK',
                    tripId: tripId,
                    text: TripQrText.forTrip(
                      tripName: 'Long weekend',
                      countryName: 'Hong Kong',
                      placeCount: 9,
                      dayCount: 3,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      Future<void> rewrite(
        WidgetTester tester, {
        required String lead,
        required String title,
      }) async {
        await tester.tap(find.text('Edit text'));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('trip-qr-lead')), lead);
        await tester.enterText(
            find.byKey(const ValueKey('trip-qr-title')), title);
        await tester.pump();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
      }

      TripQrText shownText(WidgetTester tester) =>
          tester.widget<TripQrCard>(find.byType(TripQrCard)).text;

      testWidgets('the form opens on the words the card shows', (tester) async {
        await openSheet(tester, tripId: 'trip1');
        expect(find.text('Places to visit in'), findsOneWidget);
        expect(find.text('Hong Kong'), findsOneWidget);

        await tester.tap(find.text('Edit text'));
        await tester.pumpAndSettle();
        TextField field(String key) =>
            tester.widget<TextField>(find.byKey(ValueKey(key)));
        expect(field('trip-qr-lead').controller!.text, 'Places to visit in');
        expect(field('trip-qr-title').controller!.text, 'Hong Kong');
        // Nothing of the traveller's yet, so nothing to go back to.
        expect(find.text('Use the original'), findsNothing);
      });

      testWidgets('saving rewrites the card and is remembered for the trip',
          (tester) async {
        await openSheet(tester, tripId: 'trip1');
        await rewrite(tester, lead: 'Food crawl in', title: 'Kowloon');

        expect(find.text('Food crawl in'), findsOneWidget);
        expect(find.text('Kowloon'), findsOneWidget);
        expect(find.text('Places to visit in'), findsNothing);
        expect(find.text('Long weekend'), findsOneWidget);
        expect(shownText(tester).isCustom, isTrue);
        // The code is the trip's, whatever the words say.
        final painter = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((p) => p.painter)
            .whereType<TripQrPainter>()
            .single;
        expect(painter.modules, qrModulesFor(tripShareLink('AB12CD')!));
        expect(await TripQrTextStore().load('trip1'),
            (lead: 'Food crawl in', title: 'Kowloon'));

        // Closed and opened again: the card comes back as it was left.
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('Kowloon'), findsOneWidget);
        expect(find.text('Food crawl in'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('another trip keeps its own words', (tester) async {
        await TripQrTextStore()
            .save('trip1', (lead: 'Food crawl in', title: 'Kowloon'));
        await openSheet(tester, tripId: 'trip2');
        expect(find.text('Hong Kong'), findsOneWidget);
        expect(find.text('Kowloon'), findsNothing);
      });

      testWidgets('an empty small line leaves only the big one',
          (tester) async {
        await openSheet(tester, tripId: 'trip1');
        await rewrite(tester, lead: '', title: 'Our long weekend');
        expect(find.text('Our long weekend'), findsOneWidget);
        expect(find.text('Places to visit in'), findsNothing);
        expect(shownText(tester).lead, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the big line cannot be saved empty', (tester) async {
        await openSheet(tester, tripId: 'trip1');
        await tester.tap(find.text('Edit text'));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('trip-qr-title')), '   ');
        await tester.pump();
        expect(find.text('The big line needs some text'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Hong Kong'), findsOneWidget);
        expect(await TripQrTextStore().load('trip1'), isNull);
      });

      testWidgets('cancelling changes nothing', (tester) async {
        await openSheet(tester, tripId: 'trip1');
        await tester.tap(find.text('Edit text'));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('trip-qr-title')), 'Somewhere else');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Hong Kong'), findsOneWidget);
        expect(find.text('Somewhere else'), findsNothing);
        expect(await TripQrTextStore().load('trip1'), isNull);
      });

      testWidgets('"Use the original" brings the trip\'s headline back',
          (tester) async {
        await openSheet(tester, tripId: 'trip1');
        await rewrite(tester, lead: 'Food crawl in', title: 'Kowloon');
        expect(find.text('Kowloon'), findsOneWidget);

        await tester.tap(find.text('Edit text'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Use the original'));
        await tester.pumpAndSettle();

        expect(find.text('Places to visit in'), findsOneWidget);
        expect(find.text('Hong Kong'), findsOneWidget);
        expect(shownText(tester).isCustom, isFalse);
        expect(await TripQrTextStore().load('trip1'), isNull);
      });

      testWidgets('typing the original back in is the original',
          (tester) async {
        await openSheet(tester, tripId: 'trip1');
        await rewrite(tester, lead: 'Food crawl in', title: 'Kowloon');
        await rewrite(tester,
            lead: ' Places to visit in ', title: 'Hong  Kong');
        expect(shownText(tester).isCustom, isFalse);
        expect(await TripQrTextStore().load('trip1'), isNull);
      });

      testWidgets('without a trip id the rewrite lasts only for the sheet',
          (tester) async {
        await openSheet(tester);
        await rewrite(tester, lead: 'Food crawl in', title: 'Kowloon');
        expect(find.text('Kowloon'), findsOneWidget);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getKeys().where((k) => k.startsWith(TripQrTextStore.keyPrefix)),
          isEmpty,
        );
      });
    });

    // Looked at, and scanned, by hand:
    //   VOYZA_QR_CARD_OUT=/tmp/card flutter test test/widgets/trip_qr_card_test.dart
    // writes card-country.png, card-no-country.png, card-long.png and two
    // cards with a headline of the traveller's own.
    testWidgets('exports the card as an image', (tester) async {
      final out = Platform.environment['VOYZA_QR_CARD_OUT'];
      final cases = <String, (TripQrText, String?)>{
        'country': (
          TripQrText.forTrip(
            tripName: 'Tokyo 2026',
            countryName: 'Japan',
            placeCount: 12,
            dayCount: 5,
          ),
          'JP',
        ),
        'no-country': (
          TripQrText.forTrip(
              tripName: 'Coast road, north to south', placeCount: 7),
          null,
        ),
        'long': (
          TripQrText.forTrip(
            tripName: 'Island hopping with the whole family',
            countryName: 'Saint Vincent and the Grenadines',
            placeCount: 23,
            dayCount: 9,
          ),
          'VC',
        ),
        'custom': (
          TripQrText.forTrip(
            tripName: 'Long weekend',
            countryName: 'Hong Kong',
            placeCount: 9,
            dayCount: 3,
          ).withHeadline(
              lead: 'Where we are eating in', title: 'Hong Kong & Macau'),
          'HK',
        ),
        'custom-one-line': (
          TripQrText.forTrip(
            tripName: 'Long weekend',
            countryName: 'Hong Kong',
            placeCount: 9,
            dayCount: 3,
          ).withHeadline(lead: '', title: 'Our first trip together'),
          'HK',
        ),
      };
      for (final entry in cases.entries) {
        final key = await pumpCard(
          tester,
          text: entry.value.$1,
          countryCode: entry.value.$2,
        );
        await tester.runAsync(() async {
          // The flag is an asset; give it a moment to load.
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await tester.pump();

        late final ByteData? png;
        late final int width;
        await tester.runAsync(() async {
          final image = await captureTripQrCard(key);
          width = image!.width;
          png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
        });
        expect(png, isNotNull, reason: entry.key);
        // 300 wide plus its margins, at three pixels per point.
        expect(width, (300 + 26 + 26) * 3, reason: entry.key);
        if (out != null) {
          File('$out-${entry.key}.png')
              .writeAsBytesSync(png!.buffer.asUint8List());
        }
      }
    });
  });
}
