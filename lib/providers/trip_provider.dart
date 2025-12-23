import 'dart:developer';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:geolocator/geolocator.dart';
import '../models/location_model.dart';
import '../models/trip_model.dart';
import '../models/trip.dart';
import '../services/google_maps_service.dart';
import '../services/storage_service.dart';
import '../providers/debounced_settings_provider.dart';
import '../utils/zone_utils.dart';
import '../utils/isolate_utils.dart';
import '../models/saved_location.dart';
import 'location_provider.dart';
import 'trip_listener_provider.dart';
import 'trip_collaborator_provider.dart';

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
  
  // OPTIMIZATION: Debounce timer for route generation to prevent excessive recalculation
  Timer? _routeOptimizationDebounceTimer;
  
  // OPTIMIZATION: Cache for today's date to avoid repeated DateTime calculations
  late DateTime _cachedToday;
  DateTime? _cachedTodayDate;

  TripNotifier(this._ref) : super(TripState()) {
    _initSyncListener();
    _updateCachedToday();
  }

  /// Get today's date, cached and updated only when needed
  DateTime get today {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    // Invalidate cache if day has changed
    if (_cachedTodayDate != today) {
      _cachedToday = today;
      _cachedTodayDate = today;
    }
    return _cachedToday;
  }

  void _updateCachedToday() {
    final now = DateTime.now();
    _cachedToday = DateTime(now.year, now.month, now.day);
    _cachedTodayDate = _cachedToday;
  }

  /// Check if user has write access to the active trip
  /// Returns true if no trip is active (user can edit their own locations)
  /// or if user is owner/has write permission on the active trip
  Future<bool> _hasWriteAccess() async {
    final activeTripAsync = _ref.read(realtimeActiveTripProvider);
    final activeTrip = activeTripAsync.asData?.value;

    // No active trip - user can edit their own non-trip locations
    if (activeTrip == null) return true;

    // Check if user is owner
    final isOwner = await _ref.read(isTripOwnerProvider(activeTrip.id).future);
    if (isOwner) return true;

    // Check if user has write permission
    final permission = await _ref.read(userTripPermissionProvider(activeTrip.id).future);
    return permission == 'write';
  }

  void _initSyncListener() {
    // Instead, watch the full AsyncValue and extract the trip manually
    _ref.listen<AsyncValue<Trip?>>(
      realtimeActiveTripProvider,
      (prev, next) {
        final prevTrip = prev?.asData?.value;
        final nextTrip = next.asData?.value;

        final prevId = prevTrip?.id;
        final nextId = nextTrip?.id;

        debugPrint('🔍 Trip ID changed: prev=$prevId → next=$nextId');

        // Only update if the trip ID actually changed
        if (prevId != nextId) {
          if (nextTrip != null) {
            // Trip was activated or switched
            debugPrint(
                '🟢 TripNotifier: Trip ACTIVATED - ${nextTrip.name} (${nextTrip.id})');
          } else {
            // Trip was deactivated
            debugPrint(
                '🔴 TripNotifier: Trip DEACTIVATED - clearing all locations');
            // Trip was deactivated, clear all pinned locations immediately
            state = state.copyWith(
              pinnedLocations: [],
              optimizedLocationsForSelectedDate: [],
              optimizedRoute: [],
              legPolylines: [],
              legDetails: [],
              totalTravelTime: Duration.zero,
              totalDistance: 0.0,
            );
          }
        }
      },
    );

    // Listen to filtered locations based on active trip
    // When trip active: shows only that trip's locations
    // When no trip active: shows empty list
    _ref.listen<AsyncValue<List<SavedLocation>>>(
        filteredLocationsForMapProvider, (prev, next) {
      next.whenData((filteredLocations) {
        debugPrint(
            '📍 TripNotifier._initSyncListener: Received ${filteredLocations.length} filtered locations');

        // Convert SavedLocation list to LocationModel list
        final newPinnedLocations = filteredLocations.map((saved) {
          return LocationModel(
            id: saved.id,
            name: saved.name,
            address: '', // Address not available from SavedLocation
            coordinates: LatLng(saved.lat, saved.lng),
            addedAt: saved.createdAt,
            scheduledDate:
                saved.scheduledDate ?? _ref.read(selectedDateProvider),
            isSkipped: saved.isSkipped,
            stayDuration: Duration(seconds: saved.stayDuration),
          );
        }).toList();

        debugPrint(
            '✅ TripNotifier._initSyncListener: Converted to ${newPinnedLocations.length} LocationModel objects');

        // Update state with filtered locations from active trip
        state = state.copyWith(
          pinnedLocations: newPinnedLocations,
          // Clear optimized route when locations change (different trip's locations)
          optimizedLocationsForSelectedDate: [],
          optimizedRoute: [],
          legPolylines: [],
          legDetails: [],
          totalTravelTime: Duration.zero,
          totalDistance: 0.0,
        );
      });
    });
  }

  Future<void> addLocation(LocationModel location) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('addLocation: Permission denied - user does not have write access');
      return;
    }

    final selectedDate = _ref.read(selectedDateProvider);

    // Ensure the new location has the currently selected date if it doesn't have one.
    final locationWithDate = location.scheduledDate == null
        ? location.copyWith(scheduledDate: selectedDate)
        : location;

    // Note: pinnedLocations is synced from filteredLocationsForMapProvider
    // When we add the location, the filter will automatically update
    // So we don't update state here - it will be updated by _initSyncListener

    try {
      // Get the REALTIME active trip to associate this location with it
      // This ensures we use the most up-to-date trip state
      final activeTripAsync = _ref.read(realtimeActiveTripProvider);
      final activeTrip = activeTripAsync.asData?.value;

      final savedLoc = SavedLocation(
        id: locationWithDate.id,
        name: locationWithDate.name,
        lat: locationWithDate.coordinates.latitude,
        lng: locationWithDate.coordinates.longitude,
        createdAt: locationWithDate.addedAt,
        scheduledDate: locationWithDate.scheduledDate,
        stayDuration: locationWithDate.stayDuration.inSeconds,
        isSkipped: locationWithDate.isSkipped,
        // IMPORTANT: Set tripId if a trip is active, null if no trip is active
        tripId: activeTrip?.id,
        // userId and fingerprint will be handled by repository based on auth state
        userId: '',
        fingerprint: '',
      );

      debugPrint('addLocation: Adding location "${savedLoc.name}" with tripId=${savedLoc.tripId ?? "null (no trip)"}');
      await _ref.read(locationRepositoryProvider).addLocation(savedLoc);

      // Clear optimized route when location is added
      state = state.copyWith(
        optimizedLocationsForSelectedDate: [],
        optimizedRoute: [],
        legPolylines: [],
        legDetails: [],
        totalTravelTime: Duration.zero,
        totalDistance: 0.0,
      );
      selectLeg(null);
    } catch (e) {
      log('Error saving to repository: $e');
    }
  }

  /// Associates existing locations with a trip
  Future<void> addLocationsToTrip(
      List<String> locationIds, String tripId) async {
    // Permission check - must have write access to the target trip
    final isOwner = await _ref.read(isTripOwnerProvider(tripId).future);
    if (!isOwner) {
      final permission = await _ref.read(userTripPermissionProvider(tripId).future);
      if (permission != 'write') {
        debugPrint('addLocationsToTrip: Permission denied - user does not have write access to trip $tripId');
        return;
      }
    }

    try {
      final repository = _ref.read(locationRepositoryProvider);

      // Update each location to associate with the trip
      for (final locationId in locationIds) {
        await repository.updateLocation(locationId, {'trip_id': tripId});
      }

      // The locations stream will automatically update and filter via filteredLocationsForMapProvider
    } catch (e) {
      log('Error adding locations to trip: $e');
    }
  }

  /// Removes locations from a trip (sets trip_id to null)
  Future<void> removeLocationsFromTrip(List<String> locationIds) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('removeLocationsFromTrip: Permission denied - user does not have write access');
      return;
    }

    try {
      final repository = _ref.read(locationRepositoryProvider);

      for (final locationId in locationIds) {
        await repository.updateLocation(locationId, {'trip_id': null});
      }
    } catch (e) {
      log('Error removing locations from trip: $e');
    }
  }

  Future<void> removeLocation(String locationId) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('removeLocation: Permission denied - user does not have write access');
      return;
    }

    // Clear optimized route data when a location is removed
    state = state.copyWith(
      optimizedLocationsForSelectedDate: [],
      optimizedRoute: [],
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    selectLeg(null); // Clear selected leg

    // Sync deletion with Repository
    // This will trigger filteredLocationsForMapProvider to update pinnedLocations
    try {
      await _ref.read(locationRepositoryProvider).deleteLocation(locationId);
    } catch (e) {
      log('Error deleting from repository: $e');
    }
  }

  Future<void> removeMultipleLocations(Set<String> locationIds) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('removeMultipleLocations: Permission denied - user does not have write access');
      return;
    }

    // Clear optimized route data when locations are removed
    state = state.copyWith(
      optimizedLocationsForSelectedDate: [], // Clear optimized list
      optimizedRoute: [],
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    selectLeg(null); // Clear selected leg

    // Sync multiple deletions with Repository
    // This will trigger filteredLocationsForMapProvider to update pinnedLocations
    final repository = _ref.read(locationRepositoryProvider);
    for (final id in locationIds) {
      try {
        await repository.deleteLocation(id);
      } catch (e) {
        log('Error deleting from repository for id $id: $e');
      }
    }
  }

  Future<void> skipMultipleLocations(Set<String> locationIds) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('skipMultipleLocations: Permission denied - user does not have write access');
      return;
    }

    // Clear optimized route
    state = state.copyWith(
      optimizedRoute: [],
      optimizedLocationsForSelectedDate: [], // Clear optimized list
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    selectLeg(null); // Clear selected leg

    // Sync skip status with Repository
    final repository = _ref.read(locationRepositoryProvider);
    for (final id in locationIds) {
      try {
        await repository.updateLocation(id, {'is_skipped': true});
      } catch (e) {
        log('Error skipping location in repository for id $id: $e');
      }
    }
  }

  Future<void> unskipMultipleLocations(Set<String> locationIds) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('unskipMultipleLocations: Permission denied - user does not have write access');
      return;
    }

    // Clear optimized route
    state = state.copyWith(
      optimizedRoute: [],
      optimizedLocationsForSelectedDate: [], // Clear optimized list
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    selectLeg(null); // Clear selected leg

    // Sync unskip status with Repository
    final repository = _ref.read(locationRepositoryProvider);
    for (final id in locationIds) {
      try {
        await repository.updateLocation(id, {'is_skipped': false});
      } catch (e) {
        log('Error unskipping location in repository for id $id: $e');
      }
    }
  }

  Future<void> reorderLocation(int oldIndex, int newIndex) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('reorderLocation: Permission denied - user does not have write access');
      return;
    }

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
  }

  Future<void> updateLocationName(String locationId, String newName) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('updateLocationName: Permission denied - user does not have write access');
      return;
    }

    final updatedLocations = state.pinnedLocations.map((loc) {
      if (loc.id == locationId) {
        // Return a new LocationModel with the updated name
        return loc.copyWith(name: newName);
      }
      return loc;
    }).toList();

    state = state.copyWith(pinnedLocations: updatedLocations);

    // Sync with Repository
    try {
      await _ref
          .read(locationRepositoryProvider)
          .updateLocation(locationId, {'name': newName});
    } catch (e) {
      log('Error updating name in repository: $e');
    }
  }

  Future<void> updateLocationStayDuration(
      String locationId, Duration newDuration) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('updateLocationStayDuration: Permission denied - user does not have write access');
      return;
    }

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

    print("Stay For: " + newDuration.inSeconds.toString());

    // Sync with Repository
    try {
      await _ref
          .read(locationRepositoryProvider)
          .updateLocation(locationId, {'stay_duration': newDuration.inSeconds});
    } catch (e) {
      log('Error updating stay duration in repository: $e');
    }
  }

  Future<void> updateLocationScheduledDate(
      String locationId, DateTime newDate) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('updateLocationScheduledDate: Permission denied - user does not have write access');
      return;
    }

    final locations = state.pinnedLocations;
    final updatedLocations = locations.map((loc) {
      if (loc.id == locationId) {
        return loc.copyWith(scheduledDate: newDate);
      }
      return loc;
    }).toList();

    state = state.copyWith(pinnedLocations: updatedLocations);

    // Sync with Repository
    try {
      await _ref.read(locationRepositoryProvider).updateLocation(
          locationId, {'scheduled_date': newDate.toIso8601String()});
    } catch (e) {
      log('Error updating scheduled date in repository: $e');
    }
  }

  Future<void> updateMultipleLocationsScheduledDate(
      Set<String> locationIds, DateTime newDate) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('updateMultipleLocationsScheduledDate: Permission denied - user does not have write access');
      return;
    }

    final updatedLocations = state.pinnedLocations.map((loc) {
      if (locationIds.contains(loc.id)) {
        // Return a new LocationModel with the updated scheduled date
        return loc.copyWith(scheduledDate: newDate);
      }
      return loc;
    }).toList();

    state = state.copyWith(pinnedLocations: updatedLocations);

    // Sync multiple updates with Repository
    final repository = _ref.read(locationRepositoryProvider);
    for (final id in locationIds) {
      try {
        await repository
            .updateLocation(id, {'scheduled_date': newDate.toIso8601String()});
      } catch (e) {
        log('Error updating scheduled date for id $id: $e');
      }
    }
  }

  Future<void> copyMultipleLocationsToDate(
      Set<String> locationIds, DateTime newDate) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('copyMultipleLocationsToDate: Permission denied - user does not have write access');
      return;
    }

    final locationsToCopy = state.pinnedLocations
        .where((loc) => locationIds.contains(loc.id))
        .toList();

    // Get the REALTIME active trip to associate copied locations with it
    final activeTripAsync = _ref.read(realtimeActiveTripProvider);
    final activeTrip = activeTripAsync.asData?.value;

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
      // Sync new locations with Repository
      final repository = _ref.read(locationRepositoryProvider);
      for (final loc in newLocations) {
        try {
          final savedLoc = SavedLocation(
            id: loc.id,
            userId: '',
            fingerprint: '',
            name: loc.name,
            lat: loc.coordinates.latitude,
            lng: loc.coordinates.longitude,
            isSkipped: loc.isSkipped,
            stayDuration: loc.stayDuration.inSeconds,
            scheduledDate: loc.scheduledDate,
            createdAt: loc.addedAt,
            // IMPORTANT: Associate with active trip if available, null if no trip is active
            tripId: activeTrip?.id,
          );
          debugPrint('copyMultipleLocationsToDate: Copying "${savedLoc.name}" with tripId=${savedLoc.tripId ?? "null (no trip)"}');
          await repository.addLocation(savedLoc);
        } catch (e) {
          log('Error copying to repository for id ${loc.id}: $e');
        }
      }
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

      // OPTIMIZATION: Increase minimum distance threshold to 30m to reduce updates further
      // This reduces unnecessary state changes and provider rebuilds
      if (distance < 30) {
        return;
      }
    }

    state = state.copyWith(currentLocation: location);
  }

  Future<void> generateOptimizedRoute(
      {String? startLocationId, required DateTime selectedDate}) async {
    // OPTIMIZATION: Cancel previous route generation debounce if it exists
    _routeOptimizationDebounceTimer?.cancel();

    // OPTIMIZATION: Debounce the route generation by 500ms to prevent excessive API calls
    // when user is rapidly changing dates or locations
    _routeOptimizationDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _performRouteOptimization(
        startLocationId: startLocationId,
        selectedDate: selectedDate,
      );
    });
  }

  Future<void> _performRouteOptimization({
    String? startLocationId,
    required DateTime selectedDate,
  }) async {
    // Filter locations to only include those for the selected date.
    final allLocations = state.pinnedLocations;
    
    // OPTIMIZATION: Cache the date comparison value
    final selectedYear = selectedDate.year;
    final selectedMonth = selectedDate.month;
    final selectedDay = selectedDate.day;
    
    final locationsForDate = allLocations.where((loc) {
      if (loc.isSkipped) {
        return false;
      }
      if (loc.scheduledDate == null) {
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

      // OPTIMIZATION: Run clustering on an isolate to prevent UI blocking
      final proximityThreshold = _ref.read(proximityThresholdCommittedProvider);
      final clusterResult =
          await IsolateUtils.clusterLocationsIsolate(locationsToOptimize, proximityThreshold);

      // OPTIMIZATION: Reconstruct clusters from isolate result
      final List<List<LocationModel>> clusters = [];
      for (final clusterData in clusterResult['clusters'] as List) {
        final cluster = <LocationModel>[];
        for (final locData in clusterData as List) {
          // Find the matching location object
          final matching = locationsToOptimize.firstWhere(
            (loc) => loc.id == locData['id'],
            orElse: () => locationsToOptimize.first,
          );
          cluster.add(matching);
        }
        clusters.add(cluster);
      }

      List<List<LocationModel>> orderedClusters = [];
      LatLng currentPoint = startPoint;

      // OPTIMIZATION: Use simplified nearest-cluster finding
      while (clusters.isNotEmpty) {
        List<LocationModel>? closestCluster;
        double minDistance = double.infinity;

        for (final cluster in clusters) {
          // Find the nearest location in this cluster
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

      // OPTIMIZATION: Add timeout to API call to prevent hanging
      final routeResult = await GoogleMapsService.getOptimizedRouteDetails(
        origin: startPoint,
        destination: destination,
        waypoints: intermediateWaypoints,
        optimizeWaypoints: false,
      ).timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          print('Route optimization API call timed out');
          return {
            'routePoints': <LatLng>[],
            'waypointOrder': <int>[],
            'legDetails': <Map<String, dynamic>>[],
            'legPolylines': <List<LatLng>>[],
          };
        },
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

      // OPTIMIZATION: Cache date calculation instead of recalculating for each location
      final otherDateLocations = state.pinnedLocations.where((loc) {
        if (loc.scheduledDate == null) {
          final addedAt = loc.addedAt;
          return !(selectedYear == addedAt.year &&
              selectedMonth == addedAt.month &&
              selectedDay == addedAt.day);
        }
        final locDate = loc.scheduledDate!;
        return !(selectedYear == locDate.year &&
            selectedMonth == locDate.month &&
            selectedDay == locDate.day);
      }).toList();

      final updatedLocationsForDate = finalOptimizedLocationsForDate
          .map((loc) => locationsById[loc.id] ?? loc)
          .toList();

      final skippedLocationsForDate = allLocations.where((loc) {
        if (!loc.isSkipped) return false;
        if (loc.scheduledDate == null) {
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
    // Reset trip data and clear all locations from local storage
    state = state.copyWith(
      pinnedLocations: [],
      optimizedLocationsForSelectedDate: [], // Clear optimized list
      optimizedRoute: [],
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    // Remove all locations from local device storage
    StorageService.savePinnedLocations([]);
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

  // OPTIMIZATION: Cache date components to avoid repeated DateTime object creation
  final selectedYear = selectedDate.year;
  final selectedMonth = selectedDate.month;
  final selectedDay = selectedDate.day;

  // If an optimized route exists for the selected date, use it.
  // This check is crucial because optimizedLocationsForSelectedDate might hold data from a previous selectedDate.
  // We will now return the optimized list PLUS any skipped locations for that date.
  if (optimizedLocations.isNotEmpty) {
    final firstOptimizedLocDate = optimizedLocations.first.scheduledDate;
    bool dateMatches = false;
    if (firstOptimizedLocDate != null) {
      dateMatches = selectedYear == firstOptimizedLocDate.year &&
          selectedMonth == firstOptimizedLocDate.month &&
          selectedDay == firstOptimizedLocDate.day;
    } else {
      // If first optimized location has null scheduledDate, check using addedAt
      final firstOptimizedLoc = optimizedLocations.first;
      final addedAt = firstOptimizedLoc.addedAt;
      dateMatches = selectedYear == addedAt.year &&
          selectedMonth == addedAt.month &&
          selectedDay == addedAt.day;
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
      // Return the optimized locations first, followed by the skipped ones.
      return [...optimizedLocations, ...skippedForDate];
    }
  }

  // Fallback: filter from pinnedLocations if no optimized route or for a different date
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
