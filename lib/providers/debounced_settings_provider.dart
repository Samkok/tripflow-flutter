import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';


class DebouncedProximityThreshold {
  final double previewValue;
  final double committedValue;
  final bool isDebouncing;

  const DebouncedProximityThreshold({
    required this.previewValue,
    required this.committedValue,
    this.isDebouncing = false,
  });

  DebouncedProximityThreshold copyWith({
    double? previewValue,
    double? committedValue,
    bool? isDebouncing,
  }) {
    return DebouncedProximityThreshold(
      previewValue: previewValue ?? this.previewValue,
      committedValue: committedValue ?? this.committedValue,
      isDebouncing: isDebouncing ?? this.isDebouncing,
    );
  }
}

class DebouncedProximityThresholdNotifier extends StateNotifier<DebouncedProximityThreshold> {
  DebouncedProximityThresholdNotifier()
      : super(const DebouncedProximityThreshold(previewValue: 1000.0, committedValue: 1000.0)) {
    _loadProximityThreshold();
  }

  static const _proximityThresholdKey = 'proximity_threshold';

  Future<void> _loadProximityThreshold() async {
    final prefs = await SharedPreferences.getInstance();
    final savedValue = prefs.getDouble(_proximityThresholdKey) ?? 1000.0;
    state = DebouncedProximityThreshold(
      previewValue: savedValue,
      committedValue: savedValue,
    );
  }

  Future<void> _saveProximityThreshold(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_proximityThresholdKey, value);
  }

  Timer? _debounceTimer;
  static const Duration _debounceDuration = Duration(milliseconds: 300);

  void updatePreviewValue(double value) {
    state = state.copyWith(
      previewValue: value,
      isDebouncing: true,
    );

    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, () {
      _commitValue(value);
    });
  }

  void _commitValue(double value) {
    state = state.copyWith(
      committedValue: value,
      isDebouncing: false,
    );
    _saveProximityThreshold(value);
  }

  void setValueImmediately(double value) {
    _debounceTimer?.cancel();
    state = DebouncedProximityThreshold(
      previewValue: value,
      committedValue: value,
      isDebouncing: false,
    );
    _saveProximityThreshold(value);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }
}

final debouncedProximityThresholdProvider =
    StateNotifierProvider<DebouncedProximityThresholdNotifier, DebouncedProximityThreshold>((ref) {
  return DebouncedProximityThresholdNotifier();
});

final proximityThresholdPreviewProvider = Provider<double>((ref) {
  return ref.watch(debouncedProximityThresholdProvider.select((state) => state.previewValue));
});

final proximityThresholdCommittedProvider = Provider<double>((ref) {
  return ref.watch(debouncedProximityThresholdProvider.select((state) => state.committedValue));
});

final isProximityThresholdDebouncingProvider = Provider<bool>((ref) {
  return ref.watch(debouncedProximityThresholdProvider.select((state) => state.isDebouncing));
});
