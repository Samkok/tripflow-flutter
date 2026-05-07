import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/main.dart';

/// User preference: should the "Zoom to fit" map control include the
/// device's current location in the bounds it fits to?
///
/// Default is `true` — most users planning a trip benefit from seeing
/// where they currently are relative to their stops. The setting is
/// persisted via SharedPreferences and surfaced in the settings screen.
class IncludeCurrentInFitNotifier extends StateNotifier<bool> {
  IncludeCurrentInFitNotifier() : super(_load());

  static const _key = 'include_current_location_in_zoom_to_fit';
  static const bool defaultValue = true;

  static bool _load() =>
      SharedPrefsCache.instance.getBool(_key) ?? defaultValue;

  Future<void> set(bool value) async {
    state = value;
    await SharedPrefsCache.instance.setBool(_key, value);
  }
}

final includeCurrentInFitProvider =
    StateNotifierProvider<IncludeCurrentInFitNotifier, bool>((ref) {
  return IncludeCurrentInFitNotifier();
});
