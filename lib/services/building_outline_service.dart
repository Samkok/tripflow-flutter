import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'api_service.dart';

/// The footprint of the building (or grounds) a place occupies, as Google
/// draws it when the place is selected in Google Maps, plus the entrances
/// Google knows for it.
class BuildingOutline {
  const BuildingOutline({
    required this.placeId,
    required this.rings,
    required this.entrances,
  });

  final String placeId;

  /// Outer rings of the footprint, one per building part. Holes are
  /// dropped: a tinted courtyard reads fine and costs nothing.
  final List<List<LatLng>> rings;

  final List<LatLng> entrances;

  bool get isEmpty => rings.isEmpty;
}

/// Reads a SearchDestinations response (Geocoding API v4) into a
/// [BuildingOutline]. The primary place's own footprint when it IS a
/// building or grounds (a shop with its own building, a park); otherwise
/// the building that contains it (a shop inside a mall gets the mall), and
/// failing that the grounds it sits on. Null when nothing has a footprint.
BuildingOutline? parseBuildingOutline(
    String placeId, Map<String, dynamic> json) {
  final destinations = json['destinations'] as List?;
  if (destinations == null || destinations.isEmpty) return null;
  final destination = destinations.first as Map<String, dynamic>;

  List<List<LatLng>>? ringsOf(Map<String, dynamic>? place, Set<String> types) {
    if (place == null) return null;
    if (!types.contains(place['structureType'] as String?)) return null;
    final rings = _ringsFromDisplayPolygon(place['displayPolygon']);
    return rings.isEmpty ? null : rings;
  }

  final primary = destination['primary'] as Map<String, dynamic>?;
  final containing = ((destination['containingPlaces'] as List?) ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();

  var rings = ringsOf(primary, const {'BUILDING', 'GROUNDS'});
  if (rings == null) {
    for (final types in const [
      {'BUILDING'},
      {'GROUNDS'},
    ]) {
      for (final place in containing) {
        rings = ringsOf(place, types);
        if (rings != null) break;
      }
      if (rings != null) break;
    }
  }
  if (rings == null) return null;

  final entrances = <LatLng>[];
  for (final e in (destination['entrances'] as List?) ?? const []) {
    final loc = (e as Map?)?['location'] as Map?;
    final lat = (loc?['latitude'] as num?)?.toDouble();
    final lng = (loc?['longitude'] as num?)?.toDouble();
    if (lat != null && lng != null) entrances.add(LatLng(lat, lng));
  }
  return BuildingOutline(placeId: placeId, rings: rings, entrances: entrances);
}

/// GeoJSON `Polygon` ([ring][point][lng, lat]) or `MultiPolygon`
/// ([polygon][ring][point][lng, lat]) → outer rings as LatLng lists.
List<List<LatLng>> _ringsFromDisplayPolygon(Object? polygon) {
  if (polygon is! Map) return const [];
  final type = polygon['type'] as String?;
  final coords = polygon['coordinates'];
  if (coords is! List) return const [];

  List<LatLng> ring(Object? raw) {
    if (raw is! List) return const [];
    final out = <LatLng>[];
    for (final pt in raw) {
      if (pt is List && pt.length >= 2) {
        final lng = (pt[0] as num?)?.toDouble();
        final lat = (pt[1] as num?)?.toDouble();
        if (lat != null && lng != null) out.add(LatLng(lat, lng));
      }
    }
    return out.length >= 3 ? out : const [];
  }

  final rings = <List<LatLng>>[];
  if (type == 'Polygon') {
    if (coords.isNotEmpty) {
      final r = ring(coords.first);
      if (r.isNotEmpty) rings.add(r);
    }
  } else if (type == 'MultiPolygon') {
    for (final poly in coords) {
      if (poly is List && poly.isNotEmpty) {
        final r = ring(poly.first);
        if (r.isNotEmpty) rings.add(r);
      }
    }
  }
  return rings;
}

/// Fetches building footprints from Google's Geocoding API v4
/// (SearchDestinations), once per place per run. One small POST when a pin
/// is opened for the first time; every later open of the same place is
/// answered from memory, so the map never waits on this.
class BuildingOutlineService {
  static const String _endpoint =
      'https://geocode.googleapis.com/v4/geocode/destinations';

  /// Only the fields drawn: structure types, footprints, entrance points.
  static const String _fieldMask = 'destinations.primary.structureType,'
      'destinations.primary.displayPolygon,'
      'destinations.containingPlaces.structureType,'
      'destinations.containingPlaces.displayPolygon,'
      'destinations.entrances.location';

  static final Map<String, Future<BuildingOutline?>> _cache = {};

  /// Set when Google answers that this key may not use the endpoint
  /// (API not enabled, key restricted): no further requests this run, so a
  /// misconfigured key costs one request, not one per pin tap.
  static bool _unavailable = false;

  /// The outline for [placeId], or null when Google has none for it (or
  /// the request failed — a transient failure is not remembered, so the
  /// next open asks again).
  static Future<BuildingOutline?> forPlace(String placeId) {
    if (_unavailable) return Future.value(null);
    return _cache.putIfAbsent(placeId, () {
      return _fetch(placeId).catchError((Object e) {
        if (e is DioException) {
          final code = e.response?.statusCode ?? 0;
          if (code == 401 || code == 403 || code == 404) _unavailable = true;
        }
        debugPrint('BuildingOutlineService($placeId): $e');
        _cache.remove(placeId);
        return null;
      });
    });
  }

  static Future<BuildingOutline?> _fetch(String placeId) async {
    final key = ApiService.googleMapsApiKey;
    if (key.isEmpty) return null;
    final response = await ApiService.dio.post(
      _endpoint,
      data: {'place': 'places/$placeId'},
      options: Options(headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': key,
        'X-Goog-FieldMask': _fieldMask,
      }),
    );
    final data = response.data;
    if (data is! Map<String, dynamic>) return null;
    return parseBuildingOutline(placeId, data);
  }

  @visibleForTesting
  static void resetCache() {
    _cache.clear();
    _unavailable = false;
  }
}
