import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:voyza/core/theme.dart';
import '../utils/marker_utils.dart';

class MarkerCacheService {
  static final MarkerCacheService _instance = MarkerCacheService._internal();
  factory MarkerCacheService() => _instance;
  MarkerCacheService._internal();

  final LinkedHashMap<String, MarkerBitmapResult> _cache = LinkedHashMap();
  // 400, not 100: one busy day is ~40 name-labeled pins × light/dark ×
  // renumbering after each optimize. At 100 the LRU thrashed and pins
  // regenerated on every revisit; bitmaps are tens of KB, so 400 is ~MBs.
  static const int _maxCacheSize = 400;
  MarkerBitmapResult? _currentLocationIcon;
  MarkerBitmapResult? _currentLocationHeadingIcon;
  bool _isPrewarming = false;
  bool _isPrewarmed = false;

  /// PERFORMANCE: Lazily pre-generate common markers in background
  /// This runs without blocking and improves UX for subsequent marker loads
  /// Called automatically on first marker request
  void prewarmCacheInBackground() {
    if (_isPrewarmed || _isPrewarming) return;
    _isPrewarming = true;

    // Run prewarming in background without blocking
    Future(() async {
      try {
        debugPrint('🔥 Prewarming marker cache in background...');

        // Pre-generate only the most commonly used markers (2-3 markers)
        // to minimize initial load while still providing benefit
        await Future.wait([
          getCurrentLocationMarker(),
          getCurrentLocationHeadingMarker(),
          getLegStartMarker(),
          getLegEndMarker(),
        ]);

        _isPrewarmed = true;
        debugPrint('✅ Marker cache prewarmed with ${_cache.length} markers');
      } catch (e) {
        debugPrint('⚠️ Error prewarming marker cache: $e');
      } finally {
        _isPrewarming = false;
      }
    });
  }

  String _generateKey({
    required String type,
    int? number,
    String? name,
    Color? backgroundColor,
    Color? textColor,
  }) {
    if (type == 'current_location') {
      return 'current_location_${backgroundColor?.value}';
    }
    return '${type}_${number}_${name}_${backgroundColor?.value}_${textColor?.value}';
  }

  Future<MarkerBitmapResult> getCurrentLocationMarker({
    Color backgroundColor = const Color(0xFF00D4FF),
  }) async {
    // Trigger background prewarming on first marker access
    prewarmCacheInBackground();

    if (_currentLocationIcon != null) {
      return _currentLocationIcon!;
    }

    final key = _generateKey(
      type: 'current_location',
      backgroundColor: backgroundColor,
    );

    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    final icon = await MarkerUtils.getCurrentLocationMarker(
      backgroundColor: backgroundColor,
    );

    // Center anchor for location dot
    final result = MarkerBitmapResult(icon, const Offset(0.5, 0.5));

    _currentLocationIcon = result;
    _addToCache(key, result);
    return result;
  }

  /// Heading-beam variant of the current-location dot. Same dot geometry,
  /// plus the compass wedge; the beam is aimed via Marker.rotation so this
  /// bitmap is generated once and never again.
  Future<MarkerBitmapResult> getCurrentLocationHeadingMarker({
    Color backgroundColor = const Color(0xFF00D4FF),
  }) async {
    prewarmCacheInBackground();

    if (_currentLocationHeadingIcon != null) {
      return _currentLocationHeadingIcon!;
    }

    final key = 'current_location_heading_${backgroundColor.toARGB32()}';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    final icon = await MarkerUtils.getCurrentLocationHeadingMarker(
      backgroundColor: backgroundColor,
    );

    // Dot is centered in the canvas → center anchor is both the dot's
    // position AND the rotation pivot, so the beam sweeps around the dot.
    final result = MarkerBitmapResult(icon, const Offset(0.5, 0.5));

    _currentLocationHeadingIcon = result;
    _addToCache(key, result);
    return result;
  }

  Future<MarkerBitmapResult> getNumberedMarker({
    required int number,
    required String name,
    Color backgroundColor = const Color(0xFFFF6B6B),
    Color textColor = Colors.white,
    required bool isDarkMode,
    bool isStart = false,
    bool isSkipped = false,
    bool isDone = false,
  }) async {
    // Trigger background prewarming on first marker access
    prewarmCacheInBackground();

    final key =
        'numbered_${number}_${name}_${backgroundColor.value}_${textColor.value}_${isDarkMode}_${isSkipped}_${isDone}_$isStart';

    if (_cache.containsKey(key)) {
      _moveToEnd(key);
      return _cache[key]!;
    }

    final result = await MarkerUtils.getCustomMarkerBitmap(
      isStart: isStart,
      number: number,
      name: name,
      backgroundColor: backgroundColor,
      textColor: textColor,
      isDarkMode: isDarkMode,
      isSkipped: isSkipped,
      isDone: isDone,
    );

    _addToCache(key, result);
    return result;
  }

  Future<MarkerBitmapResult> getLegStartMarker() async {
    const key = 'leg_start_marker';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }
    final icon = await MarkerUtils.getLegMarkerBitmap(
      color: Colors.green.shade400,
      icon: Icons.flag_circle,
    );
    final result = MarkerBitmapResult(icon, const Offset(0.5, 0.5));
    _addToCache(key, result);
    return result;
  }

  Future<MarkerBitmapResult> getLegEndMarker() async {
    const key = 'leg_end_marker';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }
    final icon = await MarkerUtils.getLegMarkerBitmap(
      color: AppTheme.accentColor,
      icon: Icons.location_on,
    );
    final result = MarkerBitmapResult(icon, const Offset(0.5, 0.5));
    _addToCache(key, result);
    return result;
  }

  Future<MarkerBitmapResult> getDestinationMarker() async {
    const key = 'destination_marker';
    if (_cache.containsKey(key)) {
      _moveToEnd(key);
      return _cache[key]!;
    }

    final icon = await MarkerUtils.getDestinationMarkerBitmap(
      color: AppTheme.accentColor,
      size: 100.0,
    );

    // Flag pole bottom is roughly at (0.1, 0.9) based on drawing commands
    final result = MarkerBitmapResult(icon, const Offset(0.1, 0.9));

    _addToCache(key, result);
    return result;
  }

  Future<MarkerBitmapResult> getDistanceAndMapsMarker(
      String distanceLabel) async {
    final key = 'distance_maps_$distanceLabel';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    final result = await MarkerUtils.getDistanceAndMapsMarker(distanceLabel);
    _addToCache(key, result);
    return result;
  }

  /// Cached per distance+duration pair — the label is baked into the
  /// bitmap, so each distinct pair is its own image.
  Future<MarkerBitmapResult> getRouteLegChipMarker({
    required String distanceLabel,
    String? durationLabel,
  }) async {
    final key = 'leg_chip_${distanceLabel}_${durationLabel ?? ''}';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    final result = await MarkerUtils.getRouteLegChipMarker(
      distanceLabel: distanceLabel,
      durationLabel: durationLabel,
    );
    _addToCache(key, result);
    return result;
  }

  Future<MarkerBitmapResult> getGrabButtonMarker() async {
    const key = 'grab_button_v2';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    final result = await MarkerUtils.getGrabButtonMarker();
    _addToCache(key, result);
    return result;
  }

  Future<MarkerBitmapResult> getRouteInfoMarker({
    required String duration,
    required String distance,
    bool isHighlighted = false,
  }) async {
    final key = 'route_info_${duration}_${distance}_$isHighlighted';
    if (_cache.containsKey(key)) {
      _moveToEnd(key);
      return _cache[key]!;
    }

    final icon = await MarkerUtils.getRouteInfoMarker(
      duration: duration,
      distance: distance,
      isHighlighted: isHighlighted,
      backgroundColor: const Color(0xFF1A1A2E),
      primaryColor: AppTheme.primaryColor,
      accentColor: AppTheme.accentColor,
    );

    final result = MarkerBitmapResult(icon, const Offset(0.5, 0.5));

    _addToCache(key, result);
    return result;
  }

  void _addToCache(String key, MarkerBitmapResult result) {
    if (_cache.length >= _maxCacheSize) {
      final firstKey = _cache.keys.first;
      _cache.remove(firstKey);
    }
    _cache[key] = result;
  }

  void _moveToEnd(String key) {
    final value = _cache.remove(key);
    if (value != null) {
      _cache[key] = value;
    }
  }

  void clearCache() {
    _cache.clear();
    _currentLocationIcon = null;
  }

  int get cacheSize => _cache.length;
}
