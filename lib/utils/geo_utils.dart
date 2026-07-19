import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Distance (~500 km) beyond which the device is treated as being in a
/// different region than a set of stops when no trip country is available to
/// compare against (anonymous sessions / country-less trips). Used to keep a
/// far-away current location out of map fits and route starts — e.g. a phone
/// in Cambodia must not anchor or frame the Lisbon sample trip.
const double kForeignFallbackMeters = 500000;

/// Minimum great-circle distance in meters from [from] to any of [points].
/// Returns [double.infinity] when [points] is empty.
double minMetersToAny(LatLng from, Iterable<LatLng> points) {
  var min = double.infinity;
  for (final p in points) {
    final d = Geolocator.distanceBetween(
      from.latitude,
      from.longitude,
      p.latitude,
      p.longitude,
    );
    if (d < min) min = d;
  }
  return min;
}
