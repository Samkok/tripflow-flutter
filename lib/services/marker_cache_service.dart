import 'dart:collection';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/material.dart';
import 'package:tripflow/core/theme.dart';
import '../utils/marker_utils.dart';

class MarkerCacheService {
  static final MarkerCacheService _instance = MarkerCacheService._internal();
  factory MarkerCacheService() => _instance;
  MarkerCacheService._internal();

  final LinkedHashMap<String, BitmapDescriptor> _cache = LinkedHashMap();
  static const int _maxCacheSize = 100;
  BitmapDescriptor? _currentLocationIcon;
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

  Future<BitmapDescriptor> getCurrentLocationMarker({
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
      _currentLocationIcon = _cache[key]!;
      return _currentLocationIcon!;
    }

    final icon = await MarkerUtils.getCurrentLocationMarker(
      backgroundColor: backgroundColor,
    );

    _currentLocationIcon = icon;
    _addToCache(key, icon);
    return icon;
  }

  Future<BitmapDescriptor> getNumberedMarker({
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

    final icon = await MarkerUtils.getCustomMarkerBitmap(
      isStart: isStart,
      number: number,
      name: name,
      backgroundColor: backgroundColor,
      textColor: textColor,
      isDarkMode: isDarkMode,
      isSkipped: isSkipped, // Pass the skipped status
    );

    _addToCache(key, icon);
    return icon;
  }

  Future<BitmapDescriptor> getLegStartMarker() async {
    const key = 'leg_start_marker';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }
    final icon = await MarkerUtils.getLegMarkerBitmap(
      color: Colors.green.shade400,
      icon: Icons.flag_circle,
    );
    _addToCache(key, icon);
    return icon;
  }

  Future<BitmapDescriptor> getLegEndMarker() async {
    const key = 'leg_end_marker';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }
    final icon = await MarkerUtils.getLegMarkerBitmap(
      color: AppTheme.accentColor,
      icon: Icons.location_on,
    );
    _addToCache(key, icon);
    return icon;
  }

  Future<BitmapDescriptor> getDestinationMarker() async {
    const key = 'destination_marker';
    if (_cache.containsKey(key)) {
      _moveToEnd(key);
      return _cache[key]!;
    }

    final icon = await MarkerUtils.getDestinationMarkerBitmap(
      color: AppTheme.accentColor,
      size: 100.0,
    );

    _addToCache(key, icon);
    return icon;
  }

  Future<BitmapDescriptor> getRouteInfoMarker({
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

    _addToCache(key, icon);
    return icon;
  }

  void _addToCache(String key, BitmapDescriptor icon) {
    if (_cache.length >= _maxCacheSize) {
      final firstKey = _cache.keys.first;
      _cache.remove(firstKey);
    }
    _cache[key] = icon;
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
