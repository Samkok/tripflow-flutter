import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/location_model.dart';
import 'analytics_service.dart';
import 'referral_service.dart';
import 'supabase_service.dart';

/// Renders and shares the branded before/after route card — the artifact that
/// lets the optimize "aha" leave the app (Contagious: observable usage +
/// behavioral residue). Stylized polyline diagrams, not map tiles: offline-safe,
/// distinctive, and legally clean.
///
/// Layout (1200×630, social-preview ratio):
///   [ BEFORE panel ]  [ AFTER panel ]
///   headline stat ("~1h 40m of backtracking saved") + VoyZa wordmark/link
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

  /// Renders the card to a temp PNG. Returns null on any failure.
  Future<File?> renderCard({
    required List<LocationModel> originalOrder,
    required List<LocationModel> optimizedOrder,
    required Duration timeSaved,
    String? tripName,
  }) async {
    try {
      if (optimizedOrder.length < 2) return null;
      final before = (originalOrder.length >= 2 ? originalOrder : optimizedOrder)
          .map((l) => l.coordinates)
          .toList();
      final after = optimizedOrder.map((l) => l.coordinates).toList();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      // Background.
      canvas.drawRect(
          const Rect.fromLTWH(0, 0, _w, _h), Paint()..color = _bg);

      // Title.
      final stops = optimizedOrder.length;
      final title = (tripName != null && tripName.trim().isNotEmpty)
          ? tripName.trim()
          : 'My $stops-stop day, untangled';
      _drawText(canvas, title, const Offset(48, 40),
          fontSize: 40, weight: FontWeight.w800, color: _text, maxWidth: 900);

      // Panels.
      const panelTop = 120.0;
      const panelH = 360.0;
      const panelW = 520.0;
      const leftX = 48.0;
      const rightX = _w - 48.0 - panelW;
      _drawPanel(canvas, const Rect.fromLTWH(leftX, panelTop, panelW, panelH),
          label: 'BEFORE', points: before, line: _beforeLine, numbered: false);
      _drawPanel(canvas, const Rect.fromLTWH(rightX, panelTop, panelW, panelH),
          label: 'AFTER — OPTIMIZED',
          points: after,
          line: _afterLine,
          numbered: true);

      // Arrow between panels.
      _drawText(canvas, '→', Offset(_w / 2 - 18, panelTop + panelH / 2 - 30),
          fontSize: 48, weight: FontWeight.w700, color: _subText);

      // Headline stat.
      final stat = timeSaved >= const Duration(minutes: 5)
          ? '~${_formatDuration(timeSaved)} of backtracking saved'
          : '$stops stops, zero backtracking';
      _drawText(canvas, stat, const Offset(48, 520),
          fontSize: 40, weight: FontWeight.w800, color: _afterLine);

      // Wordmark + link.
      _drawText(canvas, 'VoyZa', const Offset(_w - 260, 516),
          fontSize: 34, weight: FontWeight.w800, color: _text);
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
  }) async {
    try {
      final file = await renderCard(
        originalOrder: originalOrder,
        optimizedOrder: optimizedOrder,
        timeSaved: timeSaved,
        tripName: tripName,
      );
      if (file == null) return;

      String link;
      if (!anonymous) {
        final code = await ReferralService.instance.getOrCreateMyCode();
        link = code != null
            ? 'https://voyza.xtremon.com/r/$code'
            : _storeLink;
      } else {
        link = _storeLink;
      }

      String itinerary = '';
      if (!anonymous && tripId != null) {
        final publicLink = await _getOrCreatePublicLink(tripId);
        if (publicLink != null) itinerary = '\nFull itinerary: $publicLink';
      }

      final saved = timeSaved >= const Duration(minutes: 5)
          ? ' and saved ~${_formatDuration(timeSaved)} of backtracking'
          : '';
      final text =
          'VoyZa put my ${optimizedOrder.length} stops in the smartest order$saved.$itinerary\n$link';

      await Share.shareXFiles([XFile(file.path)], text: text);
      AnalyticsService.instance.routeCardShared(anonymous: anonymous);
    } catch (e) {
      debugPrint('RouteShareCardService.shareRouteCard: $e');
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
      final supabaseUrl = dotenv.env['SUPABASE_URL'] ?? '';
      if (supabaseUrl.isEmpty) return null;
      return '$supabaseUrl/functions/v1/public-trip?t=$token';
    } catch (e) {
      debugPrint('RouteShareCardService._getOrCreatePublicLink: $e');
      return null;
    }
  }

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
    final plot = Rect.fromLTRB(rect.left + 56, rect.top + 72, rect.right - 56,
        rect.bottom - 44);
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
            fontSize: 17,
            weight: FontWeight.w800,
            color: _bg,
            centered: true);
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
    final scale =
        math.min(plot.width / lngExtent, plot.height / latExtent);
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

  void _drawText(
    Canvas canvas,
    String text,
    Offset at, {
    required double fontSize,
    required FontWeight weight,
    required Color color,
    double maxWidth = 600,
    bool centered = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: weight,
          height: 1.1,
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
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    if (h > 0) return '${h}h';
    return '${m}m';
  }
}
