import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'places_service.dart';

/// Answers "is the device in the same country as this place?" — the gate
/// on "Route from my location", which draws an in-app leg from the blue
/// dot and makes no sense from another country.
///
/// Two ISO-2 codes are compared: the place's (its trip's tagged country
/// when it has one, else one reverse geocode of its pin, remembered per
/// place for the session) and the device's (one reverse geocode of the
/// fix, remembered until the device moves [deviceCacheMeters]). So a place
/// on a country-tagged trip costs nothing beyond the session's first
/// device lookup, and opening several sheets in a row costs nothing at all.
///
/// Verdicts: `true` same country, `false` different, `null` unknown — a
/// lookup failed or hasn't run. Callers treat unknown as "don't block",
/// like the Optimize start-point sheet does: a flaky geocode must never
/// lock a button.
class CountryMatchService {
  CountryMatchService({
    Future<String?> Function(LatLng) geocodeCountry =
        PlacesService.getCountryCodeFromCoordinates,
  }) : _geocode = geocodeCountry;

  static final CountryMatchService instance = CountryMatchService();

  final Future<String?> Function(LatLng) _geocode;

  /// How far the device may move before its country is looked up again.
  /// Small on purpose: some borders (Singapore–Johor, Geneva–France) sit a
  /// couple of kilometres from where people actually stand.
  static const double deviceCacheMeters = 5000;

  LatLng? _deviceAt;
  String? _deviceCode;
  Future<String?>? _deviceInFlight;
  LatLng? _deviceInFlightAt;
  final Map<String, String> _placeCodes = {};

  /// What is already known, without any I/O: `null` when either side still
  /// needs a lookup. Lets the button open in its final state most of the
  /// time instead of flashing from disabled to enabled.
  bool? cachedVerdict({
    required LatLng device,
    required String placeKey,
    String? knownPlaceCountry,
  }) {
    final d = _cachedDeviceCode(device);
    final p = _normalize(knownPlaceCountry) ?? _placeCodes[placeKey];
    if (d == null || p == null) return null;
    return d == p;
  }

  /// Resolves both codes (network only where the cache can't answer) and
  /// compares them.
  Future<bool?> verdict({
    required LatLng device,
    required LatLng place,
    required String placeKey,
    String? knownPlaceCountry,
  }) async {
    final codes = await Future.wait<String?>([
      _deviceCountry(device),
      _placeCountry(place, placeKey, knownPlaceCountry),
    ]);
    final d = codes[0];
    final p = codes[1];
    if (d == null || p == null) return null;
    return d == p;
  }

  String? _cachedDeviceCode(LatLng here) {
    final at = _deviceAt;
    final code = _deviceCode;
    if (at == null || code == null) return null;
    return _metersBetween(at, here) <= deviceCacheMeters ? code : null;
  }

  Future<String?> _deviceCountry(LatLng here) {
    final cached = _cachedDeviceCode(here);
    if (cached != null) return Future.value(cached);
    // Sheets opened in quick succession share one in-flight lookup.
    final inFlight = _deviceInFlight;
    final inFlightAt = _deviceInFlightAt;
    if (inFlight != null &&
        inFlightAt != null &&
        _metersBetween(inFlightAt, here) <= deviceCacheMeters) {
      return inFlight;
    }
    final future = _lookup(here).then((code) {
      if (code != null) {
        _deviceAt = here;
        _deviceCode = code;
      }
      return code;
    }).whenComplete(() {
      _deviceInFlight = null;
      _deviceInFlightAt = null;
    });
    _deviceInFlight = future;
    _deviceInFlightAt = here;
    return future;
  }

  Future<String?> _placeCountry(LatLng place, String key, String? known) async {
    final k = _normalize(known);
    if (k != null) return k;
    final cached = _placeCodes[key];
    if (cached != null) return cached;
    final code = await _lookup(place);
    // A failed lookup is not remembered, so the next open retries it.
    if (code != null) _placeCodes[key] = code;
    return code;
  }

  Future<String?> _lookup(LatLng at) async {
    try {
      return _normalize(await _geocode(at));
    } catch (e) {
      debugPrint('CountryMatch: country lookup failed ($e)');
      return null;
    }
  }

  static String? _normalize(String? code) {
    final c = code?.trim().toUpperCase();
    return (c == null || c.isEmpty) ? null : c;
  }

  static double _metersBetween(LatLng a, LatLng b) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180.0;
    final dLat = rad(b.latitude - a.latitude);
    final dLng = rad(b.longitude - a.longitude);
    final s = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(a.latitude)) *
            math.cos(rad(b.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.atan2(math.sqrt(s), math.sqrt(1 - s));
  }
}
