import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show Rect;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/saved_location.dart';
import '../models/trip.dart';
import '../providers/all_days_route_provider.dart' show kDayRouteColors;
import '../utils/itinerary_document.dart';
import '../utils/place_tags.dart';
import '../utils/store_links.dart';

/// The three Roboto weights the document is set in (Apache 2.0, the copies
/// that ship with the Flutter SDK, bundled under assets/fonts/).
class ItineraryFonts {
  final ByteData regular;
  final ByteData medium;
  final ByteData bold;

  const ItineraryFonts({
    required this.regular,
    required this.medium,
    required this.bold,
  });

  static Future<ItineraryFonts> load() async => ItineraryFonts(
        regular: await rootBundle.load('assets/fonts/Roboto-Regular.ttf'),
        medium: await rootBundle.load('assets/fonts/Roboto-Medium.ttf'),
        bold: await rootBundle.load('assets/fonts/Roboto-Bold.ttf'),
      );
}

/// A string drawn by the device's own text engine and embedded as an
/// image — see [ItineraryPdfService.rasterize].
class RasterText {
  final Uint8List png;
  final double width;
  final double height;
  const RasterText(this.png, this.width, this.height);
}

/// Where a rasterised string appears; each role has its own size/colour.
enum RasterRole { heroTitle, stopName, stayName }

/// Exports a trip's whole itinerary as a PDF: a gradient header with the
/// trip's facts, a tag colour key, then one block per day in that day's map
/// colour — where you sleep, each stop with its tag, planned time and
/// opening hours, every name linked to Google Maps — and the places not yet
/// on a day. Text is real (selectable, searchable) in Roboto; names Roboto
/// can't draw (Chinese, Thai, Khmer, emoji…) are drawn by the device's text
/// engine and embedded as crisp images, so no script ever prints as boxes.
///
/// The document leads back to the app: every page's footer says "Powered by
/// VoyZa", and it closes on a band with the same label and a button for
/// each store.
class ItineraryPdfService {
  ItineraryPdfService._();

  // ── palette ────────────────────────────────────────────────────────────
  static const _ink = PdfColor.fromInt(0xFF1B2A41);
  static const _muted = PdfColor.fromInt(0xFF6B7A90);
  static const _hairline = PdfColor.fromInt(0xFFE3E8EF);
  static const _heroFrom = PdfColor.fromInt(0xFF0AA5D8);
  static const _heroTo = PdfColor.fromInt(0xFF7C3AED);
  static const _amber = PdfColor.fromInt(0xFFF59E0B);
  static const _green = PdfColor.fromInt(0xFF1EA672);
  static const _stayNavy = PdfColor.fromInt(0xFF2B4C9E);

  static PdfColor _dayColor(int dayNumber) => PdfColor.fromInt(
      kDayRouteColors[(dayNumber - 1) % kDayRouteColors.length].toARGB32());

  static PdfColor _tagColor(PlaceTag tag) =>
      PdfColor.fromInt(tag.color.toARGB32());

  /// [c] washed toward white: 0 = white, 1 = the colour itself. PDF fills
  /// carry no alpha here, so tints are blended up front.
  static PdfColor _tint(PdfColor c, double amount) => PdfColor(
        1 - (1 - c.red) * amount,
        1 - (1 - c.green) * amount,
        1 - (1 - c.blue) * amount,
      );

  // ── text the embedded font can't draw ──────────────────────────────────

  /// True when [text] has a character Roboto has no glyph for.
  static bool needsRaster(String text, TtfParser font) {
    for (final rune in text.runes) {
      if (rune <= 0x20) continue;
      if (!font.charToGlyphIndexMap.containsKey(rune)) return true;
    }
    return false;
  }

  static String rasterKey(RasterRole role, String text) => '${role.name}␟$text';

  /// Every (role, text) pair in [doc] that needs the raster path.
  static Set<(RasterRole, String)> rasterNeeds(
      ItineraryDocument doc, TtfParser font) {
    final out = <(RasterRole, String)>{};
    void check(RasterRole role, String text) {
      if (needsRaster(text, font)) out.add((role, text));
    }

    check(RasterRole.heroTitle, doc.tripName);
    for (final day in doc.days) {
      for (final s in day.stays) {
        check(RasterRole.stayName, s.name);
      }
      for (final s in day.stops) {
        check(RasterRole.stopName, s.name);
      }
    }
    for (final s in doc.unscheduled) {
      check(RasterRole.stopName, s.name);
    }
    return out;
  }

  /// Draws each needed string with the platform text engine (full font
  /// fallback: CJK, Thai, Khmer, emoji…) at 3× and returns PNGs sized in
  /// PDF points. One line, ellipsised at [maxWidth].
  static Future<Map<String, RasterText>> rasterize(
    Set<(RasterRole, String)> needs, {
    double maxWidth = 380,
  }) async {
    const scale = 3.0;
    final out = <String, RasterText>{};
    for (final (role, text) in needs) {
      final (double size, ui.Color color, ui.FontWeight weight) =
          switch (role) {
        RasterRole.heroTitle => (
            24.0,
            const ui.Color(0xFFFFFFFF),
            ui.FontWeight.w700
          ),
        RasterRole.stopName => (
            11.0,
            const ui.Color(0xFF1B2A41),
            ui.FontWeight.w700
          ),
        RasterRole.stayName => (
            10.0,
            const ui.Color(0xFF2B4C9E),
            ui.FontWeight.w600
          ),
      };
      final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
        fontSize: size,
        fontWeight: weight,
        maxLines: 1,
        ellipsis: '…',
      ))
        ..pushStyle(ui.TextStyle(color: color))
        ..addText(text);
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: maxWidth));
      final w = paragraph.longestLine.ceilToDouble().clamp(1.0, maxWidth);
      final h = paragraph.height.ceilToDouble().clamp(1.0, 200.0);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
        ..scale(scale)
        ..drawParagraph(paragraph, ui.Offset.zero);
      final image = await recorder
          .endRecording()
          .toImage((w * scale).ceil(), (h * scale).ceil());
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) continue;
      out[rasterKey(role, text)] = RasterText(data.buffer.asUint8List(), w, h);
    }
    return out;
  }

  // ── the document ───────────────────────────────────────────────────────

  static Future<Uint8List> buildPdf(
    ItineraryDocument doc, {
    required ItineraryFonts fonts,
    Map<String, RasterText> raster = const {},
  }) async {
    final regular = pw.Font.ttf(fonts.regular);
    final medium = pw.Font.ttf(fonts.medium);
    final bold = pw.Font.ttf(fonts.bold);

    /// [text] as real text, or its rasterised image when the font can't
    /// draw it.
    pw.Widget label(RasterRole role, String text, pw.TextStyle style) {
      final r = raster[rasterKey(role, text)];
      if (r == null) {
        return pw.Text(text, style: style, maxLines: 2);
      }
      return pw.Image(pw.MemoryImage(r.png), width: r.width, height: r.height);
    }

    final pdf = pw.Document(
      title: '${doc.tripName} — itinerary',
      author: 'VoyZa',
      creator: 'VoyZa',
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
    );

    pw.Widget pill(String text, {required PdfColor bg, required PdfColor fg}) =>
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          decoration: pw.BoxDecoration(
            color: bg,
            borderRadius: pw.BorderRadius.circular(8),
          ),
          child: pw.Text(text,
              style: pw.TextStyle(
                  font: bold, fontSize: 7.5, color: fg, letterSpacing: 0.4)),
        );

    pw.Widget dot(PdfColor color, {double size = 6}) => pw.Container(
          width: size,
          height: size,
          decoration: pw.BoxDecoration(color: color, shape: pw.BoxShape.circle),
        );

    // ── hero ─────────────────────────────────────────────────────────────
    pw.Widget heroChip(String text) => pw.Container(
          margin: const pw.EdgeInsets.only(right: 6),
          padding: const pw.EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: pw.BoxDecoration(
            color: _tint(_heroTo, 0.28),
            borderRadius: pw.BorderRadius.circular(10),
          ),
          child: pw.Text(text,
              style: pw.TextStyle(
                  font: bold,
                  fontSize: 8.5,
                  color: _heroTo,
                  letterSpacing: 0.2)),
        );

    final hero = pw.ClipRRect(
      horizontalRadius: 16,
      verticalRadius: 16,
      child: pw.Container(
        decoration: const pw.BoxDecoration(
          gradient: pw.LinearGradient(
            colors: [_heroFrom, _heroTo],
            begin: pw.Alignment.topLeft,
            end: pw.Alignment.bottomRight,
          ),
        ),
        child: pw.Stack(
          children: [
            // Soft circles — a little movement in the corner, nothing more.
            pw.Positioned(
              right: -36,
              top: -46,
              child: pw.Opacity(
                opacity: 0.14,
                child: pw.Container(
                  width: 150,
                  height: 150,
                  decoration: const pw.BoxDecoration(
                      color: PdfColors.white, shape: pw.BoxShape.circle),
                ),
              ),
            ),
            pw.Positioned(
              right: 70,
              bottom: -58,
              child: pw.Opacity(
                opacity: 0.10,
                child: pw.Container(
                  width: 110,
                  height: 110,
                  decoration: const pw.BoxDecoration(
                      color: PdfColors.white, shape: pw.BoxShape.circle),
                ),
              ),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.fromLTRB(22, 20, 22, 18),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('TRIP ITINERARY',
                      style: pw.TextStyle(
                          font: bold,
                          fontSize: 8,
                          color: PdfColors.white,
                          letterSpacing: 1.6)),
                  pw.SizedBox(height: 6),
                  label(
                    RasterRole.heroTitle,
                    doc.tripName,
                    pw.TextStyle(
                        font: bold, fontSize: 24, color: PdfColors.white),
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    [
                      if (doc.countryName != null) doc.countryName!,
                      doc.dateLine,
                    ].join('  ·  '),
                    style: pw.TextStyle(
                        font: medium, fontSize: 11, color: PdfColors.white),
                  ),
                  pw.SizedBox(height: 12),
                  pw.Row(children: [
                    heroChip(
                        '${doc.dayCount} ${doc.dayCount == 1 ? 'DAY' : 'DAYS'}'),
                    heroChip(
                        '${doc.placeCount} ${doc.placeCount == 1 ? 'PLACE' : 'PLACES'}'),
                    if (doc.stayCount > 0)
                      heroChip(
                          '${doc.stayCount} ${doc.stayCount == 1 ? 'STAY' : 'STAYS'}'),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // ── tag colour key ───────────────────────────────────────────────────
    final legend = doc.usedTags.isEmpty
        ? null
        : pw.Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: pw.WrapCrossAlignment.center,
            children: [
              for (final tag in doc.usedTags)
                pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
                  dot(_tagColor(tag), size: 7),
                  pw.SizedBox(width: 4),
                  pw.Text(tag.label,
                      style: pw.TextStyle(
                          font: medium, fontSize: 8.5, color: _muted)),
                ]),
            ],
          );

    // ── one stop ─────────────────────────────────────────────────────────
    pw.Widget stopRow(ItineraryStop s, PdfColor accent, {String? number}) {
      final nameStyle = pw.TextStyle(
        font: bold,
        fontSize: 11,
        color: s.isSkipped ? _muted : _ink,
        decoration: s.isSkipped ? pw.TextDecoration.lineThrough : null,
      );
      final meta = <pw.Widget>[];
      void sep() {
        if (meta.isNotEmpty) {
          meta.add(pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5),
            child: pw.Text('·',
                style: pw.TextStyle(font: bold, fontSize: 9, color: _muted)),
          ));
        }
      }

      final tag = s.tag;
      if (tag != null) {
        meta.add(pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
          dot(_tagColor(tag)),
          pw.SizedBox(width: 3.5),
          // "Airport" / "Train" on a Transport stop whose types say so;
          // the dot keeps it tied to the Transport row of the colour key.
          pw.Text(s.tagLabel ?? tag.label,
              style: pw.TextStyle(font: medium, fontSize: 8.5, color: _ink)),
        ]));
      }
      if (s.stayMinutes > 0) {
        sep();
        meta.add(pw.Text('Stay ${formatStayMinutes(s.stayMinutes)}',
            style: const pw.TextStyle(fontSize: 8.5, color: _muted)));
      }
      final hours = s.hoursLine;
      if (hours != null) {
        sep();
        meta.add(pw.Text(hours,
            style: pw.TextStyle(
                font: s.hoursCaution ? medium : regular,
                fontSize: 8.5,
                color: s.hoursCaution ? _amber : _muted)));
      }
      final span = s.spanLabel;
      if (span != null) {
        sep();
        meta.add(pw.Text(span,
            style: const pw.TextStyle(fontSize: 8.5, color: _muted)));
      }

      return pw.Inseparable(
          child: pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 3),
        padding: const pw.EdgeInsets.fromLTRB(10, 7, 10, 7),
        decoration: pw.BoxDecoration(
          color: _tint(accent, 0.07),
          border: pw.Border(left: pw.BorderSide(color: accent, width: 3)),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Container(
              width: 18,
              height: 18,
              alignment: pw.Alignment.center,
              decoration: pw.BoxDecoration(
                color: number == null ? _tint(accent, 0.35) : accent,
                shape: pw.BoxShape.circle,
              ),
              child: number == null
                  ? null
                  : pw.Text(number,
                      style: pw.TextStyle(
                          font: bold, fontSize: 8.5, color: PdfColors.white)),
            ),
            pw.SizedBox(width: 9),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.UrlLink(
                    destination: s.mapsUrl,
                    child: label(RasterRole.stopName, s.name, nameStyle),
                  ),
                  if (meta.isNotEmpty) ...[
                    pw.SizedBox(height: 3),
                    pw.Wrap(
                      crossAxisAlignment: pw.WrapCrossAlignment.center,
                      runSpacing: 2,
                      children: meta,
                    ),
                  ],
                ],
              ),
            ),
            if (s.isDone) ...[
              pw.SizedBox(width: 8),
              pill('DONE', bg: _tint(_green, 0.18), fg: _green),
            ] else if (s.isSkipped) ...[
              pw.SizedBox(width: 8),
              pill('SKIPPED', bg: _hairline, fg: _muted),
            ],
          ],
        ),
      ));
    }

    // ── one day ──────────────────────────────────────────────────────────
    List<pw.Widget> dayBlock(ItineraryDay day) {
      final accent = _dayColor(day.number);
      final header = pw.Container(
        margin: const pw.EdgeInsets.only(top: 14, bottom: 5),
        padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: pw.BoxDecoration(
          color: accent,
          borderRadius: pw.BorderRadius.circular(9),
        ),
        child: pw.Row(children: [
          pw.Text(day.title.toUpperCase(),
              style: pw.TextStyle(
                  font: bold,
                  fontSize: 11,
                  color: PdfColors.white,
                  letterSpacing: 0.8)),
          if (day.subtitle != null) ...[
            pw.SizedBox(width: 10),
            pw.Text(day.subtitle!,
                style: pw.TextStyle(
                    font: medium, fontSize: 10, color: PdfColors.white)),
          ],
          pw.Spacer(),
          pw.Text(
            day.stops.isEmpty
                ? 'Free day'
                : '${day.stops.length} ${day.stops.length == 1 ? 'place' : 'places'}',
            style:
                pw.TextStyle(font: medium, fontSize: 9, color: PdfColors.white),
          ),
        ]),
      );

      final stays = [
        for (final s in day.stays)
          pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 4),
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: pw.Row(children: [
              pill('STAY', bg: _tint(_stayNavy, 0.16), fg: _stayNavy),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: pw.UrlLink(
                  destination: s.mapsUrl,
                  child: label(
                    RasterRole.stayName,
                    s.name,
                    pw.TextStyle(font: medium, fontSize: 10, color: _stayNavy),
                  ),
                ),
              ),
              if (s.spanLabel != null)
                pw.Text(s.spanLabel!,
                    style: const pw.TextStyle(fontSize: 8.5, color: _muted)),
            ]),
          ),
      ];

      final rows = <pw.Widget>[];
      var n = 0;
      for (final s in day.stops) {
        // Numbers follow the plan; a skipped stop isn't part of the walk.
        rows.add(stopRow(s, accent, number: s.isSkipped ? null : '${++n}'));
      }
      if (rows.isEmpty && stays.isEmpty) {
        rows.add(pw.Padding(
          padding: const pw.EdgeInsets.fromLTRB(12, 2, 12, 4),
          child: pw.Text('Nothing planned yet — room to wander.',
              style: const pw.TextStyle(fontSize: 9, color: _muted)),
        ));
      }

      // The header travels with where-you-stay AND the first stop, so a day
      // never starts as a lonely bar (or a bar plus a hotel) at the foot of
      // a page with its places stranded on the next one.
      // Inseparable: a plain Column may itself be split across pages.
      return [
        pw.Inseparable(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [header, ...stays, if (rows.isNotEmpty) rows.first],
          ),
        ),
        ...rows.skip(1),
      ];
    }

    List<pw.Widget> unscheduledBlock() {
      if (doc.unscheduled.isEmpty) return const [];
      final header = pw.Container(
        margin: const pw.EdgeInsets.only(top: 16, bottom: 5),
        padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: pw.BoxDecoration(
          color: _amber,
          borderRadius: pw.BorderRadius.circular(9),
        ),
        child: pw.Row(children: [
          pw.Text('NOT ON A DAY YET',
              style: pw.TextStyle(
                  font: bold,
                  fontSize: 11,
                  color: PdfColors.white,
                  letterSpacing: 0.8)),
          pw.Spacer(),
          pw.Text(
            '${doc.unscheduled.length} ${doc.unscheduled.length == 1 ? 'place' : 'places'}',
            style:
                pw.TextStyle(font: medium, fontSize: 9, color: PdfColors.white),
          ),
        ]),
      );
      final rows = [for (final s in doc.unscheduled) stopRow(s, _amber)];
      return [
        pw.Inseparable(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [header, rows.first],
          ),
        ),
        ...rows.skip(1),
      ];
    }

    // ── the way back to the app ──────────────────────────────────────────
    // A link in a PDF is one fixed address, and the reader may be on any
    // phone or laptop — so the label goes to the site's download section
    // (both stores), and each store also gets a button of its own.
    pw.Widget storeButton(String text, String url) => pw.Padding(
          padding: const pw.EdgeInsets.only(left: 6),
          child: pw.UrlLink(
            destination: url,
            child: pw.Container(
              padding:
                  const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: pw.BoxDecoration(
                color: PdfColors.white,
                borderRadius: pw.BorderRadius.circular(14),
              ),
              child: pw.Text(text,
                  style: pw.TextStyle(font: bold, fontSize: 9, color: _heroTo)),
            ),
          ),
        );

    // The hero's gradient, mirrored: the words sit on the violet end, where
    // white reads best, and the document ends the way it began.
    final poweredBy = pw.Padding(
      padding: const pw.EdgeInsets.only(top: 16),
      child: pw.ClipRRect(
        horizontalRadius: 12,
        verticalRadius: 12,
        child: pw.Container(
          padding: const pw.EdgeInsets.fromLTRB(16, 11, 12, 11),
          decoration: const pw.BoxDecoration(
            gradient: pw.LinearGradient(
              colors: [_heroTo, _heroFrom],
              begin: pw.Alignment.centerLeft,
              end: pw.Alignment.centerRight,
            ),
          ),
          child: pw.Row(children: [
            pw.Expanded(
              child: pw.UrlLink(
                destination: voyzaGetAppUrl,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('Powered by VoyZa',
                        style: pw.TextStyle(
                            font: bold,
                            fontSize: 12.5,
                            color: PdfColors.white)),
                    pw.SizedBox(height: 2),
                    pw.Text('Plan your next trip like this one.',
                        style: pw.TextStyle(
                            font: medium,
                            fontSize: 8.5,
                            color: PdfColors.white)),
                  ],
                ),
              ),
            ),
            storeButton('App Store', voyzaAppStoreUrl),
            storeButton('Google Play', voyzaPlayStoreUrl),
          ]),
        ),
      ),
    );

    final exportedOn =
        'Exported ${DateFormat('MMM d, y').format(doc.generatedAt)}';

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(34, 34, 34, 36),
        maxPages: 200,
        footer: (context) => pw.Container(
          margin: const pw.EdgeInsets.only(top: 10),
          padding: const pw.EdgeInsets.only(top: 1),
          decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: _hairline, width: 0.8)),
          ),
          child: pw.Row(children: [
            // The padding is inside the link: 8pt type alone is too small a
            // target once a phone has shrunk the page to its screen.
            pw.UrlLink(
              destination: voyzaGetAppUrl,
              child: pw.Padding(
                padding: const pw.EdgeInsets.fromLTRB(0, 5, 5, 5),
                child: pw.Text('Powered by VoyZa',
                    style:
                        pw.TextStyle(font: bold, fontSize: 8, color: _heroTo)),
              ),
            ),
            pw.Text('·  Tap a place name to open it in Google Maps',
                style: const pw.TextStyle(fontSize: 8, color: _muted)),
            pw.Spacer(),
            pw.Text(
                '$exportedOn  ·  '
                'Page ${context.pageNumber} of ${context.pagesCount}',
                style: const pw.TextStyle(fontSize: 8, color: _muted)),
          ]),
        ),
        build: (context) => [
          hero,
          if (legend != null) ...[
            pw.SizedBox(height: 12),
            legend,
          ],
          for (final day in doc.days) ...dayBlock(day),
          ...unscheduledBlock(),
          poweredBy,
        ],
      ),
    );
    return pdf.save();
  }

  /// A filesystem-safe "<trip> itinerary.pdf".
  static String fileNameFor(String tripName) {
    final safe = tripName
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '${safe.isEmpty ? 'VoyZa trip' : safe} itinerary.pdf';
  }

  /// Builds the itinerary for [trip] and hands it to the share sheet.
  /// [shareOrigin] anchors the popover on iPad.
  static Future<void> exportAndShare({
    required Trip trip,
    required List<SavedLocation> locations,
    Rect? shareOrigin,
  }) async {
    final doc = buildItineraryDocument(trip: trip, locations: locations);
    final fonts = await ItineraryFonts.load();
    final needs = rasterNeeds(doc, TtfParser(fonts.bold));
    final raster =
        needs.isEmpty ? const <String, RasterText>{} : await rasterize(needs);
    final bytes = await buildPdf(doc, fonts: fonts, raster: raster);

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${fileNameFor(trip.name)}');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'application/pdf')],
      sharePositionOrigin: shareOrigin,
    ));
  }
}
