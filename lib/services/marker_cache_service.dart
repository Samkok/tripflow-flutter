import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:voyza/core/theme.dart';
import '../utils/marker_utils.dart';

class MarkerCacheService {
  static final MarkerCacheService _instance = MarkerCacheService._internal();
  factory MarkerCacheService() => _instance;
  MarkerCacheService._internal();

  final LinkedHashMap<String, MarkerBitmapResult> _cache = LinkedHashMap();
  static const int _maxCacheSize = 100;
  MarkerBitmapResult? _currentLocationIcon;
  bool _isPrewarmed = false;

  /// PERFORMANCE: Pre-generate common markers to avoid async delays on first use
  /// Call this during app initialization for better UX
  Future<void> prewarmCache() async {
    if (_isPrewarmed) return;

    print('🔥 Prewarming marker cache...');

    // Pre-generate current location marker
    await getCurrentLocationMarker();

    // Pre-generate numbered markers 1-10 (covers most common use cases)
    // This prevents the first location additions from being slow
    final prewarmFutures = <Future>[];
    for (int i = 1; i <= 10; i++) {
      prewarmFutures.add(
        getNumberedMarker(
          number: i,
          name: 'Location $i',
          backgroundColor: AppTheme.accentColor,
          textColor: Colors.white,
          isDarkMode: false, // or true, for prewarming
        ),
      );
    }

    // Pre-generate leg markers
    prewarmFutures.add(getLegStartMarker());
    prewarmFutures.add(getLegEndMarker());

    await Future.wait(prewarmFutures);
    _isPrewarmed = true;
    print('✅ Marker cache prewarmed with ${_cache.length} markers');
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

  Future<MarkerBitmapResult> getNumberedMarker({
    required int number,
    required String name,
    Color backgroundColor = const Color(0xFFFF6B6B),
    Color textColor = Colors.white,
    required bool isDarkMode,
    bool isStart = false,
    bool isSkipped = false, // Add this parameter
  }) async {
    final key =
        'numbered_${number}_${name}_${backgroundColor.value}_${textColor.value}_${isDarkMode}_${isSkipped}_$isStart';

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
      isSkipped: isSkipped, // Pass the skipped status
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

  Future<MarkerBitmapResult> getGoogleMapsButtonMarker() async {
    const key =
        'google_maps_button_marker_v2'; // Versioned to force cache refresh
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    final result = await MarkerUtils.getGoogleMapsButtonMarker();
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
