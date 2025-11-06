import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:tripflow/providers/map_ui_state_provider.dart';
import 'package:geolocator/geolocator.dart';
import '../models/location_model.dart';
import '../models/trip_model.dart';
import '../services/storage_service.dart';
import '../providers/debounced_settings_provider.dart';
import '../utils/zone_utils.dart';
import '../services/google_maps_service.dart';

class TripState {
  final List<LocationModel> pinnedLocations;
  final List<LatLng> optimizedRoute;
  final List<List<LatLng>> legPolylines;
  final List<Map<String, dynamic>> legDetails;
  final LatLng? currentLocation;
  final Duration totalTravelTime;
  final double? currentHeading;
  final double totalDistance;

  TripState({
    this.pinnedLocations = const [],
    this.optimizedRoute = const [],
    this.legPolylines = const [],
    this.legDetails = const [],
    this.currentLocation,
    this.totalTravelTime = Duration.zero,
    this.currentHeading,
    this.totalDistance = 0.0,
  });

  TripState copyWith({
    List<LocationModel>? pinnedLocations,
    List<LatLng>? optimizedRoute,
    List<List<LatLng>>? legPolylines,
    List<Map<String, dynamic>>? legDetails,
    LatLng? currentLocation,
    Duration? totalTravelTime,
    double? currentHeading,
    double? totalDistance,
  }) {
    return TripState(
      pinnedLocations: pinnedLocations ?? this.pinnedLocations,
      optimizedRoute: optimizedRoute ?? this.optimizedRoute,
      legPolylines: legPolylines ?? this.legPolylines,
      legDetails: legDetails ?? this.legDetails,
      currentLocation: currentLocation ?? this.currentLocation,
      totalTravelTime: totalTravelTime ?? this.totalTravelTime,
      currentHeading: currentHeading ?? this.currentHeading,
      totalDistance: totalDistance ?? this.totalDistance,
    );
  }

  // PERFORMANCE: Add equality checking to prevent unnecessary rebuilds
  // Riverpod uses == to determine if state changed
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is TripState &&
        _listEquals(other.pinnedLocations, pinnedLocations) &&
        _listEquals(other.optimizedRoute, optimizedRoute) &&
        other.currentLocation == currentLocation &&
        other.totalTravelTime == totalTravelTime &&
        other.totalDistance == totalDistance;
    // Note: Deliberately excluding legPolylines and legDetails from equality
    // to keep the check fast. They change together with optimizedRoute anyway.
  }

  @override
  int get hashCode {
    return Object.hash(
      Object.hashAll(pinnedLocations),
      Object.hashAll(optimizedRoute),
      currentLocation,
      totalTravelTime,
      totalDistance,
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
    state = state.copyWith(pinnedLocations: updatedLocations);

    // Save to storage asynchronously without blocking
    _saveLocations(updatedLocations);
  }

  Future<void> removeLocation(String locationId) async {
    final updatedLocations = state.pinnedLocations
        .where((loc) => loc.id != locationId)
        .toList();
    
    // Clear optimized route data when a location is removed
    state = state.copyWith(
      pinnedLocations: updatedLocations,
      optimizedRoute: [],
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    
    await _saveLocations(updatedLocations);
  }

  Future<void> removeMultipleLocations(Set<String> locationIds) async {
    final updatedLocations = state.pinnedLocations
        .where((loc) => !locationIds.contains(loc.id))
        .toList();

    // Clear optimized route data when locations are removed
    state = state.copyWith(
      pinnedLocations: updatedLocations,
      optimizedRoute: [],
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );

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
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    
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

  Future<void> updateLocationStayDuration(String locationId, Duration newDuration) async {
    final updatedLocations = state.pinnedLocations.map((loc) {
      if (loc.id == locationId) {
        return loc.copyWith(stayDuration: newDuration);
      }
      return loc;
    }).toList();

    // Recalculate total travel time
    final newTotalTravelTime = _calculateTotalTime(updatedLocations, state.legDetails);

    state = state.copyWith(
      pinnedLocations: updatedLocations,
      totalTravelTime: newTotalTravelTime,
    );
    await _saveLocations(updatedLocations);
  }

  Future<void> updateLocationScheduledDate(String locationId, DateTime newDate) async {
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

  Future<void> updateMultipleLocationsScheduledDate(Set<String> locationIds, DateTime newDate) async {
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

  Future<void> copyMultipleLocationsToDate(Set<String> locationIds, DateTime newDate) async {
    final locationsToCopy = state.pinnedLocations.where((loc) => locationIds.contains(loc.id)).toList();

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

  Future<void> generateOptimizedRoute({String? startLocationId, required DateTime selectedDate}) async {
    // Filter locations to only include those for the selected date.
    final allLocations = state.pinnedLocations;
    final locationsForDate = allLocations.where((loc) {
      // This logic now mirrors `locationsForSelectedDateProvider` exactly.
      if (loc.scheduledDate == null) {
        final addedAtDate = DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
        return selectedDate.isAtSameMomentAs(addedAtDate);
      }
      final locDate = loc.scheduledDate!;
      final scheduledDateAtMidnight = DateTime(locDate.year, locDate.month, locDate.day);
      return selectedDate.isAtSameMomentAs(scheduledDateAtMidnight);
    }).toList();

    if (locationsForDate.isEmpty) return;

    _ref.read(isGeneratingRouteProvider.notifier).state = true;

    try {
      // 1. Determine the starting point and the list of locations to be optimized.
      LatLng startPoint;
      List<LocationModel> locationsToOptimize = List.from(locationsForDate);
      bool isUsingCurrentLocation = false;

      if (startLocationId == 'current_location' && state.currentLocation != null) {
        startPoint = state.currentLocation!;
        isUsingCurrentLocation = true;
        // All locations for the date are waypoints
      } else if (startLocationId != null) {
        // The start location must be one of the locations for the selected date.
        final startLocation = locationsForDate.firstWhere((loc) => loc.id == startLocationId);
        startPoint = startLocation.coordinates;
        // Remove start location from waypoints to be optimized
        locationsToOptimize.removeWhere((loc) => loc.id == startLocationId);
      } else {
        // Default behavior: use current location if available, else first location for the date.
        if (state.currentLocation != null) {
          startPoint = state.currentLocation!;
          isUsingCurrentLocation = true;
        } else {
          startPoint = locationsForDate.first.coordinates;
          locationsToOptimize.removeAt(0);
        }
      }

      if (locationsToOptimize.isEmpty) {
        // If there's nothing to optimize (e.g., only a start point was selected), clear the route.
        clearOptimizedRoute();
        return;
      }

      // 2. Group locations into clusters based on proximity.
      final proximityThreshold = _ref.read(proximityThresholdCommittedProvider);
      final clusters = ZoneUtils.clusterLocations(locationsToOptimize, proximityThreshold);

      // 3. Order the clusters. Find the closest cluster to the start point, then the next closest, and so on.
      List<List<LocationModel>> orderedClusters = [];
      LatLng currentPoint = startPoint;

      while (clusters.isNotEmpty) {
        // Find the cluster with the minimum distance from the current point.
        List<LocationModel>? closestCluster;
        double minDistance = double.infinity;

        for (final cluster in clusters) {
          for (final location in cluster) {
            final distance = Geolocator.distanceBetween(
              currentPoint.latitude, currentPoint.longitude,
              location.coordinates.latitude, location.coordinates.longitude
            );
            if (distance < minDistance) {
              minDistance = distance;
              closestCluster = cluster;
            }
          }
        }

        if (closestCluster != null) {
          orderedClusters.add(closestCluster);
          clusters.remove(closestCluster);
          // To find the next closest cluster, we can approximate the next "currentPoint"
          // by using the last location of the cluster we just added. This is a heuristic.
          currentPoint = closestCluster.last.coordinates;
        } else {
          break; // Should not happen if clusters is not empty
        }
      }

      // 4. Flatten the ordered clusters into a single list of waypoints.
      // This list is now ordered by cluster proximity.
      final finalOrderedWaypoints = orderedClusters.expand((cluster) => cluster).toList();

      // 5. Get the route from Google Maps, but WITHOUT waypoint optimization,
      // as we have already defined our custom order.
      final routeResult = await GoogleMapsService.getOptimizedRouteDetails(
        origin: startPoint,
        destinations: finalOrderedWaypoints,
        // We use our custom order, not Google's TSP solver.
        optimizeWaypoints: false,
      );

      final routePoints = routeResult['routePoints'] as List<LatLng>;
      final waypointOrder = routeResult['waypointOrder'] as List<int>;
      final legDetails = routeResult['legDetails'] as List<Map<String, dynamic>>;
      final legPolylines = routeResult['legPolylines'] as List<List<LatLng>>;

      // The final ordered list of locations for the day's trip.
      // This list respects our custom cluster-based ordering.
      List<LocationModel> orderedTripLocations = [];
      // The `waypointOrder` from Google will just be a sequence [0, 1, 2, ...]
      // because we set `optimizeWaypoints: false`. We use our `finalOrderedWaypoints`.
      final orderedWaypoints = finalOrderedWaypoints;
      if (startLocationId != null && startLocationId != 'current_location') {
        final startLocation = locationsForDate.firstWhere((loc) => loc.id == startLocationId);
        orderedTripLocations = [startLocation, ...orderedWaypoints];
      } else {
        orderedTripLocations = orderedWaypoints;
      }

      // Add travel details to each location
      List<LocationModel> locationsWithDetails = [];
      Duration totalTravelTime = Duration.zero;
      double totalDistance = 0.0;

      // Create a map of all original locations by ID for easy lookup
      final originalLocationsMap = {for (var loc in allLocations) loc.id: loc};
      
      // Iterate through the correctly ordered trip locations and assign travel details.
      for (int i = 0; i < orderedTripLocations.length; i++) {
        final location = orderedTripLocations[i];
        Duration? travelTime;
        double? distance;

        // The leg index depends on whether we started from a pinned location or current location.
        final legIndex = (startLocationId != null && startLocationId != 'current_location') ? i - 1 : i;

        if (legIndex >= 0 && legIndex < legDetails.length) {
          travelTime = legDetails[legIndex]['duration'] as Duration?;
          distance = (legDetails[legIndex]['distance'] as num?)?.toDouble();
        }

        locationsWithDetails.add(location.copyWith(
          travelTimeFromPrevious: travelTime,
          distanceFromPrevious: distance,
        ));
      }

      // Create a map of the updated locations with travel details.
      final updatedDetailsMap = {for (var loc in locationsWithDetails) loc.id: loc};

      // Separate locations for the current date from other dates.
      final locationsForOtherDates = allLocations.where((loc) {
        final locDate = loc.scheduledDate != null
            ? DateTime(loc.scheduledDate!.year, loc.scheduledDate!.month, loc.scheduledDate!.day)
            : DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
        return !selectedDate.isAtSameMomentAs(locDate);
      }).toList();

      // The new `pinnedLocations` list should be the newly ordered locations for the current date,
      // plus all the locations from other dates. This preserves the order for the optimized date
      // while leaving others untouched.
      final finalLocationsList = [
        ...locationsWithDetails,
        ...locationsForOtherDates,
      ];

      // Recalculate total time including stay durations
      totalTravelTime = _calculateTotalTime(locationsWithDetails, legDetails);
      totalDistance = legDetails.fold(0.0, (sum, leg) => sum + ((leg['distance'] as num?)?.toDouble() ?? 0.0));

      // OPTIMIZED: Only update state once with all changes
      state = state.copyWith(
        pinnedLocations: finalLocationsList,
        optimizedRoute: routePoints,
        legPolylines: legPolylines,
        legDetails: legDetails,
        totalTravelTime: totalTravelTime,
        totalDistance: totalDistance,
      );

      // Save to storage asynchronously without blocking UI
      _saveLocations(finalLocationsList);
    } catch (e) {
      print('Error generating route: $e');
    } finally {
      _ref.read(isGeneratingRouteProvider.notifier).state = false;
    }
  }

  Duration _calculateTotalTime(List<LocationModel> locations, List<Map<String, dynamic>> legDetails) {
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
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
  }

  void clearTrip() {
    // Use copyWith to reset trip data while preserving the current location and heading.
    state = state.copyWith(
      pinnedLocations: [],
      optimizedRoute: [],
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    _saveLocations([]);
  }
}

final tripProvider = StateNotifierProvider<TripNotifier, TripState>((ref) {
  return TripNotifier(ref);
});

// A simple provider to track the loading state of route generation
final isGeneratingRouteProvider = StateProvider<bool>((ref) => false);

// Provider to filter locations based on the selected date
final locationsForSelectedDateProvider = Provider<List<LocationModel>>((ref) {
  final allLocations = ref.watch(tripProvider.select((s) => s.pinnedLocations));
  final selectedDate = ref.watch(selectedDateProvider);

  return allLocations.where((loc) {
    if (loc.scheduledDate == null) {
      // If a location somehow has a null date, associate it with the date it was added.
      // This prevents it from incorrectly showing up on the current day in the future.
      final addedAtDate = DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
      return selectedDate.isAtSameMomentAs(addedAtDate);
    }
    // Compare just the date part, ignoring time
    final locDate = loc.scheduledDate!;
    final scheduledDateAtMidnight = DateTime(locDate.year, locDate.month, locDate.day);
    return selectedDate.isAtSameMomentAs(scheduledDateAtMidnight);
  }).toList();
});

// Provider to get a set of all dates that have locations scheduled.
final datesWithLocationsProvider = Provider<Set<DateTime>>((ref) {
  final allLocations = ref.watch(tripProvider.select((s) => s.pinnedLocations));
  final Set<DateTime> dates = {};
  for (final loc in allLocations) {
    if (loc.scheduledDate != null) {
      final dateOnly = DateTime(loc.scheduledDate!.year, loc.scheduledDate!.month, loc.scheduledDate!.day);
      dates.add(dateOnly);
    }
  }
  return dates;
});