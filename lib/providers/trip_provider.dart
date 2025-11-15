import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:geolocator/geolocator.dart';
import '../models/location_model.dart';
import '../models/trip_model.dart';
import '../services/storage_service.dart';
import '../providers/debounced_settings_provider.dart';
import '../utils/zone_utils.dart';
import '../services/google_maps_service.dart';

class TripState {
  final List<LocationModel> pinnedLocations;
  final List<LocationModel> optimizedLocationsForSelectedDate; // New field for the optimized order
  final List<LatLng> optimizedRoute;
  final List<List<LatLng>> legPolylines;
  final List<Map<String, dynamic>> legDetails;
  final LatLng? currentLocation;
  final Duration totalTravelTime;
  final double? currentHeading;
  final double totalDistance;
  String startLocationId;

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
    this.startLocationId = ''
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
  }) {
    return TripState(
      pinnedLocations: pinnedLocations ?? this.pinnedLocations,
      optimizedLocationsForSelectedDate: optimizedLocationsForSelectedDate ?? this.optimizedLocationsForSelectedDate,
      optimizedRoute: optimizedRoute ?? this.optimizedRoute,
      legPolylines: legPolylines ?? this.legPolylines,
      legDetails: legDetails ?? this.legDetails,
      currentLocation: currentLocation ?? this.currentLocation,
      totalTravelTime: totalTravelTime ?? this.totalTravelTime,
      currentHeading: currentHeading ?? this.currentHeading,
      totalDistance: totalDistance ?? this.totalDistance,
      startLocationId: startLocationId ?? this.startLocationId,
    );
  }

  // PERFORMANCE: Add equality checking to prevent unnecessary rebuilds
  // Riverpod uses == to determine if state changed
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is TripState &&
        _listEquals(other.pinnedLocations, pinnedLocations) &&
        _listEquals(other.optimizedLocationsForSelectedDate, optimizedLocationsForSelectedDate) &&
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
      Object.hashAll(optimizedLocationsForSelectedDate),
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
    // When adding a new location, the existing optimized route is no longer valid.
    // Clear it to ensure the UI reflects the new, un-optimized list.
    state = state.copyWith(
      pinnedLocations: updatedLocations,
      optimizedLocationsForSelectedDate: [],
      optimizedRoute: [],
      legDetails: [],
    );

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
      optimizedLocationsForSelectedDate: [],
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
      optimizedLocationsForSelectedDate: [], // Clear optimized list
      optimizedRoute: [],
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );

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
      // This logic now mirrors `locationsForSelectedDateProvider` exactly, and also filters out skipped locations.
      if (loc.isSkipped) {
        return false;
      }
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

      if (startLocationId == 'current_location' && state.currentLocation != null) {
        startPoint = state.currentLocation!;
        state.startLocationId = 'current_location';

        // All locations for the date are waypoints
        // locationsToOptimize remains as is.
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
          // To find the next closest cluster, we need a better heuristic for the next "currentPoint".
          // Instead of just taking the last item, find the point in the cluster that is
          // "on the edge" or farthest from the cluster's center, which likely represents
          // a good exit point from that zone.
          if (closestCluster.length > 1) {
            final clusterCenter = ZoneUtils.getClusterCenter(closestCluster);
            double maxDistFromCenter = -1;
            LocationModel? farthestPoint;
            for (final loc in closestCluster) {
              final dist = Geolocator.distanceBetween(clusterCenter.latitude, clusterCenter.longitude, loc.coordinates.latitude, loc.coordinates.longitude);
              if (dist > maxDistFromCenter) {
                maxDistFromCenter = dist;
                farthestPoint = loc;
              }
            }
            currentPoint = farthestPoint?.coordinates ?? closestCluster.last.coordinates;
          } else {
            // If only one location in the cluster, that's our next point.
            currentPoint = closestCluster.first.coordinates;
          }
        } else {
          break; // Should not happen if clusters is not empty
        }
      }

      // 4. Flatten the ordered clusters into a single list of waypoints.
      // This list is now ordered by cluster proximity.
      final finalOrderedWaypoints = orderedClusters.expand((cluster) => cluster).toList();

      // Separate the final destination from the intermediate waypoints.
      // The last location in our custom-ordered list is the destination.
      LocationModel? destination;
      List<LocationModel> intermediateWaypoints = [];

      if (finalOrderedWaypoints.isNotEmpty) {
        destination = finalOrderedWaypoints.last;
        intermediateWaypoints = finalOrderedWaypoints.length > 1 ? finalOrderedWaypoints.sublist(0, state.startLocationId == 'current_location' ? finalOrderedWaypoints.length : finalOrderedWaypoints.length - 1) : [];
      }
      // 5. Get the route from Google Maps, but WITHOUT waypoint optimization,
      // as we have already defined our custom order.
      // Always pass the destination when it exists, regardless of start location type.
      // This ensures the route connects to the final location even when starting from current location.
      final routeResult = await GoogleMapsService.getOptimizedRouteDetails(
        origin: startPoint,
        destination: destination,
        waypoints: intermediateWaypoints,
        // We use our custom order, so Google's TSP solver is not needed.
        optimizeWaypoints: false,
      );

      final routePoints = routeResult['routePoints'] as List<LatLng>;
      final legDetails = routeResult['legDetails'] as List<Map<String, dynamic>>;
      final legPolylines = routeResult['legPolylines'] as List<List<LatLng>>;

      // 4. Reconstruct the final, ordered list of locations based on Google's response.
      final waypointOrder = routeResult['waypointOrder'] as List<int>? ?? [];
      List<LocationModel> orderedWaypoints = [];
      if (waypointOrder.isNotEmpty) {
        orderedWaypoints = waypointOrder.map((index) => intermediateWaypoints[index]).toList();
      }
      // Add the destination back to the end of the ordered list.
      // if (destination != null) {
      //   orderedWaypoints.add(destination);
      // }

      // This is the definitive, optimized list of locations for the day's trip.
      List<LocationModel> finalOptimizedLocationsForDate = List.from(orderedWaypoints);

      // If the start location was a specific stop (not 'current_location'),
      // prepend it to the final list so it appears first.
      if (startLocationId != null && startLocationId != 'current_location') {
        final startLocation = locationsForDate.firstWhere((loc) => loc.id == startLocationId);
        finalOptimizedLocationsForDate.insert(0, startLocation);
      }

      // Add travel details to each location
      final Map<String, LocationModel> locationsById = {for (var loc in allLocations) loc.id: loc};
      Duration totalTravelTime = Duration.zero;
      double totalDistance = 0.0;
      
      // 5. Iterate through the route legs and assign travel details to each destination in our final ordered list.
      for (int i = 0; i < legDetails.length; i++) {
        final leg = legDetails[i];
        // The destination for the i-th leg is the i-th location in the `orderedWaypoints` list.
        if (i >= orderedWaypoints.length) continue; // Safety check
        final destinationForThisLeg = orderedWaypoints[i];
        locationsById[destinationForThisLeg.id] = destinationForThisLeg.copyWith(
          travelTimeFromPrevious: leg['duration'] as Duration?,
          distanceFromPrevious: (leg['distance'] as num?)?.toDouble(),
        );
      }

      // Reconstruct the master list of all pinned locations to persist the new order.
      // 1. Get all locations that are NOT for the selected date.
      final otherDateLocations = state.pinnedLocations.where((loc) {
        if (loc.scheduledDate == null) {
          final addedAtDate = DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
          return !selectedDate.isAtSameMomentAs(addedAtDate);
        }
        final locDate = loc.scheduledDate!;
        final scheduledDateAtMidnight = DateTime(locDate.year, locDate.month, locDate.day);
        return !selectedDate.isAtSameMomentAs(scheduledDateAtMidnight);
      }).toList();

      // 2. Get the newly ordered and updated locations for the current date (non-skipped only).
      final updatedLocationsForDate = finalOptimizedLocationsForDate.map((loc) => locationsById[loc.id] ?? loc).toList();

      // 3. Get skipped locations for the selected date (these should remain visible but not in the route).
      final skippedLocationsForDate = allLocations.where((loc) {
        if (!loc.isSkipped) return false;
        if (loc.scheduledDate == null) {
          final addedAtDate = DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
          return selectedDate.isAtSameMomentAs(addedAtDate);
        }
        final locDate = loc.scheduledDate!;
        final scheduledDateAtMidnight = DateTime(locDate.year, locDate.month, locDate.day);
        return selectedDate.isAtSameMomentAs(scheduledDateAtMidnight);
      }).toList();

      // 4. Combine them into the new master list. This preserves the optimized order and includes skipped locations.
      final updatedPinnedLocations = [...otherDateLocations, ...updatedLocationsForDate, ...skippedLocationsForDate];
      
      // Recalculate total time including stay durations
      totalTravelTime = _calculateTotalTime(finalOptimizedLocationsForDate, legDetails);
      totalDistance = legDetails.fold(0.0, (sum, leg) => sum + ((leg['distance'] as num?)?.toDouble() ?? 0.0));

      // OPTIMIZED: Only update state once with all changes
      state = state.copyWith(
        // Update pinnedLocations with travel details, but maintain original order for non-optimized.
        // The optimizedLocationsForSelectedDate will hold the actual optimized order.
        pinnedLocations: updatedPinnedLocations,
        // Store the actual optimized list for the selected date
        optimizedLocationsForSelectedDate: finalOptimizedLocationsForDate,
        optimizedRoute: routePoints,
        legPolylines: legPolylines,
        legDetails: legDetails,
        totalTravelTime: totalTravelTime,
        totalDistance: totalDistance,
      );

      // Save to storage asynchronously without blocking UI (saves updatedPinnedLocations)
      _saveLocations(updatedPinnedLocations);

      // Trigger the UI to zoom to fit the new route
      _ref.read(zoomToFitRouteTrigger.notifier).update((state) => state + 1);
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
      optimizedLocationsForSelectedDate: [], // Clear optimized list
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
      optimizedLocationsForSelectedDate: [], // Clear optimized list
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

// A provider to signal the UI to zoom to fit the optimized route
final zoomToFitRouteTrigger = StateProvider<int>((ref) => 0);

// Provider to filter locations based on the selected date
final locationsForSelectedDateProvider = Provider<List<LocationModel>>((ref) {
  final tripState = ref.watch(tripProvider);
  final selectedDate = ref.watch(selectedDateProvider);

  // If an optimized route exists for the selected date, use it.
  // This check is crucial because optimizedLocationsForSelectedDate might hold data from a previous selectedDate.
  // We will now return the optimized list PLUS any skipped locations for that date.
  if (tripState.optimizedLocationsForSelectedDate.isNotEmpty) {
    final firstOptimizedLocDate = tripState.optimizedLocationsForSelectedDate.first.scheduledDate;
    bool dateMatches = false;
    if (firstOptimizedLocDate != null) {
      final optimizedDateAtMidnight = DateTime(firstOptimizedLocDate.year, firstOptimizedLocDate.month, firstOptimizedLocDate.day);
      dateMatches = selectedDate.isAtSameMomentAs(optimizedDateAtMidnight);
    } else {
      // If first optimized location has null scheduledDate, check using addedAt
      final firstOptimizedLoc = tripState.optimizedLocationsForSelectedDate.first;
      final addedAtDate = DateTime(firstOptimizedLoc.addedAt.year, firstOptimizedLoc.addedAt.month, firstOptimizedLoc.addedAt.day);
      dateMatches = selectedDate.isAtSameMomentAs(addedAtDate);
    }
    
    if (dateMatches) {
      // Get skipped locations for the selected date, handling null scheduledDate
      final skippedForDate = tripState.pinnedLocations.where((loc) {
        if (!loc.isSkipped) return false;
        if (loc.scheduledDate == null) {
          final addedAtDate = DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
          return selectedDate.isAtSameMomentAs(addedAtDate);
        }
        final locDate = loc.scheduledDate!;
        final scheduledDateAtMidnight = DateTime(locDate.year, locDate.month, locDate.day);
        return selectedDate.isAtSameMomentAs(scheduledDateAtMidnight);
      }).toList();
      // Return the optimized locations first, followed by the skipped ones.
      return [...tripState.optimizedLocationsForSelectedDate, ...skippedForDate];
    }
  }

  // Fallback: filter from pinnedLocations if no optimized route or for a different date
  return tripState.pinnedLocations.where((loc) {
    if (loc.scheduledDate == null) {
      // If a location somehow has a null date, associate it with the date it was added.
      // This prevents it from incorrectly showing up on the current day in the future.
      final addedAtDate = DateTime(loc.addedAt.year, loc.addedAt.month, loc.addedAt.day);
      return selectedDate.isAtSameMomentAs(addedAtDate);
    }
    return DateTime(loc.scheduledDate!.year, loc.scheduledDate!.month, loc.scheduledDate!.day).isAtSameMomentAs(selectedDate);
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