import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/main.dart';

/// User-configurable radius (in meters) used when the long-press flow on the
/// map screen queries Google's Nearby Search for POIs around the tapped
/// coordinate. Defaults to 300m — small enough that the returned list stays
/// focused on the spot the user actually pressed, but large enough to catch
/// adjacent landmarks.
class NearbyRadiusNotifier extends StateNotifier<double> {
  NearbyRadiusNotifier() : super(_load());

  static const _key = 'nearby_poi_radius_meters';
  static const double defaultRadius = 300;
  static const double minRadius = 100;
  static const double maxRadius = 2000;

  static double _load() {
    final raw = SharedPrefsCache.instance.getDouble(_key) ?? defaultRadius;
    return raw.clamp(minRadius, maxRadius);
  }

  Future<void> set(double meters) async {
    final clamped = meters.clamp(minRadius, maxRadius);
    state = clamped;
    await SharedPrefsCache.instance.setDouble(_key, clamped);
  }
}

final nearbyRadiusProvider =
    StateNotifierProvider<NearbyRadiusNotifier, double>((ref) {
  return NearbyRadiusNotifier();
});
