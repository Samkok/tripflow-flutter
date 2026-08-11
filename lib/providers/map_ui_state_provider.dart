import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

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
      showPolylineInfoOverlay:
          showPolylineInfoOverlay ?? this.showPolylineInfoOverlay,
      tappedPolylineId: clearTappedPolyline
          ? null
          : (tappedPolylineId ?? this.tappedPolylineId),
      highlightedLocationIndex: clearHighlightedLocation
          ? null
          : (highlightedLocationIndex ?? this.highlightedLocationIndex),
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

final mapUIStateProvider =
    StateNotifierProvider<MapUIStateNotifier, MapUIState>((ref) {
  return MapUIStateNotifier();
});

final showPlaceNamesProvider = StateProvider<bool>((ref) => true);

final fabMenuOpenProvider = Provider<bool>((ref) {
  return ref.watch(mapUIStateProvider.select((state) => state.isFabMenuOpen));
});

final tappedPolylineIdProvider = Provider<String?>((ref) {
  return ref
      .watch(mapUIStateProvider.select((state) => state.tappedPolylineId));
});

final highlightedLocationIndexProvider = Provider<int?>((ref) {
  return ref.watch(
      mapUIStateProvider.select((state) => state.highlightedLocationIndex));
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

/// One-shot signal (bumped counter) that a flow just focused the map on a
/// specific day — e.g. the trip card's "Go to map" sets [selectedDateProvider]
/// to the trip's first day and bumps this. The trip sheet listens and flips
/// its locations toggle back to "Selected Day", which otherwise retains
/// whatever the user last used and made the landing look un-focused.
final mapDayFocusRequestProvider = StateProvider<int>((ref) => 0);

/// Device compass heading in degrees clockwise from north, or null when no
/// reliable heading exists (no magnetometer, simulator, uncalibrated).
/// Written ONLY by MapScreen's throttled + ≥3°-gated compass subscription
/// and watched ONLY by finalMarkersProvider, which aims the current-location
/// beam via Marker.rotation. Deliberately NOT part of TripState: a heading
/// tick must never wake trip-state listeners.
final deviceHeadingProvider = StateProvider<double?>((_) => null);

/// One-shot "collapse the plan sheet and zoom the map to this spot"
/// request, fired by a location card's map button and consumed by
/// MapScreen. A fresh object every time (no ==) so repeat taps on the
/// same location still fire.
class MapZoomToLocationRequest {
  MapZoomToLocationRequest(this.target);
  final LatLng target;
}

final mapZoomToLocationRequestProvider =
    StateProvider<MapZoomToLocationRequest?>((_) => null);

/// One-shot "frame this route leg on the map" request, fired by the
/// route-leg sheet's Show-on-map button. MapScreen consumes it: collapses
/// the plan sheet, fits the camera to the leg's bounds, and highlights it.
class MapZoomToLegRequest {
  MapZoomToLegRequest(this.legIndex);
  final int legIndex;
}

final mapZoomToLegRequestProvider =
    StateProvider<MapZoomToLegRequest?>((_) => null);
