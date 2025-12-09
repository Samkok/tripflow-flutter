import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:geolocator/geolocator.dart';
import '../models/location_model.dart';
import '../models/trip_model.dart';
import '../services/google_maps_service.dart';
import '../services/storage_service.dart';
import '../providers/debounced_settings_provider.dart';
import '../utils/zone_utils.dart';

class TripState {
  final List<LocationModel> pinnedLocations;
  final List<LocationModel>
      optimizedLocationsForSelectedDate; // New field for the optimized order
  final List<LatLng> optimizedRoute;
  final List<List<LatLng>> legPolylines;
  final List<Map<String, dynamic>> legDetails;
  final LatLng? currentLocation;
  final Duration totalTravelTime;
  final double? currentHeading;
  final double totalDistance;
  String startLocationId;
  final int? selectedLegIndex;

  TripState({
    this.pinnedLocations = const [],
    this.optimizedLocationsForSelectedDate = const [],
    this.optimizedRoute = const [],
    this.legPolylines = const [],
    this.legDetails = const [],
    this.currentLocation,
    this.totalTravelTime = Duration.zero,
    this.currentHeading,
    this.totalDistance = 0.0,
    this.startLocationId = '',
    this.selectedLegIndex,
  });

  TripState copyWith({
    List<LocationModel>? pinnedLocations,
    List<LocationModel>? optimizedLocationsForSelectedDate,
    List<LatLng>? optimizedRoute,
    List<List<LatLng>>? legPolylines,
    List<Map<String, dynamic>>? legDetails,
    LatLng? currentLocation,
    Duration? totalTravelTime,
    double? currentHeading,
    double? totalDistance,
    String? startLocationId,
    int? selectedLegIndex,
  }) {
    return TripState(
      pinnedLocations: pinnedLocations ?? this.pinnedLocations,
      optimizedLocationsForSelectedDate: optimizedLocationsForSelectedDate ??
          this.optimizedLocationsForSelectedDate,
      optimizedRoute: optimizedRoute ?? this.optimizedRoute,
      legPolylines: legPolylines ?? this.legPolylines,
      legDetails: legDetails ?? this.legDetails,
      currentLocation: currentLocation ?? this.currentLocation,
      totalTravelTime: totalTravelTime ?? this.totalTravelTime,
      currentHeading: currentHeading ?? this.currentHeading,
      totalDistance: totalDistance ?? this.totalDistance,
      startLocationId: startLocationId ?? this.startLocationId,
      selectedLegIndex: selectedLegIndex, // Allow setting to null
    );
  }

  // PERFORMANCE: Add equality checking to prevent unnecessary rebuilds
  // Riverpod uses == to determine if state changed
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is TripState &&
        _listEquals(other.pinnedLocations, pinnedLocations) &&
        _listEquals(other.optimizedLocationsForSelectedDate,
            optimizedLocationsForSelectedDate) &&
        _listEquals(other.optimizedRoute, optimizedRoute) &&
        other.currentLocation == currentLocation &&
        other.totalTravelTime == totalTravelTime &&
        other.totalDistance == totalDistance &&
        other.selectedLegIndex == selectedLegIndex;
    // Note: Deliberately excluding legPolylines and legDetails from equality
    // to keep the check fast. They change together with optimizedRoute anyway.
  }

  @override
  int get hashCode {
    return Object.hash(
      Object.hashAll(pinnedLocations),
      Object.hashAll(optimizedLocationsForSelectedDate),
      Object.hashAll(optimizedRoute),
      currentLocation,
      totalTravelTime,
      totalDistance,
      selectedLegIndex,
    );
  }

  bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class TripNotifier extends StateNotifier<TripState> {
  final Ref _ref;
  bool _isLoading = true;

  TripNotifier(this._ref) : super(TripState()) {
    _loadPinnedLocations();
  }

  Future<void> _loadPinnedLocations() async {
    _isLoading = true;
    final locations = await StorageService.getPinnedLocations();
    state = state.copyWith(pinnedLocations: locations);
    _isLoading = false;
  }

  Future<void> _saveLocations(List<LocationModel> locations) async {
    if (_isLoading) return; // Prevent saving while initial load is in progress
    await StorageService.savePinnedLocations(locations);
  }

  Future<void> addLocation(LocationModel location) async {
    // Optimistic update: add location immediately to state for instant UI feedback
    final selectedDate = _ref.read(selectedDateProvider);

    // Ensure the new location has the currently selected date if it doesn't have one.
    final locationWithDate = location.scheduledDate == null
        ? location.copyWith(scheduledDate: selectedDate)
        : location;

    final updatedLocations = [...state.pinnedLocations, locationWithDate];
    // When adding a new location, the existing optimized route is no longer valid.
    // Clear it to ensure the UI reflects the new, un-optimized list.
    state = state.copyWith(
      pinnedLocations: updatedLocations,
      optimizedLocationsForSelectedDate: [],
      optimizedRoute: [],
      legDetails: [],
    );
    selectLeg(null); // Clear selected leg

    // Save to storage asynchronously without blocking
    _saveLocations(updatedLocations);
  }

  Future<void> removeLocation(String locationId) async {
    final updatedLocations =
        state.pinnedLocations.where((loc) => loc.id != locationId).toList();

    // Clear optimized route data when a location is removed
    state = state.copyWith(
      pinnedLocations: updatedLocations,
      optimizedLocationsForSelectedDate: [],
      optimizedRoute: [],
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    selectLeg(null); // Clear selected leg

    await _saveLocations(updatedLocations);
  }

  Future<void> removeMultipleLocations(Set<String> locationIds) async {
    final updatedLocations = state.pinnedLocations
        .where((loc) => !locationIds.contains(loc.id))
        .toList();

    // Clear optimized route data when locations are removed
    state = state.copyWith(
      pinnedLocations: updatedLocations,
      optimizedLocationsForSelectedDate: [], // Clear optimized list
      optimizedRoute: [],
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    selectLeg(null); // Clear selected leg

    await _saveLocations(updatedLocations);
  }

  Future<void> skipMultipleLocations(Set<String> locationIds) async {
    final updatedLocations = state.pinnedLocations.map((loc) {
      if (locationIds.contains(loc.id)) {
        return loc.copyWith(isSkipped: true);
      }
      return loc;
    }).toList();

    state = state.copyWith(
      pinnedLocations: updatedLocations,
      optimizedRoute: [],
      optimizedLocationsForSelectedDate: [], // Clear optimized list
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    selectLeg(null); // Clear selected leg
    await _saveLocations(updatedLocations);
  }

  Future<void> unskipMultipleLocations(Set<String> locationIds) async {
    final updatedLocations = state.pinnedLocations.map((loc) {
      if (locationIds.contains(loc.id)) {
        return loc.copyWith(isSkipped: false);
      }
      return loc;
    }).toList();

    state = state.copyWith(
      pinnedLocations: updatedLocations,
      optimizedRoute: [],
      optimizedLocationsForSelectedDate: [], // Clear optimized list
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    selectLeg(null); // Clear selected leg
    await _saveLocations(updatedLocations);
  }

  Future<void> reorderLocation(int oldIndex, int newIndex) async {
    final updatedLocations = List<LocationModel>.from(state.pinnedLocations);

    // Adjust newIndex if it's greater than oldIndex (due to removal)
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }

    // Remove item from old position and insert at new position
    final item = updatedLocations.removeAt(oldIndex);
    updatedLocations.insert(newIndex, item);

    // Clear optimized route data when locations are reordered
    state = state.copyWith(
      pinnedLocations: updatedLocations,
      optimizedRoute: [],
      optimizedLocationsForSelectedDate: [], // Clear optimized list
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    selectLeg(null); // Clear selected leg

    await _saveLocations(updatedLocations);
  }

  Future<void> updateLocationName(String locationId, String newName) async {
    final updatedLocations = state.pinnedLocations.map((loc) {
      if (loc.id == locationId) {
        // Return a new LocationModel with the updated name
        return loc.copyWith(name: newName);
      }
      return loc;
    }).toList();

    state = state.copyWith(pinnedLocations: updatedLocations);
    await _saveLocations(updatedLocations);
  }

  Future<void> updateLocationStayDuration(
      String locationId, Duration newDuration) async {
    final updatedLocations = state.pinnedLocations.map((loc) {
      if (loc.id == locationId) {
        return loc.copyWith(stayDuration: newDuration);
      }
      return loc;
    }).toList();

    // Recalculate total travel time
    final newTotalTravelTime =
        _calculateTotalTime(updatedLocations, state.legDetails);

    state = state.copyWith(
      pinnedLocations: updatedLocations,
      totalTravelTime: newTotalTravelTime,
    );
    await _saveLocations(updatedLocations);
  }

  Future<void> updateLocationScheduledDate(
      String locationId, DateTime newDate) async {
    final locations = state.pinnedLocations;
    final updatedLocations = locations.map((loc) {
      if (loc.id == locationId) {
        return loc.copyWith(scheduledDate: newDate);
      }
      return loc;
    }).toList();

    state = state.copyWith(pinnedLocations: updatedLocations);
    await _saveLocations(updatedLocations);
  }

  Future<void> updateMultipleLocationsScheduledDate(
      Set<String> locationIds, DateTime newDate) async {
    final updatedLocations = state.pinnedLocations.map((loc) {
      if (locationIds.contains(loc.id)) {
        // Return a new LocationModel with the updated scheduled date
        return loc.copyWith(scheduledDate: newDate);
      }
      return loc;
    }).toList();

    state = state.copyWith(pinnedLocations: updatedLocations);
    await _saveLocations(updatedLocations);
  }

  Future<void> copyMultipleLocationsToDate(
      Set<String> locationIds, DateTime newDate) async {
    final locationsToCopy = state.pinnedLocations
        .where((loc) => locationIds.contains(loc.id))
        .toList();

    final newLocations = locationsToCopy.map((loc) {
      // Create a new location with a new ID and the new date.
      // Reset travel details as they are not applicable to the new date yet.
      return loc.copyWith(
        id: const Uuid().v4(),
        scheduledDate: newDate,
        travelTimeFromPrevious: null,
        distanceFromPrevious: null,
      );
    }).toList();

    if (newLocations.isNotEmpty) {
      final updatedLocations = [...state.pinnedLocations, ...newLocations];
      state = state.copyWith(pinnedLocations: updatedLocations);
      await _saveLocations(updatedLocations);
    }
  }

  void updateCurrentLocation(LatLng location) {
    // PERFORMANCE: Only update if location changed significantly (>20m)
    // This prevents cascading provider rebuilds from minor GPS fluctuations
    if (state.currentLocation != null) {
      final distance = Geolocator.distanceBetween(
        state.currentLocation!.latitude,
        state.currentLocation!.longitude,
        location.latitude,
        location.longitude,
      );

      // Ignore updates smaller than 20 meters (GPS noise)
      if (distance < 20) {
        return;
      }
    }

    state = state.copyWith(currentLocation: location);
  }

  Future<void> generateOptimizedRoute(
      {String? startLocationId, required DateTime selectedDate}) async {
    // Filter locations to only include those for the selected date.
    final allLocations = state.pinnedLocations;
    final locationsForDate = allLocations.where((loc) {
      if (loc.isSkipped) {
        return false;
      }
      if (loc.scheduledDate == null) {
        final addedAtDate =
            DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
        return selectedDate.isAtSameMomentAs(addedAtDate);
      }
      final locDate = loc.scheduledDate!;
      final scheduledDateAtMidnight =
          DateTime(locDate.year, locDate.month, locDate.day);
      return selectedDate.isAtSameMomentAs(scheduledDateAtMidnight);
    }).toList();

    if (locationsForDate.isEmpty) return;

    _ref.read(isGeneratingRouteProvider.notifier).state = true;

    try {
      // 1. Determine the starting point and the list of locations to be optimized.
      LatLng startPoint;
      List<LocationModel> locationsToOptimize = List.from(locationsForDate);
      String effectiveStartLocationId = '';

      if (startLocationId == 'current_location' &&
          state.currentLocation != null) {
        startPoint = state.currentLocation!;
        effectiveStartLocationId = 'current_location';
      } else if (startLocationId != null &&
          startLocationId != 'current_location') {
        // Find the start location. If it doesn't exist in the current day's list, this will be null.
        final startLocation = locationsForDate.firstWhere(
          (loc) => loc.id == startLocationId,
          orElse: () =>
              locationsForDate.first, // This was the source of the crash.
        );

        startPoint = startLocation.coordinates;
        effectiveStartLocationId = startLocation.id;
        // Ensure we only remove the location if it was the intended start, not a fallback.
        locationsToOptimize
            .removeWhere((loc) => loc.id == effectiveStartLocationId);
      } else {
        // This is the primary fallback logic. If no start location is specified, or if the
        // specified one is invalid (e.g., from a different date), we land here.
        if (state.currentLocation != null) {
          startPoint = state.currentLocation!;
          effectiveStartLocationId = 'current_location';
        } else {
          // This is the ultimate fallback: use the first location in the list.
          // The check at the top of the function ensures locationsForDate is not empty here.
          startPoint = locationsForDate.first.coordinates;
          effectiveStartLocationId = locationsForDate.first.id;
          locationsToOptimize.removeAt(0);
        }
      }
      state = state.copyWith(startLocationId: effectiveStartLocationId);

      if (locationsToOptimize.isEmpty) {
        clearOptimizedRoute();
        _ref.read(isGeneratingRouteProvider.notifier).state = false;
        return;
      }

      final proximityThreshold = _ref.read(proximityThresholdCommittedProvider);
      final clusters =
          ZoneUtils.clusterLocations(locationsToOptimize, proximityThreshold);

      List<List<LocationModel>> orderedClusters = [];
      LatLng currentPoint = startPoint;

      while (clusters.isNotEmpty) {
        List<LocationModel>? closestCluster;
        double minDistance = double.infinity;

        for (final cluster in clusters) {
          for (final location in cluster) {
            final distance = Geolocator.distanceBetween(
                currentPoint.latitude,
                currentPoint.longitude,
                location.coordinates.latitude,
                location.coordinates.longitude);
            if (distance < minDistance) {
              minDistance = distance;
              closestCluster = cluster;
            }
          }
        }

        if (closestCluster != null) {
          orderedClusters.add(closestCluster);
          clusters.remove(closestCluster);
          if (closestCluster.length > 1) {
            final clusterCenter = ZoneUtils.getClusterCenter(closestCluster);
            double maxDistFromCenter = -1;
            LocationModel? farthestPoint;
            for (final loc in closestCluster) {
              final dist = Geolocator.distanceBetween(
                  clusterCenter.latitude,
                  clusterCenter.longitude,
                  loc.coordinates.latitude,
                  loc.coordinates.longitude);
              if (dist > maxDistFromCenter) {
                maxDistFromCenter = dist;
                farthestPoint = loc;
              }
            }
            currentPoint =
                farthestPoint?.coordinates ?? closestCluster.last.coordinates;
          } else {
            currentPoint = closestCluster.first.coordinates;
          }
        } else {
          break;
        }
      }

      final finalOrderedWaypoints =
          orderedClusters.expand((cluster) => cluster).toList();

      LocationModel? destination =
          finalOrderedWaypoints.isNotEmpty ? finalOrderedWaypoints.last : null;
      List<LocationModel> intermediateWaypoints;

      if (finalOrderedWaypoints.isNotEmpty) {
        intermediateWaypoints = finalOrderedWaypoints.length > 1
            ? finalOrderedWaypoints.sublist(0, finalOrderedWaypoints.length - 1)
            : [];
      } else {
        intermediateWaypoints = [];
        // No waypoints, so no destination. The service call will handle this.
      }

      final routeResult = await GoogleMapsService.getOptimizedRouteDetails(
        origin: startPoint,
        destination: destination,
        waypoints: intermediateWaypoints,
        optimizeWaypoints: false,
      );

      final routePoints = routeResult['routePoints'] as List<LatLng>;
      final legDetails =
          routeResult['legDetails'] as List<Map<String, dynamic>>;
      final legPolylines = routeResult['legPolylines'] as List<List<LatLng>>;

      List<LocationModel> orderedWaypoints = List.from(finalOrderedWaypoints);

      List<LocationModel> finalOptimizedLocationsForDate =
          List.from(orderedWaypoints);

      if (startLocationId != null && startLocationId != 'current_location') {
        final startLocation =
            locationsForDate.firstWhere((loc) => loc.id == startLocationId);
        finalOptimizedLocationsForDate.insert(0, startLocation);
      }

      final Map<String, LocationModel> locationsById = {
        for (var loc in allLocations) loc.id: loc
      };

      for (int i = 0; i < legDetails.length; i++) {
        final leg = legDetails[i];
        if (i >= orderedWaypoints.length) continue;
        final destinationForThisLeg = orderedWaypoints[i];
        locationsById[destinationForThisLeg.id] =
            destinationForThisLeg.copyWith(
          travelTimeFromPrevious: leg['duration'] as Duration?,
          distanceFromPrevious: (leg['distance'] as num?)?.toDouble(),
        );
      }

      final otherDateLocations = state.pinnedLocations.where((loc) {
        if (loc.scheduledDate == null) {
          final addedAtDate =
              DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
          return !selectedDate.isAtSameMomentAs(addedAtDate);
        }
        final locDate = loc.scheduledDate!;
        final scheduledDateAtMidnight =
            DateTime(locDate.year, locDate.month, locDate.day);
        return !selectedDate.isAtSameMomentAs(scheduledDateAtMidnight);
      }).toList();

      final updatedLocationsForDate = finalOptimizedLocationsForDate
          .map((loc) => locationsById[loc.id] ?? loc)
          .toList();

      final skippedLocationsForDate = allLocations.where((loc) {
        if (!loc.isSkipped) return false;
        if (loc.scheduledDate == null) {
          final addedAtDate =
              DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
          return selectedDate.isAtSameMomentAs(addedAtDate);
        }
        final locDate = loc.scheduledDate!;
        final scheduledDateAtMidnight =
            DateTime(locDate.year, locDate.month, locDate.day);
        return selectedDate.isAtSameMomentAs(scheduledDateAtMidnight);
      }).toList();

      final updatedPinnedLocations = [
        ...otherDateLocations,
        ...updatedLocationsForDate,
        ...skippedLocationsForDate
      ];

      final totalTravelTime =
          _calculateTotalTime(finalOptimizedLocationsForDate, legDetails);
      final totalDistance = legDetails.fold(0.0,
          (sum, leg) => sum + ((leg['distance'] as num?)?.toDouble() ?? 0.0));

      state = state.copyWith(
        pinnedLocations: updatedPinnedLocations,
        optimizedLocationsForSelectedDate: finalOptimizedLocationsForDate,
        optimizedRoute: routePoints,
        legPolylines: legPolylines,
        legDetails: legDetails,
        totalTravelTime: totalTravelTime,
        totalDistance: totalDistance,
      );

      _saveLocations(updatedPinnedLocations);
      _ref.read(zoomToFitRouteTrigger.notifier).update((state) => state + 1);
    } catch (e) {
      log('Error generating route: $e');
    } finally {
      _ref.read(isGeneratingRouteProvider.notifier).state = false;
    }
  }

  Duration _calculateTotalTime(
      List<LocationModel> locations, List<Map<String, dynamic>> legDetails) {
    Duration totalTime = Duration.zero;

    // Sum travel time from all legs
    for (final detail in legDetails) {
      totalTime += detail['duration'] as Duration;
    }

    // Sum stay duration for all but the last location
    for (int i = 0; i < locations.length - 1; i++) {
      totalTime += locations[i].stayDuration;
    }
    return totalTime;
  }

  Future<void> saveCurrentTrip(String name) async {
    if (state.pinnedLocations.isEmpty) return;

    final trip = TripModel(
      id: const Uuid().v4(),
      name: name,
      locations: state.pinnedLocations,
      optimizedRoute: state.optimizedRoute,
      totalDuration: state.totalTravelTime,
      totalDistance: state.totalDistance,
      createdAt: DateTime.now(),
    );

    await StorageService.saveTrip(trip);
  }

  void clearOptimizedRoute() {
    // Clears only the route-specific data, preserving the locations list.
    // This is used when switching dates to prevent showing an old route.
    state = state.copyWith(
      optimizedRoute: [],
      optimizedLocationsForSelectedDate: [], // Clear optimized list
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
  }

  void clearTrip() {
    // Use copyWith to reset trip data while preserving the.
    state = state.copyWith(
      pinnedLocations: [],
      optimizedLocationsForSelectedDate: [], // Clear optimized list
      optimizedRoute: [],
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    _saveLocations([]);
  }

  void selectLeg(int? legIndex) {
    // If the same leg is tapped again, deselect it. Otherwise, select the new one.
    state = state.copyWith(
        selectedLegIndex: state.selectedLegIndex == legIndex ? null : legIndex);
  }
}

final tripProvider = StateNotifierProvider<TripNotifier, TripState>((ref) {
  return TripNotifier(ref);
});

// A simple provider to track the loading state of route generation
final isGeneratingRouteProvider = StateProvider<bool>((ref) => false);

// A provider to signal the UI to zoom to fit the optimized route
final zoomToFitRouteTrigger = StateProvider<int>((ref) => 0);

/// A provider that exposes details of the currently selected route leg.
/// The UI can watch this to show/hide the "Open in Maps" button.
final selectedLegDetailsProvider = Provider<Map<String, dynamic>?>((ref) {
  final tripState = ref.watch(tripProvider);
  final selectedIndex = tripState.selectedLegIndex;

  if (selectedIndex == null || selectedIndex >= tripState.legDetails.length) {
    return null;
  }

  final legDetail = tripState.legDetails[selectedIndex];
  final legPolyline = tripState.legPolylines[selectedIndex];

  // Calculate the midpoint of the polyline to position the button
  final midPoint = legPolyline[legPolyline.length ~/ 2];

  return {
    'start': legDetail['start_location'],
    'end': legDetail['end_location'],
    'midPoint': midPoint,
  };
});

// OPTIMIZATION: Cached provider to filter locations based on the selected date
// Uses keepAlive to prevent unnecessary recomputations during animations
final locationsForSelectedDateProvider = Provider<List<LocationModel>>((ref) {
  // PERFORMANCE: Watch only the specific fields we need, not the entire state
  final optimizedLocations = ref
      .watch(tripProvider.select((s) => s.optimizedLocationsForSelectedDate));
  final pinnedLocations =
      ref.watch(tripProvider.select((s) => s.pinnedLocations));
  final selectedDate = ref.watch(selectedDateProvider);

  // OPTIMIZATION: Early return if no locations at all
  if (pinnedLocations.isEmpty) return const [];

  // If an optimized route exists for the selected date, use it.
  // This check is crucial because optimizedLocationsForSelectedDate might hold data from a previous selectedDate.
  // We will now return the optimized list PLUS any skipped locations for that date.
  if (optimizedLocations.isNotEmpty) {
    final firstOptimizedLocDate = optimizedLocations.first.scheduledDate;
    bool dateMatches = false;
    if (firstOptimizedLocDate != null) {
      final optimizedDateAtMidnight = DateTime(firstOptimizedLocDate.year,
          firstOptimizedLocDate.month, firstOptimizedLocDate.day);
      dateMatches = selectedDate.isAtSameMomentAs(optimizedDateAtMidnight);
    } else {
      // If first optimized location has null scheduledDate, check using addedAt
      final firstOptimizedLoc = optimizedLocations.first;
      final addedAtDate = DateTime(firstOptimizedLoc.addedAt.year,
          firstOptimizedLoc.addedAt.month, firstOptimizedLoc.addedAt.day);
      dateMatches = selectedDate.isAtSameMomentAs(addedAtDate);
    }

    if (dateMatches) {
      // OPTIMIZATION: Use a Set for O(1) lookup instead of searching the list multiple times
      final optimizedIds = {for (var loc in optimizedLocations) loc.id};

      // Get skipped locations for the selected date, handling null scheduledDate
      final skippedForDate = pinnedLocations.where((loc) {
        // Skip if already in optimized list
        if (optimizedIds.contains(loc.id)) return false;
        if (!loc.isSkipped) return false;

        if (loc.scheduledDate == null) {
          final addedAtDate =
              DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
          return selectedDate.isAtSameMomentAs(addedAtDate);
        }
        final locDate = loc.scheduledDate!;
        final scheduledDateAtMidnight =
            DateTime(locDate.year, locDate.month, locDate.day);
        return selectedDate.isAtSameMomentAs(scheduledDateAtMidnight);
      }).toList();
      // Return the optimized locations first, followed by the skipped ones.
      return [...optimizedLocations, ...skippedForDate];
    }
  }

  // Fallback: filter from pinnedLocations if no optimized route or for a different date
  // OPTIMIZATION: Cache the selected date components to avoid recalculating in the loop
  final selectedYear = selectedDate.year;
  final selectedMonth = selectedDate.month;
  final selectedDay = selectedDate.day;

  return pinnedLocations.where((loc) {
    if (loc.scheduledDate == null) {
      // If a location somehow has a null date, associate it with the date it was added.
      // This prevents it from incorrectly showing up on the current day in the future.
      final addedAt = loc.addedAt;
      return selectedYear == addedAt.year &&
          selectedMonth == addedAt.month &&
          selectedDay == addedAt.day;
    }
    final locDate = loc.scheduledDate!;
    return selectedYear == locDate.year &&
        selectedMonth == locDate.month &&
        selectedDay == locDate.day;
  }).toList();
});

// Provider to get a set of all dates that have locations scheduled.
final datesWithLocationsProvider = Provider<Set<DateTime>>((ref) {
  final allLocations = ref.watch(tripProvider.select((s) => s.pinnedLocations));
  final Set<DateTime> dates = {};
  for (final loc in allLocations) {
    if (loc.scheduledDate != null) {
      final dateOnly = DateTime(loc.scheduledDate!.year,
          loc.scheduledDate!.month, loc.scheduledDate!.day);
      dates.add(dateOnly);
    }
  }
  return dates;
});
