import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../utils/stream_utils.dart';
import 'api_service.dart';

class LocationService {
  /// Check if location services are enabled on the device
  static Future<bool> isLocationServiceEnabled() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  /// Check current location permission status
  static Future<LocationPermission> checkLocationPermission() async {
    return await Geolocator.checkPermission();
  }

  /// Open device location settings
  static Future<bool> openLocationSettings() async {
    return await Geolocator.openLocationSettings();
  }

  /// Request location permission using both Geolocator and permission_handler
  /// True when location can be read RIGHT NOW without showing any prompt.
  ///
  /// For opportunistic, non-user-initiated work (arrival polling, background
  /// refreshes) — those must never be what raises the OS permission dialog.
  /// Only in-context, user-visible flows should call
  /// [requestLocationPermission].
  static Future<bool> hasLocationPermissionAlready() async {
    try {
      if (!await isLocationServiceEnabled()) return false;
      final permission = await checkLocationPermission();
      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (e) {
      debugPrint('hasLocationPermissionAlready: $e');
      return false;
    }
  }

  /// Global latch: the OS permission dialog is HARD-SUPPRESSED until the app
  /// reaches a surface where asking makes sense (the map actually visible, or
  /// an explicit user action like the my-location button). Opened by
  /// MapScreen's location gate.
  ///
  /// This exists because gating individual call sites kept leaking — any
  /// launch-time code path that reaches [requestLocationPermission] while the
  /// latch is closed now gets the current status WITHOUT a prompt, and in
  /// debug builds logs the caller's stack so the leak is identifiable.
  static bool promptsAllowed = false;

  static Future<bool> requestLocationPermission() async {
    // First check if location services are enabled
    final serviceEnabled = await isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('Location services are disabled on device');
      return false;
    }

    // Check current permission status
    LocationPermission permission = await checkLocationPermission();

    // If already granted (whileInUse or always), return true immediately
    if (permission == LocationPermission.whileInUse) {
      debugPrint('Location permission already granted: $permission');
      return true;
    }

    // If denied, request permission
    if (permission == LocationPermission.denied) {
      if (!promptsAllowed) {
        if (kDebugMode) {
          debugPrint('Location prompt SUPPRESSED (latch closed). Caller was:\n'
              '${StackTrace.current}');
        }
        return false;
      }
      debugPrint('Requesting location permission...');
      permission = await Geolocator.requestPermission();

      // Check if permission was granted after request
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.whileInUse) {
        debugPrint('Location permission granted: $permission');
        return true;
      }

      if (permission == LocationPermission.denied) {
        debugPrint('Location permission denied');
        return false;
      }
    }

    // If permanently denied
    if (permission == LocationPermission.deniedForever) {
      debugPrint('Location permission permanently denied');
      return false;
    }

    return true;
  }

  static Future<LatLng?> getCurrentLocation() async {
    try {
      final hasPermission = await requestLocationPermission();
      if (!hasPermission) return null;

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );

      return LatLng(position.latitude, position.longitude);
    } catch (e) {
      debugPrint('Error getting current location: $e');
      return null;
    }
  }

  static Future<String?> getCurrentCountryCode() async {
    final coordinates = await getCurrentLocation();
    if (coordinates == null) return null;
    return getCountryCodeForLocation(coordinates);
  }

  /// Reverse-geocodes a KNOWN point to its ISO 3166-1 alpha-2 country code
  /// (uppercase, e.g. 'JP'), matching how trips store `countryCode`. Takes an
  /// explicit [coordinates] so callers can resolve the country of a location
  /// already in memory without triggering a fresh GPS fix.
  static Future<String?> getCountryCodeForLocation(LatLng coordinates) async {
    try {
      final url = 'https://maps.googleapis.com/maps/api/geocode/json'
          '?latlng=${coordinates.latitude},${coordinates.longitude}'
          '&key=${ApiService.googleMapsApiKey}';

      final response = await ApiService.dio.get(url);
      final data = response.data;

      if (data['status'] != 'OK' || data['results'].isEmpty) {
        return null;
      }

      final results = data['results'] as List;
      for (final result in results) {
        final addressComponents = result['address_components'] as List;
        for (final component in addressComponents) {
          final types = component['types'] as List;
          if (types.contains('country')) {
            return (component['short_name'] as String?)?.toUpperCase();
          }
        }
      }
      return null;
    } catch (e) {
      debugPrint('Error getting country code for location: $e');
      return null;
    }
  }

  static Stream<LatLng> getLocationStream() async* {
    final hasPermission = await requestLocationPermission();
    if (!hasPermission) return;

    // 5m native filter: emits only on real movement (a stationary device
    // produces ZERO events — the OS suppresses them), yet the pin tracks a
    // walking user every few steps, Google-Maps-like. The old 50m throttle
    // existed because every tick used to regenerate every marker bitmap;
    // that pipeline is fixed (bitmaps cached, position applied downstream),
    // so the coarse filter's reason is gone.
    // Android: the fused provider's default interval is "as fast as
    // possible" — a 3 s interval cuts the GPS duty cycle with no visible
    // cost (walking pace = one step every 3 s; driving at 50 km/h ≈ 40 m
    // hops, fine for a planning map). iOS keeps the plain settings: its
    // auto-pause options can leave the stream silent after a long rest,
    // the frozen-dot bug class we just fixed.
    final LocationSettings locationSettings =
        defaultTargetPlatform == TargetPlatform.android
            ? AndroidSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 5,
                intervalDuration: const Duration(seconds: 3),
              )
            : const LocationSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 5,
              );

    await for (final position in Geolocator.getPositionStream(
      locationSettings: locationSettings,
    )) {
      yield LatLng(position.latitude, position.longitude);
    }
  }

  static Stream<double?> getCompassStream() {
    // 750ms (was 500, was 250): every beam update redraws the map, and
    // with the glass sheet's blur over it that redraw was the thermal hot
    // path. At ~1.3 events/sec slow turns still step ≤ the 5° gate (smooth
    // — small deltas accumulate per tick), and fast turns hide the latency.
    // The consumer (MapScreen) gates on a ≥3° change, so a stationary
    // phone's magnetometer noise produces zero downstream work.
    return FlutterCompass.events!
        .transform(StreamUtils.throttle(const Duration(milliseconds: 750)))
        .map((event) => event.heading);
  }
}
