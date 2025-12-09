import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils/stream_utils.dart';
import 'api_service.dart';

class LocationService {
  static Future<bool> requestLocationPermission() async {
    final permission = await Permission.location.request();
    return permission == PermissionStatus.granted;
  }

  static Future<LatLng?> getCurrentLocation() async {
    try {
      final hasPermission = await requestLocationPermission();
      if (!hasPermission) return null;

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      return LatLng(position.latitude, position.longitude);
    } catch (e) {
      print('Error getting current location: $e');
      return null;
    }
  }

  static Future<String?> getCurrentCountryCode() async {
    try {
      final coordinates = await getCurrentLocation();
      if (coordinates == null) return null;

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
            return component['short_name'];
          }
        }
      }
      return null;
    } catch (e) {
      print('Error getting current country code: $e');
      return null;
    }
  }

  static Stream<LatLng> getLocationStream() async* {
    final hasPermission = await requestLocationPermission();
    if (!hasPermission) return;

    // PERFORMANCE: Increased distance filter from 10m to 50m
    // This dramatically reduces updates and battery drain
    // 50m is enough to track movement without excessive updates
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 50, // Only update when moved 50+ meters
    );

    await for (final position in Geolocator.getPositionStream(
      locationSettings: locationSettings,
    )) {
      yield LatLng(position.latitude, position.longitude);
    }
  }

  static Stream<double?> getCompassStream() {
    // PERFORMANCE: Increased throttle from 100ms to 500ms (2 updates/sec)
    // This is sufficient for compass UI and reduces CPU/battery usage by 80%
    // Most users don't need real-time compass updates
    return FlutterCompass.events!
        .transform(StreamUtils.throttle(const Duration(milliseconds: 500)))
        .map((event) => event.heading);
  }
}