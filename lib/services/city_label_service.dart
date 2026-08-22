import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:hive/hive.dart';

import 'places_service.dart';

/// Names auto-detected city clusters ("Taipei", "Tainan") for the Auto-plan
/// preview. Labels are DISPLAY-ONLY — never persisted onto any model.
///
/// One reverse geocode per ~11 km grid cell, cached forever in Hive (city
/// names don't move): a preview of a 5-city trip costs at most 5 calls the
/// first time and zero afterward. Offline / API failure returns null — the
/// caller falls back to "Around <nearest place name>".
class CityLabelService {
  CityLabelService._();
  static final CityLabelService instance = CityLabelService._();

  static const _boxName = 'city_labels';
  Box<String>? _box;

  Future<Box<String>> _ensureBox() async =>
      _box ??= Hive.isBoxOpen(_boxName)
          ? Hive.box<String>(_boxName)
          : await Hive.openBox<String>(_boxName);

  /// ~0.1° grid (≈11 km) — every point of a metro shares one cache entry.
  String _gridKey(double lat, double lng) =>
      '${lat.toStringAsFixed(1)},${lng.toStringAsFixed(1)}';

  /// Strips noise so "Taipei City" and "台北市" read as the city name.
  String _clean(String raw) {
    var s = raw.trim();
    for (final suffix in [' City', ' city', '市', ' Municipality']) {
      if (s.length > suffix.length && s.endsWith(suffix)) {
        s = s.substring(0, s.length - suffix.length);
        break;
      }
    }
    return s;
  }

  Future<String?> labelFor(double lat, double lng) async {
    try {
      final box = await _ensureBox();
      final key = _gridKey(lat, lng);
      final cached = box.get(key);
      if (cached != null) return cached.isEmpty ? null : cached;

      final raw =
          await PlacesService.getLocalityFromCoordinates(LatLng(lat, lng));
      final label = raw == null ? null : _clean(raw);
      // Cache misses as '' too — a centroid in the ocean shouldn't re-query
      // every preview.
      await box.put(key, label ?? '');
      return label;
    } catch (e) {
      debugPrint('CityLabelService: $e');
      return null;
    }
  }
}
