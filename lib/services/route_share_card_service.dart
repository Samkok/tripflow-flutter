import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:gal/gal.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/location_model.dart';
import 'analytics_service.dart';
import 'referral_service.dart';
import 'supabase_service.dart';
import 'time_saved_ledger_service.dart';

/// Destination formats for the realistic map card. Instagram center-crops
/// feed posts to ~4:5 (Stories are full-bleed 9:16), so one render cannot
/// serve both surfaces — the share flow renders per destination instead
/// (the Strava pattern: per-surface assets, never one image cropped by the
/// platform).
enum ShareCardFormat {
  /// 9:16 full-bleed — Stories / Reels / WhatsApp status.
  story(1080, 1920, 140),

  /// 4:5 — Instagram & Facebook feed posts, shown uncropped.
  post(1080, 1350, 80);

  const ShareCardFormat(this.width, this.height, this.bottomReserve);
  final double width;
  final double height;

  /// Bottom margin under the text block. Deliberately snug (owner's call:
  /// the text hugs the bottom-left corner so the route image dominates).
  /// NOTE this sits inside Instagram's ~250px advisory story-chrome zone
  /// and a 4:5 feed crop of the story render WILL clip it — feed posts are
  /// what the [post] format is for.
  final double bottomReserve;

  /// width : height — the shape the map capture window must match.
  double get aspect => width / height;
}

/// Renders and shares the branded before/after route card — the artifact that
/// lets the optimize "aha" leave the app (Contagious: observable usage +
/// behavioral residue). Stylized polyline diagrams, not map tiles: offline-safe,
/// distinctive, and legally clean.
///
/// Layout (1200×630, social-preview ratio):
///   [ BEFORE panel ]  [ AFTER panel ]
///   headline stat ("~1h 40m of travel time saved") + VoyZa wordmark/link
///
/// Follows the marker_utils PictureRecorder→toImage pattern and the
/// csv_service temp-file→Share.shareXFiles pattern. Never throws into callers.
class RouteShareCardService {
  RouteShareCardService._();
  static final instance = RouteShareCardService._();

  static const double _w = 1200;
  static const double _h = 630;

  // Brand palette (theme-independent so the card renders identically for
  // every user and in both light/dark app themes).
  static const _bg = Color(0xFF0E1726);
  static const _panel = Color(0xFF16233A);
  static const _beforeLine = Color(0xFFFF6B6B);
  static const _afterLine = Color(0xFF00D4FF); // AppTheme.primaryColor
  static const _text = Color(0xFFF3F6FB);
  static const _subText = Color(0xFF9AA7BD);

  // ── Brand display type ────────────────────────────────────────────────
  // No font file is bundled (keeps the binary lean and avoids licensing),
  // so the wordmark uses a PLATFORM STACK: the engine takes the first
  // family that exists on the device and silently falls back to the system
  // face if none do — never a missing-glyph box. These are condensed /
  // geometric grotesques: distinctive enough to read as a logotype, still
  // perfectly legible at card sizes. Paired with w900 + wide letterSpacing
  // at the call site, which is what actually makes it look designed.
  // Map-card treatment: a light gaussian blur (sigma in card pixels — the
  // 1080-wide card shows at ~390pt, so this reads as roughly a third of
  // the value) + a uniform low-alpha navy veil. Tuned to keep routes and
  // markers clearly visible while giving text reliable contrast anywhere.
  static const double _mapBlurSigma =
      0.8; // tuned to keep routes/markers readable
  static const Color _mapVeil = Color(0x260E1726); // _bg at ~15%

  // Map-card text is drawn slightly soft (~15% of glyph size as gaussian
  // sigma): de-emphasizes the caption layer so the route image reads as
  // the hero, while every line stays comfortably legible.
  static const double _textBlurFactor = 0.045;

  static const String _displayFont = 'Avenir Next Condensed'; // iOS/macOS
  static const List<String> _displayFontFallback = <String>[
    'AvenirNextCondensed-Heavy', // iOS PostScript name
    'Futura', // iOS
    'sans-serif-condensed', // Android → Roboto Condensed
    'Roboto Condensed', // Android (explicit)
    'Helvetica Neue', // last resort before the system default
  ];

  /// Renders the card to a temp PNG. Returns null on any failure.
  /// [lifetimeSaved] adds the compounding all-time footer when it's
  /// meaningfully bigger than this route's own saving.
  Future<File?> renderCard({
    required List<LocationModel> originalOrder,
    required List<LocationModel> optimizedOrder,
    required Duration timeSaved,
    String? tripName,
    String? dayLabel,
    Duration lifetimeSaved = Duration.zero,
  }) async {
    try {
      if (optimizedOrder.length < 2) return null;
      final before =
          (originalOrder.length >= 2 ? originalOrder : optimizedOrder)
              .map((l) => l.coordinates)
              .toList();
      final after = optimizedOrder.map((l) => l.coordinates).toList();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      // Background.
      canvas.drawRect(const Rect.fromLTWH(0, 0, _w, _h), Paint()..color = _bg);

      // Title.
      final stops = optimizedOrder.length;
      final title = (tripName != null && tripName.trim().isNotEmpty)
          ? tripName.trim()
          : 'My $stops-stop day, untangled';
      // Day note above the trip name — story viewers should know which day
      // of the trip they're looking at.
      var titleY = 40.0;
      if (dayLabel != null && dayLabel.trim().isNotEmpty) {
        _drawText(canvas, dayLabel.trim().toUpperCase(), const Offset(48, 16),
            fontSize: 20, weight: FontWeight.w700, color: _subText);
        titleY = 48.0;
      }
      _drawText(canvas, title, Offset(48, titleY),
          fontSize: 40, weight: FontWeight.w800, color: _text, maxWidth: 900);

      // Panels.
      const panelTop = 120.0;
      const panelH = 360.0;
      const panelW = 520.0;
      const leftX = 48.0;
      const rightX = _w - 48.0 - panelW;
      // Emotional arc, not just data: the BEFORE label names the villain.
      _drawPanel(canvas, const Rect.fromLTWH(leftX, panelTop, panelW, panelH),
          label: 'BEFORE — THE ZIG-ZAG DAY',
          points: before,
          line: _beforeLine,
          numbered: false);
      _drawPanel(canvas, const Rect.fromLTWH(rightX, panelTop, panelW, panelH),
          label: 'AFTER — OPTIMIZED',
          points: after,
          line: _afterLine,
          numbered: true);

      // Arrow between panels.
      _drawText(canvas, '→', Offset(_w / 2 - 18, panelTop + panelH / 2 - 30),
          fontSize: 48, weight: FontWeight.w700, color: _subText);

      // Per-DAY card: no time-saved boast (owner request — the blue "~1h
      // saved" headline read as clutter on a day share). A quiet stop
      // count is all the footer says; the whole-trip Plan Card keeps its
      // time-saved stat. [timeSaved]/[lifetimeSaved] stay in the signature
      // for the share MESSAGE text, which still mentions the saving.
      _drawText(canvas, '$stops ${stops == 1 ? 'stop' : 'stops'}',
          const Offset(48, 528),
          fontSize: 28, weight: FontWeight.w700, color: _subText);

      // Wordmark + link.
      _drawText(canvas, 'VOYZA', const Offset(_w - 260, 516),
          fontSize: 34,
          weight: FontWeight.w900,
          color: _text,
          fontFamily: _displayFont,
          fontFamilyFallback: _displayFontFallback,
          letterSpacing: 3);
      _drawText(canvas, 'voyza.xtremon.com', const Offset(_w - 260, 560),
          fontSize: 20, weight: FontWeight.w500, color: _subText);

      final picture = recorder.endRecording();
      final img = await picture.toImage(_w.toInt(), _h.toInt());
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/voyza_route_card.png');
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      return file;
    } catch (e) {
      debugPrint('RouteShareCardService.renderCard: $e');
      return null;
    }
  }

  /// Renders the card and opens the OS share sheet. [anonymous] decides the
  /// link: authed users share their referral link (give-a-month-get-a-month
  /// rides along); anonymous users share the store link. When [tripId] is
  /// provided for an authed user, a wall-free public itinerary link (the
  /// `public-trip` edge function) is included too — the recipient gets real
  /// value with no account wall.
  Future<void> shareRouteCard({
    required List<LocationModel> originalOrder,
    required List<LocationModel> optimizedOrder,
    required Duration timeSaved,
    required bool anonymous,
    String? tripName,
    String? tripId,
    String? dayLabel,
  }) async {
    try {
      final lifetimeSaved = await TimeSavedLedgerService.instance.total();
      final file = await renderCard(
        originalOrder: originalOrder,
        optimizedOrder: optimizedOrder,
        timeSaved: timeSaved,
        tripName: tripName,
        dayLabel: dayLabel,
        lifetimeSaved: lifetimeSaved,
      );
      if (file == null) return;

      final link = await _audienceLink(anonymous: anonymous);

      String itinerary = '';
      if (!anonymous && tripId != null) {
        final publicLink = await _getOrCreatePublicLink(tripId);
        if (publicLink != null) itinerary = '\nFull itinerary: $publicLink';
      }

      final saved = timeSaved >= const Duration(minutes: 5)
          ? ' and saved ~${_formatDuration(timeSaved)} of travel time'
          : '';
      final text =
          'VoyZa put my ${optimizedOrder.length} stops in the smartest order$saved.$itinerary\n$link';

      await Share.shareXFiles([XFile(file.path)], text: text);
      AnalyticsService.instance.routeCardShared(anonymous: anonymous);
    } catch (e) {
      debugPrint('RouteShareCardService.shareRouteCard: $e');
    }
  }

  // ── Plan Card (social-currency flagship) ───────────────────────────────
  // The pre-trip "my plan is ready" artifact: 9:16, day-loop silhouettes as
  // the hero, an identity archetype as the headline, stats as garnish, a
  // roast line for self-aware voice, and the public trip link as the gift.
  // Research spec: marketing/social-currency-plan-card.md.

  static const double _pw = 1080;
  static const double _ph = 1920;

  /// Rule-based identity archetype from the plan's own traits. Deterministic,
  /// client-only — the label is the shareable unit (trait, not number).
  String planArchetype(List<LocationModel> places, int days) {
    if (places.isEmpty) return 'THE PLANNER FRIEND';
    final foodish = RegExp(
        r'market|caf[eé]|restaurant|food|bar|bakery|coffee|eat|kitchen',
        caseSensitive: false);
    final foodCount = places.where((p) => foodish.hasMatch(p.name)).length;
    if (places.length >= 5 && foodCount / places.length >= 0.4) {
      return 'THE TASTE ROUTER';
    }

    final byDay = <String, int>{};
    for (final p in places) {
      final d = p.scheduledDate;
      if (d == null) continue;
      final key = '${d.year}-${d.month}-${d.day}';
      byDay[key] = (byDay[key] ?? 0) + 1;
    }
    if (byDay.values.any((c) => c >= 6)) return 'THE DAY MAXIMIZER';

    var minLat = double.infinity, maxLat = -double.infinity;
    var minLng = double.infinity, maxLng = -double.infinity;
    for (final p in places) {
      final c = p.coordinates;
      if (c.latitude < minLat) minLat = c.latitude;
      if (c.latitude > maxLat) maxLat = c.latitude;
      if (c.longitude < minLng) minLng = c.longitude;
      if (c.longitude > maxLng) maxLng = c.longitude;
    }
    // ~degrees → km at mid latitudes; spread > ~50km = multi-area trip.
    final spreadKm = math.sqrt(math.pow((maxLat - minLat) * 111, 2) +
        math.pow((maxLng - minLng) * 85, 2));
    if (spreadKm > 50) return 'THE GROUND COVERER';

    if (days >= 4) return 'THE LONG HAULER';
    return 'THE PLANNER FRIEND';
  }

  static const _roastBank = <String>[
    '3 wrong turns will still happen. That\'s on you.',
    'This itinerary has been legally un-zig-zagged.',
    'Your past self would\'ve walked this route twice.',
    'Chaos had a plan. We had a better one.',
  ];

  /// Deterministic roast line per trip (stable across re-renders).
  String planRoastLine(String tripId) =>
      _roastBank[tripId.hashCode.abs() % _roastBank.length];

  /// Greedy nearest-neighbor ordering for a day's silhouette — approximates
  /// the optimized loop for DISPLAY (per-day optimized order isn't persisted).
  List<LatLng> _nnOrder(List<LatLng> points) {
    if (points.length <= 2) return points;
    final remaining = List<LatLng>.from(points);
    final ordered = <LatLng>[remaining.removeAt(0)];
    while (remaining.isNotEmpty) {
      final last = ordered.last;
      var bestI = 0;
      var bestD = double.infinity;
      for (var i = 0; i < remaining.length; i++) {
        final d = math.pow(remaining[i].latitude - last.latitude, 2) +
            math.pow(remaining[i].longitude - last.longitude, 2).toDouble();
        if (d < bestD) {
          bestD = d.toDouble();
          bestI = i;
        }
      }
      ordered.add(remaining.removeAt(bestI));
    }
    return ordered;
  }

  /// Renders the 9:16 Plan Card to a temp PNG. Returns null on any failure.
  Future<File?> renderPlanCard({
    required String tripName,
    required List<LocationModel> places,
    required String archetype,
    required Duration timeSaved,
    String? roastLine,
  }) async {
    try {
      // Group by day (date-only), sorted; skip unscheduled.
      final byDay = <DateTime, List<LatLng>>{};
      for (final p in places) {
        final d = p.scheduledDate;
        if (d == null) continue;
        final day = DateTime(d.year, d.month, d.day);
        byDay.putIfAbsent(day, () => []).add(p.coordinates);
      }
      if (byDay.isEmpty) return null;
      final dayKeys = byDay.keys.toList()..sort();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
          const Rect.fromLTWH(0, 0, _pw, _ph), Paint()..color = _bg);

      // Title.
      final title = tripName.trim().isEmpty
          ? 'MY TRIP, UNTANGLED'
          : '${tripName.trim().toUpperCase()}, UNTANGLED';
      _drawText(canvas, title, const Offset(60, 72),
          fontSize: 54, weight: FontWeight.w800, color: _text, maxWidth: 960);

      // Day panels — grid sized by day count, capped at 6 tiles.
      const gridTop = 190.0;
      const gridH = 950.0;
      const gridW = _pw - 120.0;
      final shown = dayKeys.take(6).toList();
      final cols = shown.length <= 2 ? 1 : 2;
      final rows = (shown.length + cols - 1) ~/ cols;
      const gap = 32.0;
      final cellW = (gridW - gap * (cols - 1)) / cols;
      final cellH = math.min(
          (gridH - gap * (rows - 1)) / rows, shown.length == 1 ? 700.0 : 470.0);
      for (var i = 0; i < shown.length; i++) {
        final r = i ~/ cols, c = i % cols;
        final rect = Rect.fromLTWH(
            60 + c * (cellW + gap), gridTop + r * (cellH + gap), cellW, cellH);
        _drawPanel(canvas, rect,
            label: 'DAY ${i + 1}',
            points: _nnOrder(byDay[shown[i]]!),
            line: _afterLine,
            numbered: false);
      }
      if (dayKeys.length > 6) {
        _drawText(canvas, '+${dayKeys.length - 6} more days',
            Offset(60, gridTop + rows * (cellH + gap) + 4),
            fontSize: 26, weight: FontWeight.w600, color: _subText);
      }

      // Identity headline + stats.
      final placeCount = places.length;
      _drawText(canvas, archetype, const Offset(60, 1240),
          fontSize: 52,
          weight: FontWeight.w800,
          color: _afterLine,
          maxWidth: 960);
      _drawText(
          canvas,
          '${dayKeys.length} ${dayKeys.length == 1 ? 'day' : 'days'} · '
          '$placeCount places',
          const Offset(60, 1330),
          fontSize: 36,
          weight: FontWeight.w700,
          color: _text,
          maxWidth: 960);
      var y = 1396.0;
      if (timeSaved >= const Duration(minutes: 5)) {
        _drawText(canvas, '~${_formatDuration(timeSaved)} of travel time saved',
            Offset(60, y),
            fontSize: 32, weight: FontWeight.w700, color: _afterLine);
        y += 62;
      }
      if (roastLine != null && roastLine.isNotEmpty) {
        _drawText(canvas, roastLine, Offset(60, y),
            fontSize: 28,
            weight: FontWeight.w500,
            color: _subText,
            maxWidth: 960);
      }

      // The gift + wordmark.
      _drawText(canvas, 'STEAL THIS PLAN ▸', const Offset(60, 1720),
          fontSize: 40, weight: FontWeight.w800, color: _afterLine);
      _drawText(
          canvas, 'full itinerary link in the caption', const Offset(60, 1780),
          fontSize: 26, weight: FontWeight.w500, color: _subText);
      _drawText(canvas, 'VOYZA', const Offset(_pw - 220, 1712),
          fontSize: 40,
          weight: FontWeight.w900,
          color: _text,
          fontFamily: _displayFont,
          fontFamilyFallback: _displayFontFallback,
          letterSpacing: 4);
      _drawText(canvas, 'voyza.xtremon.com', const Offset(_pw - 320, 1772),
          fontSize: 24, weight: FontWeight.w500, color: _subText);

      final picture = recorder.endRecording();
      final img = await picture.toImage(_pw.toInt(), _ph.toInt());
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/voyza_plan_card.png');
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      return file;
    } catch (e) {
      debugPrint('RouteShareCardService.renderPlanCard: $e');
      return null;
    }
  }

  /// Renders the Plan Card and opens the OS share sheet. Authed active-trip
  /// flow only (the public itinerary link IS the gift).
  Future<void> sharePlanCard({
    required String tripId,
    required String tripName,
    required List<LocationModel> places,
    required Duration timeSaved,
    required bool roastEnabled,
  }) async {
    try {
      final archetype = planArchetype(
          places,
          places
              .where((p) => p.scheduledDate != null)
              .map((p) {
                final d = p.scheduledDate!;
                return DateTime(d.year, d.month, d.day);
              })
              .toSet()
              .length);
      final file = await renderPlanCard(
        tripName: tripName,
        places: places,
        archetype: archetype,
        timeSaved: timeSaved,
        roastLine: roastEnabled ? planRoastLine(tripId) : null,
      );
      if (file == null) return;

      // Links intentionally omitted from this caption (owner's edit above).
      final dayCount = places
          .where((p) => p.scheduledDate != null)
          .map((p) {
            final d = p.scheduledDate!;
            return DateTime(d.year, d.month, d.day);
          })
          .toSet()
          .length;
      // final steal = publicLink != null ? '\nSteal it: $publicLink' : '';
      final text =
          'My ${tripName.trim()} plan is done — $dayCount ${dayCount == 1 ? 'day' : 'days'}, '
          '${places.length} places.';

      await Share.shareXFiles([XFile(file.path)], text: text);
      AnalyticsService.instance.planCardShared();
    } catch (e) {
      debugPrint('RouteShareCardService.sharePlanCard: $e');
    }
  }

  // ── Realistic map card ─────────────────────────────────────────────────
  // The share image travelers actually want: the REAL map with the route +
  // numbered markers (from GoogleMapController.takeSnapshot), not an abstract
  // silhouette. VoyZa branding + stats are composited over it.

  /// Composites branding over a live map snapshot into a share image shaped
  /// by [format] (9:16 story, 4:5 feed post).
  /// Returns PNG bytes, or null on failure so the caller can fall back to the
  /// silhouette card. Pure (no file I/O) so it's unit-testable.
  /// When [archetype] is supplied (the Plan Card moment) it becomes the
  /// headline — the identity is the shareable unit — with the trip name as a
  /// small kicker above it, and [roastLine] (if any) rides under the stats.
  /// Otherwise the headline is the plain "{TRIP}, OPTIMIZED".
  Future<Uint8List?> renderMapCard({
    required Uint8List mapBytes,
    required String tripName,
    required int stops,
    required Duration timeSaved,
    double distanceKm = 0,
    String? archetype,
    String? roastLine,
    // All-days mode: the card frames the WHOLE trip, so the stat line reads
    // "N days · M places" instead of the single-day stop count.
    int? daysCount,
    // Single-day shares: "Day 1 of the trip" — drawn as the small kicker
    // above the trip name, so a story viewer knows which day they're seeing.
    String? dayLabel,
    ShareCardFormat format = ShareCardFormat.story,
  }) async {
    try {
      final pw = format.width;
      final ph = format.height;
      final codec = await ui.instantiateImageCodec(mapBytes);
      final frame = await codec.getNextFrame();
      final map = frame.image;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(Rect.fromLTWH(0, 0, pw, ph), Paint()..color = _bg);

      // The real map is the hero — cover-fit it across the whole card, with
      // a UNIFORM whisper of treatment (owner-tuned): a light global blur +
      // a ~15% brand-navy veil over the entire image. Enough for the white
      // text to pop anywhere, while routes and markers stay clearly
      // readable — deliberately NOT the old bottom gradient band, which
      // read as a smeared frame.
      _drawImageCover(canvas, map, Rect.fromLTWH(0, 0, pw, ph),
          blurSigma: _mapBlurSigma);
      canvas.drawRect(Rect.fromLTWH(0, 0, pw, ph), Paint()..color = _mapVeil);

      // The text block is BOTTOM-ANCHORED: its last line always ends exactly
      // at ph - bottomReserve, whichever optional lines exist. For the story
      // format that reserve is the safe zone that survives Instagram's 4:5
      // feed center-crop and stays above the Stories reply bar. Line heights
      // are fontSize × 1.1 (the height multiplier in _drawText), exact for
      // these single-line painters, so the stack can be sized before drawing.
      // Sizes deliberately small and the whole block bottom-left-hugging:
      // the route image is the hero, the caption is a quiet signature.
      double lineH(double fontSize) => fontSize * 1.1;
      double soft(double fontSize) => fontSize * _textBlurFactor;
      final planMode = archetype != null && archetype.trim().isNotEmpty;
      final dayKicker = dayLabel != null && dayLabel.trim().isNotEmpty;
      final hasKicker = (planMode && tripName.trim().isNotEmpty) || dayKicker;
      final hasSaved = timeSaved >= const Duration(minutes: 5);
      final hasRoast = roastLine != null && roastLine.trim().isNotEmpty;
      double stack = lineH(38) + 14 + lineH(26) + 22 + lineH(34);
      if (hasKicker) stack += lineH(20) + 20;
      if (hasSaved) stack += 14 + lineH(24);
      if (hasRoast) stack += 12 + lineH(22);
      var y = ph - format.bottomReserve - stack;

      // Per-glyph shadows on top of the global veil above — no bottom
      // gradient band (it read as a smeared frame).
      const shadow = [
        Shadow(color: Color(0xCC000000), blurRadius: 14, offset: Offset(0, 2)),
      ];

      if (hasKicker) {
        // Small kicker above the identity headline: the trip name in plan
        // mode, "DAY 1 OF THE TRIP" on single-day shares.
        final kicker = planMode
            ? tripName.trim().toUpperCase()
            : dayLabel!.trim().toUpperCase();
        y += 20 +
            _drawText(canvas, kicker, Offset(60, y),
                fontSize: 20,
                weight: FontWeight.w700,
                color: _subText,
                maxWidth: 960,
                shadows: shadow,
                blurSigma: soft(20));
      }
      final title = planMode
          ? archetype.trim().toUpperCase()
          : (tripName.trim().isEmpty
              ? 'MY DAY'
              : tripName.trim().toUpperCase());
      y += 14 +
          _drawText(canvas, title, Offset(60, y),
              fontSize: 38,
              weight: FontWeight.w800,
              color: _text,
              maxWidth: 960,
              shadows: shadow,
              blurSigma: soft(38));

      final stat = <String>[
        if (daysCount != null) '$daysCount ${daysCount == 1 ? 'day' : 'days'}',
        daysCount != null
            ? '$stops ${stops == 1 ? 'place' : 'places'}'
            : '$stops ${stops == 1 ? 'stop' : 'stops'}',
        if (distanceKm > 0) '${distanceKm.toStringAsFixed(1)} km',
      ].join('  ·  ');
      y += _drawText(canvas, stat, Offset(60, y),
          fontSize: 26,
          weight: FontWeight.w700,
          color: _text,
          maxWidth: 960,
          shadows: shadow,
          blurSigma: soft(26));

      // Wordmark beneath the stat — white, with a touch more air above it so
      // it reads as a signature rather than another stat row. Display face +
      // heavy weight + wide tracking keep it a logotype, not body copy.
      y += 22;
      y += _drawText(canvas, 'VOYZA', Offset(60, y),
          fontSize: 34,
          weight: FontWeight.w900,
          color: _text,
          maxWidth: 960,
          shadows: shadow,
          fontFamily: _displayFont,
          fontFamilyFallback: _displayFontFallback,
          letterSpacing: 4,
          blurSigma: soft(34));

      if (hasSaved) {
        y += 14;
        y += _drawText(
            canvas,
            '~${_formatDuration(timeSaved)} of travel time saved',
            Offset(60, y),
            fontSize: 24,
            weight: FontWeight.w700,
            color: _afterLine,
            maxWidth: 960,
            shadows: shadow,
            blurSigma: soft(24));
      }

      // The roast line (Plan Card curation control) — self-aware voice.
      if (hasRoast) {
        y += 12;
        _drawText(canvas, '“${roastLine.trim()}”', Offset(60, y),
            fontSize: 22,
            weight: FontWeight.w600,
            color: _text,
            maxWidth: 960,
            shadows: shadow,
            blurSigma: soft(22));
      }

      final picture = recorder.endRecording();
      final img = await picture.toImage(pw.toInt(), ph.toInt());
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      return bytes?.buffer.asUint8List();
    } catch (e) {
      debugPrint('RouteShareCardService.renderMapCard: $e');
      return null;
    }
  }

  /// Cover-fits [image] into [dst]. [blurSigma] > 0 applies a gaussian blur
  /// while drawing (sigma in destination pixels; clamped tiling so edges
  /// don't fringe).
  void _drawImageCover(Canvas canvas, ui.Image image, Rect dst,
      {double blurSigma = 0}) {
    final iw = image.width.toDouble();
    final ih = image.height.toDouble();
    if (iw <= 0 || ih <= 0) return;
    final scale = math.max(dst.width / iw, dst.height / ih);
    final sw = dst.width / scale;
    final sh = dst.height / scale;
    final src = Rect.fromLTWH((iw - sw) / 2, (ih - sh) / 2, sw, sh);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    if (blurSigma > 0) {
      paint.imageFilter = ui.ImageFilter.blur(
          sigmaX: blurSigma, sigmaY: blurSigma, tileMode: TileMode.clamp);
    }
    canvas.drawImageRect(image, src, dst, paint);
  }

  /// Shares a realistic map card. [mapBytes] = the live map snapshot; when it's
  /// null or rendering fails, falls back to the silhouette route card so the
  /// user always gets a shareable image. [tripId] is null for anonymous users
  /// (no public itinerary link — just the map + store link).
  /// Shares an ALREADY-RENDERED map card (the preview-confirmed bytes — what
  /// the user approved is byte-for-byte what ships). Writes the temp file,
  /// puts the caption on the clipboard, opens the OS share sheet.
  /// [stopCount] is the single-day stop count used by the caption when not
  /// in all-days mode.
  Future<void> shareRenderedMapCard({
    required Uint8List png,
    required String? tripId,
    required String tripName,
    required int stopCount,
    required Duration timeSaved,
    required bool anonymous,
    String? archetype,
    // All-days mode: whole-trip framing. [daysCount]/[totalPlaces] replace
    // the single-day stop count in the caption.
    int? daysCount,
    int? totalPlaces,
    ShareCardFormat format = ShareCardFormat.story,
  }) async {
    try {
      final allTrip = daysCount != null && totalPlaces != null;

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/voyza_route_map_card_${format.name}.png');
      await file.writeAsBytes(png, flush: true);

      // final link = await _audienceLink(anonymous: anonymous);
      // String itinerary = '';
      // if (!anonymous && tripId != null) {
      //   final publicLink = await _getOrCreatePublicLink(tripId);
      //   if (publicLink != null) itinerary = '\nSteal it: $publicLink';
      // }
      final saved = timeSaved >= const Duration(minutes: 5)
          ? ' · ~${_formatDuration(timeSaved)} of travel time saved'
          : '';
      final planMode = archetype != null && archetype.trim().isNotEmpty;
      final String text;
      if (allTrip) {
        text = 'My ${tripName.trim()} plan — $daysCount '
            '${daysCount == 1 ? 'day' : 'days'}, $totalPlaces '
            '${totalPlaces == 1 ? 'place' : 'places'}$saved.';
      } else if (planMode) {
        text = 'My ${tripName.trim()} plan is ready — ${archetype.trim()}. '
            '$stopCount ${stopCount == 1 ? 'stop' : 'stops'}$saved.';
      } else {
        text = 'My ${tripName.trim()} route, optimized — '
            '$stopCount ${stopCount == 1 ? 'stop' : 'stops'}$saved.';
      }

      // Share the IMAGE alone and put the caption (with its links) on the
      // clipboard instead of in the intent. Targets like Facebook treat a
      // share carrying both a file and URL-bearing text as a LINK post — the
      // image never loads. File-only guarantees the card image lands
      // everywhere; the caption is one paste away (FB strips prefilled
      // captions by policy anyway, so nothing of value is lost there).
      await Clipboard.setData(ClipboardData(text: text));
      await Share.shareXFiles([XFile(file.path)],
          subject: '${tripName.trim()} — planned with VoyZa');
      AnalyticsService.instance
          .routeCardShared(anonymous: anonymous, format: format.name);
    } catch (e) {
      debugPrint('RouteShareCardService.shareRenderedMapCard: $e');
    }
  }

  /// Saves ALREADY-RENDERED card bytes (the preview-confirmed image) to
  /// the device's photo library. Returns true on success; false covers
  /// GalException (e.g. photo-library access denied) and I/O failures.
  Future<bool> saveRenderedMapCard(
    Uint8List png, {
    ShareCardFormat format = ShareCardFormat.story,
  }) async {
    try {
      // Android 7–9 need the runtime storage grant and get NO prompt from
      // putImage itself — without this request the save button was a
      // permanent dead end there.
      if (!await Gal.hasAccess()) {
        final granted = await Gal.requestAccess();
        if (!granted) return false;
      }
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/voyza_card_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(png, flush: true);
      await Gal.putImage(file.path);
      AnalyticsService.instance.routeCardSaved(format: format.name);
      return true;
    } catch (e) {
      debugPrint('RouteShareCardService.saveRenderedMapCard: $e');
      return false;
    }
  }

  /// Saves an already-written image file to the photo library (used by the
  /// silhouette fallback when the live map snapshot fails). Same permission
  /// handling as [saveRenderedMapCard].
  Future<bool> saveImageFileToPhotos(File file) async {
    try {
      if (!await Gal.hasAccess()) {
        final granted = await Gal.requestAccess();
        if (!granted) return false;
      }
      await Gal.putImage(file.path);
      return true;
    } catch (e) {
      debugPrint('RouteShareCardService.saveImageFileToPhotos: $e');
      return false;
    }
  }

  /// Referral link for authed sharers (the give-a-month offer rides along);
  /// store link for anonymous.
  Future<String> _audienceLink({required bool anonymous}) async {
    if (!anonymous) {
      final code = await ReferralService.instance.getOrCreateMyCode();
      if (code != null) return 'https://voyza.xtremon.com/r/$code';
    }
    return _storeLink;
  }

  /// Renders the post-trip recap card ("the trip, by the numbers") to a temp
  /// PNG. Returns null on any failure.
  Future<File?> renderRecapCard({
    required String tripName,
    required int days,
    required int places,
    required Duration timeSaved,
  }) async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(const Rect.fromLTWH(0, 0, _w, _h), Paint()..color = _bg);

      _drawText(canvas, tripName.trim().isEmpty ? 'My trip' : tripName.trim(),
          const Offset(48, 48),
          fontSize: 48, weight: FontWeight.w800, color: _text, maxWidth: 1100);
      _drawText(canvas, 'THE TRIP, BY THE NUMBERS', const Offset(48, 120),
          fontSize: 22, weight: FontWeight.w600, color: _subText);

      // Stat columns.
      final stats = <(String, String)>[
        ('$days', days == 1 ? 'day' : 'days'),
        ('$places', places == 1 ? 'place' : 'places'),
        if (timeSaved >= const Duration(minutes: 5))
          ('~${_formatDuration(timeSaved)}', 'travel time saved'),
      ];
      final colW = (_w - 96) / stats.length;
      for (var i = 0; i < stats.length; i++) {
        final x = 48 + colW * i;
        _drawText(canvas, stats[i].$1, Offset(x, 240),
            fontSize: 96,
            weight: FontWeight.w800,
            color: i == stats.length - 1 && stats.length == 3
                ? _afterLine
                : _text);
        _drawText(canvas, stats[i].$2, Offset(x, 372),
            fontSize: 26, weight: FontWeight.w600, color: _subText);
      }

      _drawText(canvas, 'Planned & optimized with VoyZa', const Offset(48, 520),
          fontSize: 30, weight: FontWeight.w700, color: _afterLine);

      _drawText(canvas, 'VOYZA', const Offset(_w - 260, 516),
          fontSize: 34,
          weight: FontWeight.w900,
          color: _text,
          fontFamily: _displayFont,
          fontFamilyFallback: _displayFontFallback,
          letterSpacing: 3);
      _drawText(canvas, 'voyza.xtremon.com', const Offset(_w - 260, 560),
          fontSize: 20, weight: FontWeight.w500, color: _subText);

      final picture = recorder.endRecording();
      final img = await picture.toImage(_w.toInt(), _h.toInt());
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/voyza_trip_recap.png');
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      return file;
    } catch (e) {
      debugPrint('RouteShareCardService.renderRecapCard: $e');
      return null;
    }
  }

  /// Renders the recap card and opens the OS share sheet. Rides on an
  /// already-happening ritual (posting trip photos at T+1): the card is the
  /// behavioral residue, the itinerary link the wall-free recipient path.
  Future<void> shareRecapCard({
    required String tripName,
    required int days,
    required int places,
    required Duration timeSaved,
    required bool anonymous,
    String? tripId,
  }) async {
    try {
      final file = await renderRecapCard(
        tripName: tripName,
        days: days,
        places: places,
        timeSaved: timeSaved,
      );
      if (file == null) return;

      // final link = await _audienceLink(anonymous: anonymous);
      // String itinerary = '';
      if (!anonymous && tripId != null) {
        // final publicLink = await _getOrCreatePublicLink(tripId);
        // if (publicLink != null) itinerary = '\nFull itinerary: $publicLink';
      }

      final saved = timeSaved >= const Duration(minutes: 5)
          ? ' · ~${_formatDuration(timeSaved)} of travel time saved'
          : '';
      final text =
          '$tripName, by the numbers — $days ${days == 1 ? 'day' : 'days'} · '
          '$places ${places == 1 ? 'place' : 'places'}$saved. '
          'Planned with VoyZa.';

      await Share.shareXFiles([XFile(file.path)], text: text);
      AnalyticsService.instance.tripRecapShared();
    } catch (e) {
      debugPrint('RouteShareCardService.shareRecapCard: $e');
    }
  }

  /// Reuses an existing non-revoked share token for [tripId] or mints one
  /// (RLS: owner-only). Returns the public page URL, or null on any failure
  /// (share proceeds without the itinerary link — never blocks the sheet).
  Future<String?> _getOrCreatePublicLink(String tripId) async {
    try {
      final client = SupabaseService.instance.client;
      if (client.auth.currentSession == null) return null;

      final existing = await client
          .from('trip_shares')
          .select('token')
          .eq('trip_id', tripId)
          .isFilter('revoked_at', null)
          .limit(1)
          .maybeSingle();
      String? token = existing?['token'] as String?;

      if (token == null) {
        final inserted = await client
            .from('trip_shares')
            .insert({
              'trip_id': tripId,
              'created_by': client.auth.currentUser!.id,
            })
            .select('token')
            .single();
        token = inserted['token'] as String?;
      }
      if (token == null) return null;
      // Branded links win trust + clicks: a raw *.supabase.co URL reads as
      // phishing in a chat. Flip _brandedPublicTripBase on ONLY after the
      // site has a server-side 301/302 rule
      //   /t/*  ->  $SUPABASE_URL/functions/v1/public-trip?t=<splat>
      // (same host that already serves /r/<code> referral links). A JS/meta
      // redirect is NOT enough — chat unfurlers won't follow it and link
      // previews would break. Until then we share the function URL directly:
      // ugly but functional, and no security difference (the project ref is
      // already public in the app binary; the token is the capability).
      if (_brandedPublicTripBase != null) {
        return '$_brandedPublicTripBase$token';
      }
      final supabaseUrl = dotenv.env['SUPABASE_URL'] ?? '';
      if (supabaseUrl.isEmpty) return null;
      return '$supabaseUrl/functions/v1/public-trip?t=$token';
    } catch (e) {
      debugPrint('RouteShareCardService._getOrCreatePublicLink: $e');
      return null;
    }
  }

  /// Branded public-trip links. REQUIRES the voyza.xtremon.com `/t/*`
  /// server-side redirect rule to be deployed (see landing/_redirects) —
  /// without it these links 404. Flipped from the raw
  /// `$SUPABASE_URL/functions/v1/public-trip?t=` form: no security change
  /// (the token was always the capability; the project ref ships in the app
  /// binary), but a branded domain earns the click instead of reading as
  /// phishing.
  static const String? _brandedPublicTripBase = 'https://voyza.xtremon.com/t/';

  static String get _storeLink => Platform.isAndroid
      ? 'https://play.google.com/store/apps/details?id=com.superiordev.voyza'
      : 'https://apps.apple.com/app/id6758559163';

  // ── drawing helpers ────────────────────────────────────────────────────

  void _drawPanel(
    Canvas canvas,
    Rect rect, {
    required String label,
    required List<LatLng> points,
    required Color line,
    required bool numbered,
  }) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(24));
    canvas.drawRRect(rrect, Paint()..color = _panel);

    _drawText(canvas, label, Offset(rect.left + 24, rect.top + 18),
        fontSize: 20, weight: FontWeight.w700, color: _subText);

    // Project lat/lng into the panel's plot area (padding for dots/labels).
    final plot = Rect.fromLTRB(
        rect.left + 56, rect.top + 72, rect.right - 56, rect.bottom - 44);
    final projected = _project(points, plot);

    final linePaint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()..moveTo(projected.first.dx, projected.first.dy);
    for (final p in projected.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, linePaint);

    for (var i = 0; i < projected.length; i++) {
      final p = projected[i];
      canvas.drawCircle(p, numbered ? 16 : 9, Paint()..color = line);
      canvas.drawCircle(
          p,
          numbered ? 16 : 9,
          Paint()
            ..color = _bg
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3);
      if (numbered) {
        _drawText(canvas, '${i + 1}', Offset(p.dx, p.dy),
            fontSize: 17, weight: FontWeight.w800, color: _bg, centered: true);
      }
    }
  }

  /// Fits [points] into [plot] preserving aspect ratio. Guards the degenerate
  /// single-point / zero-extent cases.
  List<Offset> _project(List<LatLng> points, Rect plot) {
    var minLat = points.first.latitude, maxLat = points.first.latitude;
    var minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    final latExtent = math.max(maxLat - minLat, 1e-6);
    final lngExtent = math.max(maxLng - minLng, 1e-6);
    final scale = math.min(plot.width / lngExtent, plot.height / latExtent);
    final drawnW = lngExtent * scale;
    final drawnH = latExtent * scale;
    final ox = plot.left + (plot.width - drawnW) / 2;
    final oy = plot.top + (plot.height - drawnH) / 2;
    return points
        .map((p) => Offset(
              ox + (p.longitude - minLng) * scale,
              // Latitude grows north; canvas y grows down.
              oy + (maxLat - p.latitude) * scale,
            ))
        .toList();
  }

  /// Draws one line and RETURNS its laid-out height, so callers can flow
  /// stacked lines instead of hardcoding every y offset.
  ///
  /// [fontFamily] / [fontFamilyFallback] pick a typeface (see
  /// [_displayFont] for the brand display stack); [letterSpacing] gives
  /// wordmarks their tracking.
  double _drawText(
    Canvas canvas,
    String text,
    Offset at, {
    required double fontSize,
    required FontWeight weight,
    required Color color,
    double maxWidth = 600,
    bool centered = false,
    List<Shadow>? shadows,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    double? letterSpacing,
    // > 0 softens the glyphs with a gaussian blur of that sigma (px). Done
    // via a foreground paint because TextStyle forbids color+foreground
    // together — the paint carries the color instead.
    double blurSigma = 0,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: blurSigma > 0 ? null : color,
          foreground: blurSigma > 0
              ? (Paint()
                ..color = color
                ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma))
              : null,
          fontSize: fontSize,
          fontWeight: weight,
          height: 1.1,
          shadows: shadows,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          letterSpacing: letterSpacing,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    final offset = centered
        ? Offset(at.dx - painter.width / 2, at.dy - painter.height / 2)
        : at;
    painter.paint(canvas, offset);
    return painter.height;
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    if (h > 0) return '${h}h';
    return '${m}m';
  }
}
