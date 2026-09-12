import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/main.dart';

/// How close (metres) the device must be to one of today's stops before the
/// map asks whether to mark it done — and the radius of the dotted ring
/// drawn around the current-location dot, which is that same distance made
/// visible. User-set in Settings; 10–100 m so the ring stays a "you're
/// there" test rather than a neighbourhood. Persisted.
class ArrivalRadiusNotifier extends StateNotifier<double> {
  ArrivalRadiusNotifier() : super(_load());

  static const _key = 'arrival_radius_meters';

  /// Default: wide enough to absorb the 5–15 m a phone's fix typically
  /// wanders, tight enough that the stop next door doesn't count.
  static const double defaultRadius = 25;
  static const double minRadius = 10;
  static const double maxRadius = 100;

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

final arrivalRadiusProvider =
    StateNotifierProvider<ArrivalRadiusNotifier, double>((ref) {
  return ArrivalRadiusNotifier();
});
