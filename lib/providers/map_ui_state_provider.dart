import 'package:flutter_riverpod/flutter_riverpod.dart';

class MapUIState {
  final bool isFabMenuOpen;
  final bool showPolylineInfoOverlay;
  final String? tappedPolylineId;
  final int? highlightedLocationIndex;
  final String routeDescription;
  final String formattedDuration;
  final String formattedDistance;
  final int currentLegIndex;

  const MapUIState({
    this.isFabMenuOpen = false,
    this.showPolylineInfoOverlay = false,
    this.tappedPolylineId,
    this.highlightedLocationIndex,
    this.routeDescription = '',
    this.formattedDuration = '',
    this.formattedDistance = '',
    this.currentLegIndex = -1,
  });

  MapUIState copyWith({
    bool? isFabMenuOpen,
    bool? showPolylineInfoOverlay,
    String? tappedPolylineId,
    int? highlightedLocationIndex,
    String? routeDescription,
    String? formattedDuration,
    String? formattedDistance,
    int? currentLegIndex,
    bool clearTappedPolyline = false,
    bool clearHighlightedLocation = false,
  }) {
    return MapUIState(
      isFabMenuOpen: isFabMenuOpen ?? this.isFabMenuOpen,
      showPolylineInfoOverlay: showPolylineInfoOverlay ?? this.showPolylineInfoOverlay,
      tappedPolylineId: clearTappedPolyline ? null : (tappedPolylineId ?? this.tappedPolylineId),
      highlightedLocationIndex: clearHighlightedLocation ? null : (highlightedLocationIndex ?? this.highlightedLocationIndex),
      routeDescription: routeDescription ?? this.routeDescription,
      formattedDuration: formattedDuration ?? this.formattedDuration,
      formattedDistance: formattedDistance ?? this.formattedDistance,
      currentLegIndex: currentLegIndex ?? this.currentLegIndex,
    );
  }
}

class MapUIStateNotifier extends StateNotifier<MapUIState> {
  MapUIStateNotifier() : super(const MapUIState());

  void toggleFabMenu() {
    state = state.copyWith(isFabMenuOpen: !state.isFabMenuOpen);
  }

  void closeFabMenu() {
    state = state.copyWith(isFabMenuOpen: false);
  }

  void showPolylineInfo({
    required String routeDescription,
    required String formattedDuration,
    required String formattedDistance,
    required int legIndex,
  }) {
    state = state.copyWith(
      showPolylineInfoOverlay: true,
      routeDescription: routeDescription,
      formattedDuration: formattedDuration,
      formattedDistance: formattedDistance,
      currentLegIndex: legIndex,
      highlightedLocationIndex: legIndex,
    );
  }

  void hidePolylineInfo() {
    state = state.copyWith(
      showPolylineInfoOverlay: false,
      clearTappedPolyline: true,
      clearHighlightedLocation: true,
    );
  }

  void setTappedPolyline(String? polylineId) {
    state = state.copyWith(
      tappedPolylineId: polylineId,
      clearTappedPolyline: polylineId == null,
    );
  }

  void clearHighlights() {
    state = state.copyWith(
      showPolylineInfoOverlay: false,
      clearTappedPolyline: true,
      clearHighlightedLocation: true,
    );
  }
}

final mapUIStateProvider = StateNotifierProvider<MapUIStateNotifier, MapUIState>((ref) {
  return MapUIStateNotifier();
});

final showPlaceNamesProvider = StateProvider<bool>((ref) => true);

final fabMenuOpenProvider = Provider<bool>((ref) {
  return ref.watch(mapUIStateProvider.select((state) => state.isFabMenuOpen));
});

final tappedPolylineIdProvider = Provider<String?>((ref) {
  return ref.watch(mapUIStateProvider.select((state) => state.tappedPolylineId));
});

final highlightedLocationIndexProvider = Provider<int?>((ref) {
  return ref.watch(mapUIStateProvider.select((state) => state.highlightedLocationIndex));
});

// Providers for multi-select functionality in the trip list
final isSelectionModeProvider = StateProvider<bool>((ref) => false);
final selectedLocationsProvider = StateProvider<Set<String>>((ref) => {});

// Provider for the currently selected date for filtering locations
final selectedDateProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  // Default to today at midnight to ignore time component
  return DateTime(now.year, now.month, now.day);
});
