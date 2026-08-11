import 'dart:developer';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:geolocator/geolocator.dart';
import '../models/location_model.dart';
import '../models/trip_model.dart';
import '../models/trip.dart';
import '../services/google_maps_service.dart';
import '../services/leg_mode_prefs.dart';
import '../services/multi_modal_router.dart';
import '../services/places_service.dart';
import 'trip_simulation_provider.dart' show effectiveTripStartTimeProvider;
import '../services/analytics_service.dart';
// import '../services/anonymous_user_service.dart'; // DISABLED with first-optimize celebration (2026-08-07)
// import '../services/onboarding_service.dart'; // DISABLED with first-optimize celebration (2026-08-07)
import '../services/review_prompt_service.dart';
import '../services/storage_service.dart';
import '../services/time_saved_ledger_service.dart';
import '../providers/debounced_settings_provider.dart';
import '../utils/geo_utils.dart';
import '../utils/isolate_utils.dart';
import '../models/saved_location.dart';
// import 'auth_provider.dart'; // DISABLED with first-optimize celebration (2026-08-07)
import 'location_provider.dart';
import 'trip_listener_provider.dart';
import '../utils/same_day_place_guard.dart';
import '../utils/trip_dates.dart';
import 'trip_collaborator_provider.dart';
import 'onboarding_checklist_provider.dart';

class TripState {
  final List<LocationModel> pinnedLocations;
  final List<LocationModel>
      optimizedLocationsForSelectedDate; // New field for the optimized order

  /// The selected date's stops in the USER'S order as they stood when the
  /// current optimized route was generated (start anchor excluded). Powers the
  /// honest "before" panel of the shareable route card; refreshed on every
  /// successful optimize alongside [optimizedLocationsForSelectedDate].
  final List<LocationModel> originalOrderForSelectedDate;
  final List<LatLng> optimizedRoute;

  /// True while [optimizedLocationsForSelectedDate] holds a two-stop
  /// point-to-point PREVIEW (previewRouteBetween) rather than a real
  /// optimized day. The map's marker source uses this to keep every other
  /// location of the day visible around the previewed pair.
  final bool isRoutePreview;
  final List<List<LatLng>> legPolylines;
  final List<Map<String, dynamic>> legDetails;
  final LatLng? currentLocation;
  final Duration totalTravelTime;
  final double? currentHeading;
  final double totalDistance;

  /// Travel time the optimization saved vs routing the SAME stops in the
  /// user's original order (pure travel legs — stay durations cancel out).
  /// [Duration.zero] means "none or unknown" (baseline call skipped/failed);
  /// only meaningful while an optimized route is present, and refreshed on
  /// every successful optimize. This is the product's story kernel — surface
  /// it only when ≥ ~5 minutes so the claim always stays defensible.
  final Duration timeSaved;
  String startLocationId;
  final int? selectedLegIndex;

  TripState({
    this.pinnedLocations = const [],
    this.optimizedLocationsForSelectedDate = const [],
    this.originalOrderForSelectedDate = const [],
    this.optimizedRoute = const [],
    this.isRoutePreview = false,
    this.legPolylines = const [],
    this.legDetails = const [],
    this.currentLocation,
    this.totalTravelTime = Duration.zero,
    this.currentHeading,
    this.totalDistance = 0.0,
    this.timeSaved = Duration.zero,
    this.startLocationId = '',
    this.selectedLegIndex,
  });

  TripState copyWith({
    List<LocationModel>? pinnedLocations,
    List<LocationModel>? optimizedLocationsForSelectedDate,
    List<LocationModel>? originalOrderForSelectedDate,
    List<LatLng>? optimizedRoute,
    bool? isRoutePreview,
    List<List<LatLng>>? legPolylines,
    List<Map<String, dynamic>>? legDetails,
    LatLng? currentLocation,
    Duration? totalTravelTime,
    double? currentHeading,
    double? totalDistance,
    Duration? timeSaved,
    String? startLocationId,
    int? selectedLegIndex,
  }) {
    return TripState(
      pinnedLocations: pinnedLocations ?? this.pinnedLocations,
      optimizedLocationsForSelectedDate: optimizedLocationsForSelectedDate ??
          this.optimizedLocationsForSelectedDate,
      originalOrderForSelectedDate:
          originalOrderForSelectedDate ?? this.originalOrderForSelectedDate,
      optimizedRoute: optimizedRoute ?? this.optimizedRoute,
      isRoutePreview: isRoutePreview ?? this.isRoutePreview,
      legPolylines: legPolylines ?? this.legPolylines,
      legDetails: legDetails ?? this.legDetails,
      currentLocation: currentLocation ?? this.currentLocation,
      totalTravelTime: totalTravelTime ?? this.totalTravelTime,
      currentHeading: currentHeading ?? this.currentHeading,
      totalDistance: totalDistance ?? this.totalDistance,
      timeSaved: timeSaved ?? this.timeSaved,
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
        other.timeSaved == timeSaved &&
        other.selectedLegIndex == selectedLegIndex;
    // Note: Deliberately excluding legPolylines and legDetails from equality to keep the check fast. They change together with optimizedRoute anyway.
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
      timeSaved,
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
    final activeTrip = activeTripAsync.valueOrNull;

    // No active trip - user can edit their own non-trip locations
    if (activeTrip == null) return true;

    // Check if user is owner
    final isOwner = await _ref.read(isTripOwnerProvider(activeTrip.id).future);
    if (isOwner) return true;

    // Check if user has write permission
    final permission =
        await _ref.read(userTripPermissionProvider(activeTrip.id).future);
    return permission == 'write';
  }

  /// Content fingerprint of the last pinnedLocations sync. The locations
  /// stream re-emits on background syncs that change NOTHING (cold start:
  /// fetchRemoteLocations re-puts identical rows into Hive) — and clearing
  /// the optimized route on those no-op emissions was the "first optimize
  /// after a cold start never appears" bug: the route landed, then the
  /// sync's re-emission wiped it seconds later.
  String? _lastPinnedFingerprint;

  static String _locationsFingerprint(List<SavedLocation> locations) {
    final parts = locations
        .map((l) => '${l.id}|${l.lat}|${l.lng}|'
            '${l.scheduledDate?.millisecondsSinceEpoch}|'
            '${l.scheduledEndDate?.millisecondsSinceEpoch}|'
            '${l.isSkipped}|${l.isDone}|${l.stayDuration}')
        .toList()
      ..sort();
    return parts.join(';');
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
              isRoutePreview: false,
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
          final refs = saved.effectivePhotoReferences;
          return LocationModel(
            id: saved.id,
            name: saved.name,
            address: '', // Address not available from SavedLocation
            coordinates: LatLng(saved.lat, saved.lng),
            addedAt: saved.createdAt,
            scheduledDate:
                saved.scheduledDate ?? _ref.read(selectedDateProvider),
            isSkipped: saved.isSkipped,
            isDone: saved.isDone,
            isAccommodation: saved.isAccommodation,
            stayDuration: Duration(seconds: saved.stayDuration),
            photoReference: saved.photoReference,
            photoReferences: refs.isEmpty ? null : refs,
            photoAttributions: saved.photoAttributions,
            placeId: saved.placeId,
            originalName: saved.originalName,
            googleOpeningHours: saved.googleOpeningHours,
            userClosingMinuteOverride: saved.userClosingMinuteOverride,
            hoursLastRefreshedAt: saved.hoursLastRefreshedAt,
            scheduledEndDate: saved.scheduledEndDate,
            tripId: saved.tripId,
          );
        }).toList();

        debugPrint(
            '✅ TripNotifier._initSyncListener: Converted to ${newPinnedLocations.length} LocationModel objects');

        // Only a REAL content change invalidates the computed route. A
        // background sync re-emitting identical rows must not clear it —
        // that erased the first post-cold-start optimize.
        final fingerprint = _locationsFingerprint(filteredLocations);
        final contentChanged = fingerprint != _lastPinnedFingerprint;
        _lastPinnedFingerprint = fingerprint;

        if (!contentChanged) {
          debugPrint(
              '📍 TripNotifier: no-op sync emission — keeping the route');
          state = state.copyWith(pinnedLocations: newPinnedLocations);
          return;
        }

        // Update state with filtered locations from active trip
        state = state.copyWith(
          pinnedLocations: newPinnedLocations,
          // Clear optimized route when locations change (different trip's locations)
          optimizedLocationsForSelectedDate: [],
          isRoutePreview: false,
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
      debugPrint(
          'addLocation: Permission denied - user does not have write access');
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
        isDone: locationWithDate.isDone,
        isAccommodation: locationWithDate.isAccommodation,
        // IMPORTANT: Set tripId if a trip is active, null if no trip is active
        tripId: activeTrip?.id,
        // userId and fingerprint will be handled by repository based on auth state
        userId: '',
        fingerprint: '',
        photoReference: locationWithDate.photoReference,
        photoReferences: locationWithDate.photoReferences.isEmpty
            ? null
            : locationWithDate.photoReferences,
        photoAttributions: locationWithDate.photoAttributions,
        placeId: locationWithDate.placeId,
        originalName: locationWithDate.originalName,
        googleOpeningHours: locationWithDate.googleOpeningHours,
        userClosingMinuteOverride: locationWithDate.userClosingMinuteOverride,
        hoursLastRefreshedAt: locationWithDate.hoursLastRefreshedAt,
        scheduledEndDate: locationWithDate.scheduledEndDate,
      );

      debugPrint(
          'addLocation: Adding location "${savedLoc.name}" with tripId=${savedLoc.tripId ?? "null (no trip)"}');
      await _ref.read(locationRepositoryProvider).addLocation(savedLoc);

      // Funnel analytics: a place was saved (drives the 3–5 "aha" threshold).
      AnalyticsService.instance.placeAdded(state.pinnedLocations.length + 1);

      // Clear optimized route when location is added
      state = state.copyWith(
        optimizedLocationsForSelectedDate: [],
        isRoutePreview: false,
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
      final permission =
          await _ref.read(userTripPermissionProvider(tripId).future);
      if (permission != 'write') {
        debugPrint(
            'addLocationsToTrip: Permission denied - user does not have write access to trip $tripId');
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
      debugPrint(
          'removeLocationsFromTrip: Permission denied - user does not have write access');
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
      debugPrint(
          'removeLocation: Permission denied - user does not have write access');
      return;
    }

    // Clear optimized route data when a location is removed
    state = state.copyWith(
      optimizedLocationsForSelectedDate: [],
      isRoutePreview: false,
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
      debugPrint(
          'removeMultipleLocations: Permission denied - user does not have write access');
      return;
    }

    // Clear optimized route data when locations are removed
    state = state.copyWith(
      optimizedLocationsForSelectedDate: [],
      isRoutePreview: false, // Clear optimized list
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
      debugPrint(
          'skipMultipleLocations: Permission denied - user does not have write access');
      return;
    }

    // Clear optimized route
    state = state.copyWith(
      optimizedRoute: [],
      optimizedLocationsForSelectedDate: [],
      isRoutePreview: false, // Clear optimized list
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
      debugPrint(
          'unskipMultipleLocations: Permission denied - user does not have write access');
      return;
    }

    // Clear optimized route
    state = state.copyWith(
      optimizedRoute: [],
      optimizedLocationsForSelectedDate: [],
      isRoutePreview: false, // Clear optimized list
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

  Future<void> markLocationsAsDone(Set<String> locationIds) async {
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('markLocationsAsDone: Permission denied');
      return;
    }

    // Snapshot pre-mark state so we can detect "the user just finished
    // every stop on a planned day" — our delight moment for the review
    // prompt. Computed from current state and treats locationIds as
    // about-to-be-done so we don't race the sync listener.
    final affectedDates = <DateTime>{};
    for (final loc in state.pinnedLocations) {
      if (locationIds.contains(loc.id) && loc.scheduledDate != null) {
        final d = loc.scheduledDate!;
        affectedDates.add(DateTime(d.year, d.month, d.day));
      }
    }

    state = state.copyWith(
      optimizedRoute: [],
      optimizedLocationsForSelectedDate: [],
      isRoutePreview: false,
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    selectLeg(null);

    final repository = _ref.read(locationRepositoryProvider);
    for (final id in locationIds) {
      try {
        await repository.updateLocation(id, {'is_done': true});
      } catch (e) {
        log('Error marking location as done for id $id: $e');
      }
    }

    _maybePromptForReviewAfterDayCompletion(affectedDates, locationIds);
  }

  /// Fires the in-app review request when the user just finished the last
  /// remaining stop on a day that had a real plan (≥2 stops). Routes through
  /// the sentiment-gated flow via [_maybeSignalReviewPrompt] — the OS prompt is
  /// never shown directly, only after the user confirms they're happy.
  void _maybePromptForReviewAfterDayCompletion(
      Set<DateTime> affectedDates, Set<String> justMarkedIds) {
    for (final date in affectedDates) {
      final onDate = state.pinnedLocations.where((l) {
        final d = l.scheduledDate;
        if (d == null) return false;
        return d.year == date.year &&
            d.month == date.month &&
            d.day == date.day;
      }).toList();

      if (onDate.length < 2) continue;

      final allDone =
          onDate.every((l) => l.isDone || justMarkedIds.contains(l.id));
      if (allDone) {
        // Fire-and-forget: never block the mark-as-done UX on this.
        unawaited(_maybeSignalReviewPrompt());
        return;
      }
    }
  }

  /// Shared review-prompt gate for delight moments. Checks every non-UI
  /// eligibility rule (sessions, optimizes, saved-places, cooldown, lifetime
  /// caps, OS availability) and, only if eligible, bumps
  /// [reviewPromptTriggerProvider] so the map screen can show the sentiment
  /// dialog. Never throws; never shows the OS prompt directly.
  Future<void> _maybeSignalReviewPrompt() async {
    try {
      final eligible = await ReviewPromptService.instance.isEligibleForPrompt(
        savedPlacesCount: state.pinnedLocations.length,
      );
      if (eligible) {
        _ref.read(reviewPromptTriggerProvider.notifier).update((s) => s + 1);
      }
    } catch (_) {
      // Best-effort: a review prompt is never worth surfacing an error for.
    }
  }

  Future<void> unmarkLocationsAsDone(Set<String> locationIds) async {
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('unmarkLocationsAsDone: Permission denied');
      return;
    }

    state = state.copyWith(
      optimizedRoute: [],
      optimizedLocationsForSelectedDate: [],
      isRoutePreview: false,
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
    selectLeg(null);

    final repository = _ref.read(locationRepositoryProvider);
    for (final id in locationIds) {
      try {
        await repository.updateLocation(id, {'is_done': false});
      } catch (e) {
        log('Error unmarking location as done for id $id: $e');
      }
    }
  }

  Future<void> reorderLocation(int oldIndex, int newIndex) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint(
          'reorderLocation: Permission denied - user does not have write access');
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
      optimizedLocationsForSelectedDate: [],
      isRoutePreview: false, // Clear optimized list
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
      debugPrint(
          'updateLocationName: Permission denied - user does not have write access');
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
      debugPrint(
          'updateLocationStayDuration: Permission denied - user does not have write access');
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

    debugPrint("Stay For: " + newDuration.inSeconds.toString());

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
      debugPrint(
          'updateLocationScheduledDate: Permission denied - user does not have write access');
      return;
    }

    final locations = state.pinnedLocations;
    // Same-day duplicate choke point (move semantics: the row itself is
    // excluded — moving onto a day you already occupy is a no-op).
    final allowed = _allowedForDay({locationId}, newDate, excludeMoving: true);
    if (!allowed.contains(locationId)) {
      debugPrint('updateLocationScheduledDate: blocked — same place already '
          'on that day');
      return;
    }
    DateTime? movedSpanEnd;
    final updatedLocations = locations.map((loc) {
      if (loc.id == locationId) {
        // A stay range moves WHOLE — see shiftedSpanEnd.
        movedSpanEnd = shiftedSpanEnd(
          oldStart: loc.scheduledDate ?? loc.addedAt,
          oldEnd: loc.scheduledEndDate,
          newStart: newDate,
        );
        return loc.copyWith(
            scheduledDate: newDate, scheduledEndDate: movedSpanEnd);
      }
      return loc;
    }).toList();

    state = state.copyWith(pinnedLocations: updatedLocations);

    // Sync with Repository
    try {
      await _ref.read(locationRepositoryProvider).updateLocation(locationId, {
        'scheduled_date': newDate.toIso8601String(),
        'scheduled_end_date': movedSpanEnd?.toIso8601String(),
      });
    } catch (e) {
      log('Error updating scheduled date in repository: $e');
    }
  }

  /// THE write-path same-day duplicate gate: of [candidateIds] (rows about
  /// to be scheduled onto [day]), returns the subset that may proceed.
  /// [excludeMoving] = move semantics (the rows themselves don't count as
  /// occupants); copies keep them counted, so copying a place onto its own
  /// day is blocked. Occupancy counts SCHEDULED rows only — unscheduled
  /// rows phantom-occupy their creation day via the createdAt fallback.
  Set<String> _allowedForDay(Set<String> candidateIds, DateTime day,
      {required bool excludeMoving}) {
    final dayK = DateTime(day.year, day.month, day.day);
    final pinned = state.pinnedLocations;
    final moving = pinned
        .where((l) => candidateIds.contains(l.id))
        .map(placeKeyOfModel)
        .toList();
    final occupants = pinned
        .where((l) =>
            (!excludeMoving || !candidateIds.contains(l.id)) &&
            l.scheduledDate != null &&
            l.isActiveOnDate(dayK))
        .map(placeKeyOfModel);
    return filterSameDayDuplicates(
      moving: moving,
      occupantsOnDay: occupants,
    ).allowedIds;
  }

  /// Sets a location's stay range. Pass [end] = null (default) to clear the
  /// range and revert to single-day. When [end] equals [start] (same day),
  /// also clears the range — there's no point storing a redundant end.
  /// Otherwise the location appears on every day in `[start..end]` across
  /// the trip details screen and the per-day plan filter.
  Future<void> setLocationDateRange(
      String locationId, DateTime start, DateTime? end) async {
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('setLocationDateRange: Permission denied');
      return;
    }

    final startKey = DateTime(start.year, start.month, start.day);
    DateTime? endKey;
    if (end != null) {
      final candidate = DateTime(end.year, end.month, end.day);
      if (candidate.isAfter(startKey)) {
        endKey = candidate;
      }
    }

    // Optimistic local update.
    final updatedLocations = state.pinnedLocations.map((loc) {
      if (loc.id != locationId) return loc;
      return loc.copyWith(
        scheduledDate: startKey,
        scheduledEndDate: endKey,
      );
    }).toList();
    state = state.copyWith(pinnedLocations: updatedLocations);

    try {
      await _ref.read(locationRepositoryProvider).updateLocation(
        locationId,
        {
          'scheduled_date': startKey.toIso8601String(),
          'scheduled_end_date': endKey?.toIso8601String(),
        },
      );
    } catch (e) {
      log('Error setting location date range in repository: $e');
    }
  }

  /// Removes [locationId] from [day] ONLY. Single-day rows are deleted
  /// outright; a multi-day row (e.g. an accommodation spanning the trip)
  /// keeps its other days — an edge day shrinks the range, a middle day
  /// SPLITS the row into two ranges around it. Falls back to a full delete
  /// when [day] isn't inside the row's span.
  Future<void> removeLocationFromDay(String locationId, DateTime day) async {
    final idx = state.pinnedLocations.indexWhere((l) => l.id == locationId);
    if (idx == -1) {
      await removeLocation(locationId);
      return;
    }
    final loc = state.pinnedLocations[idx];
    final startRaw = loc.scheduledDate ?? loc.addedAt;
    final start = DateTime(startRaw.year, startRaw.month, startRaw.day);
    final endRaw = loc.scheduledEndDate ?? startRaw;
    final end = DateTime(endRaw.year, endRaw.month, endRaw.day);
    final d = DateTime(day.year, day.month, day.day);

    // Single-day row, or the day isn't inside the span → full delete.
    if (!end.isAfter(start) || d.isBefore(start) || d.isAfter(end)) {
      await removeLocation(locationId);
      return;
    }

    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('removeLocationFromDay: Permission denied');
      return;
    }

    if (d == start) {
      await setLocationDateRange(
          locationId, DateTime(d.year, d.month, d.day + 1), end);
      return;
    }
    if (d == end) {
      await setLocationDateRange(
          locationId, start, DateTime(d.year, d.month, d.day - 1));
      return;
    }

    // Middle day: shrink the original to [start .. day-1], then clone the
    // row for [day+1 .. end]. Shrink FIRST — for accommodations the DB's
    // one-per-day exclusion constraint would reject an overlapping clone.
    await setLocationDateRange(
        locationId, start, DateTime(d.year, d.month, d.day - 1));

    final tailStart = DateTime(d.year, d.month, d.day + 1);
    final DateTime? tailEnd = end.isAfter(tailStart) ? end : null;
    final clone = loc.copyWith(
      id: const Uuid().v4(),
      scheduledDate: tailStart,
      scheduledEndDate: tailEnd,
      travelTimeFromPrevious: null,
      distanceFromPrevious: null,
    );
    state = state.copyWith(pinnedLocations: [...state.pinnedLocations, clone]);
    try {
      final savedLoc = SavedLocation(
        id: clone.id,
        userId: '',
        fingerprint: '',
        name: clone.name,
        lat: clone.coordinates.latitude,
        lng: clone.coordinates.longitude,
        isSkipped: clone.isSkipped,
        isDone: clone.isDone,
        isAccommodation: clone.isAccommodation,
        stayDuration: clone.stayDuration.inSeconds,
        scheduledDate: tailStart,
        scheduledEndDate: tailEnd,
        createdAt: clone.addedAt,
        tripId: loc.tripId,
        photoReference: clone.photoReference,
        photoReferences:
            clone.photoReferences.isEmpty ? null : clone.photoReferences,
        photoAttributions: clone.photoAttributions,
        placeId: clone.placeId,
        originalName: clone.originalName,
        googleOpeningHours: clone.googleOpeningHours,
        userClosingMinuteOverride: clone.userClosingMinuteOverride,
        hoursLastRefreshedAt: clone.hoursLastRefreshedAt,
      );
      await _ref.read(locationRepositoryProvider).addLocation(savedLoc);
    } catch (e) {
      log('Error splitting multi-day location $locationId: $e');
    }
  }

  /// Bulk variant of [removeLocationFromDay] — used by selection-mode
  /// delete so a spanning accommodation caught in the selection only loses
  /// the day being viewed.
  Future<void> removeLocationsFromDay(
      Set<String> locationIds, DateTime day) async {
    for (final id in locationIds) {
      await removeLocationFromDay(id, day);
    }
  }

  // ── Accommodation (one per trip-day) ──────────────────────────────────

  /// Other accommodations whose day range overlaps [start..end] — the rows
  /// that would break the one-accommodation-per-day rule if [locationId]
  /// became the accommodation for that range.
  List<LocationModel> accommodationConflicts(
      String locationId, DateTime start, DateTime end) {
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    return state.pinnedLocations.where((loc) {
      if (loc.id == locationId || !loc.isAccommodation) return false;
      final oRaw = loc.scheduledDate ?? loc.addedAt;
      final oS = DateTime(oRaw.year, oRaw.month, oRaw.day);
      final oERaw = loc.scheduledEndDate ?? oRaw;
      final oE = DateTime(oERaw.year, oERaw.month, oERaw.day);
      return !(oE.isBefore(s) || oS.isAfter(e));
    }).toList();
  }

  /// Flags [locationId] as the accommodation for [start..end] (inclusive),
  /// first un-flagging every id in [replaceIds] (conflicts the user approved
  /// replacing). Callers must pass the current [accommodationConflicts] as
  /// [replaceIds]; the replaced rows are cleared FIRST because the DB's
  /// exclusion constraint (`locations_one_accommodation_per_day`) rejects an
  /// overlapping accommodation range. If a concurrent collaborator write
  /// still trips the constraint, this returns false and the optimistic
  /// state heals on the next realtime sync.
  Future<bool> setAccommodation(
    String locationId, {
    required DateTime start,
    required DateTime end,
    List<String> replaceIds = const [],
  }) async {
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('setAccommodation: Permission denied');
      return false;
    }

    final startKey = DateTime(start.year, start.month, start.day);
    final endKeyRaw = DateTime(end.year, end.month, end.day);
    final DateTime? endKey = endKeyRaw.isAfter(startKey) ? endKeyRaw : null;

    // Same-day duplicate choke point across the whole covered range.
    final target =
        state.pinnedLocations.where((l) => l.id == locationId).toList();
    if (target.isNotEmpty) {
      final movingKey = placeKeyOfModel(target.first);
      for (var d = startKey;
          !d.isAfter(endKey ?? startKey);
          d = DateTime(d.year, d.month, d.day + 1)) {
        final occupants = state.pinnedLocations
            .where((l) =>
                l.id != locationId &&
                !replaceIds.contains(l.id) &&
                l.scheduledDate != null &&
                l.isActiveOnDate(d))
            .map(placeKeyOfModel);
        final ok = filterSameDayDuplicates(
                moving: [movingKey], occupantsOnDay: occupants)
            .allowedIds;
        if (ok.isEmpty) {
          debugPrint('setAccommodation: blocked — same place already '
              'scheduled on ${d.toIso8601String()}');
          return false;
        }
      }
    }

    // Optimistic local update (target flagged + dated, conflicts cleared).
    final updated = state.pinnedLocations.map((loc) {
      if (loc.id == locationId) {
        return loc.copyWith(
          isAccommodation: true,
          scheduledDate: startKey,
          scheduledEndDate: endKey,
        );
      }
      if (replaceIds.contains(loc.id)) {
        return loc.copyWith(isAccommodation: false);
      }
      return loc;
    }).toList();
    state = state.copyWith(pinnedLocations: updated);

    final repo = _ref.read(locationRepositoryProvider);
    try {
      for (final id in replaceIds) {
        await repo.updateLocation(id, {'is_accommodation': false});
      }
      await repo.updateLocation(locationId, {
        'is_accommodation': true,
        'scheduled_date': startKey.toIso8601String(),
        'scheduled_end_date': endKey?.toIso8601String(),
      });
      return true;
    } catch (e) {
      log('Error setting accommodation: $e');
      return false;
    }
  }

  /// Removes the accommodation flag (the place itself stays on the trip).
  Future<void> clearAccommodation(String locationId) async {
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) return;
    final updated = state.pinnedLocations
        .map((loc) =>
            loc.id == locationId ? loc.copyWith(isAccommodation: false) : loc)
        .toList();
    state = state.copyWith(pinnedLocations: updated);
    try {
      await _ref
          .read(locationRepositoryProvider)
          .updateLocation(locationId, {'is_accommodation': false});
    } catch (e) {
      log('Error clearing accommodation: $e');
    }
  }

  /// Sets (or clears) the user-supplied closing-time override for a single
  /// location. Pass [minutes] = `null` to clear (the simulation will then
  /// fall back to Google's hours).
  Future<void> setUserClosingMinuteOverride(
      String locationId, int? minutes) async {
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('setUserClosingMinuteOverride: Permission denied');
      return;
    }
    try {
      await _ref.read(locationRepositoryProvider).updateLocation(
        locationId,
        {'user_closing_minute_override': minutes},
      );
    } catch (e) {
      log('Error setting closing override: $e');
    }
  }

  /// Re-fetches a place's hours from Google Places and persists them along
  /// with the refresh timestamp. Caller passes [placeId] so this works in
  /// every context (active trip, trip details, …) without a state lookup.
  /// Returns true on success, false if Places API returned nothing or a
  /// permission/auth check blocked the write.
  Future<bool> refreshLocationHours(String locationId, String placeId) async {
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint('refreshLocationHours: Permission denied');
      return false;
    }
    final details = await PlacesService.getPlaceDetails(placeId);
    if (details == null) return false;
    try {
      await _ref.read(locationRepositoryProvider).updateLocation(
        locationId,
        {
          'google_opening_hours': details.openingHours,
          'hours_last_refreshed_at': DateTime.now(),
        },
      );
      return true;
    } catch (e) {
      log('Error refreshing hours: $e');
      return false;
    }
  }

  Future<void> updateMultipleLocationsScheduledDate(
      Set<String> locationIds, DateTime newDate) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint(
          'updateMultipleLocationsScheduledDate: Permission denied - user does not have write access');
      return;
    }

    // Same-day duplicate choke point (move semantics).
    final locationIdsAllowed =
        _allowedForDay(locationIds, newDate, excludeMoving: true);
    if (locationIdsAllowed.isEmpty) {
      debugPrint(
          'updateMultipleLocationsScheduledDate: all blocked — same place '
          'already on that day');
      return;
    }
    locationIds = locationIdsAllowed;

    // Stay ranges move WHOLE — see shiftedSpanEnd (start-only writes left
    // start > end and the rows vanished from every day list).
    final spanEnds = <String, DateTime?>{};
    final updatedLocations = state.pinnedLocations.map((loc) {
      if (locationIds.contains(loc.id)) {
        final newEnd = shiftedSpanEnd(
          oldStart: loc.scheduledDate ?? loc.addedAt,
          oldEnd: loc.scheduledEndDate,
          newStart: newDate,
        );
        spanEnds[loc.id] = newEnd;
        return loc.copyWith(scheduledDate: newDate, scheduledEndDate: newEnd);
      }
      return loc;
    }).toList();

    state = state.copyWith(pinnedLocations: updatedLocations);

    // Sync multiple updates with Repository
    final repository = _ref.read(locationRepositoryProvider);
    await Future.wait(locationIds.map((id) async {
      try {
        await repository.updateLocation(id, {
          'scheduled_date': newDate.toIso8601String(),
          'scheduled_end_date': spanEnds[id]?.toIso8601String(),
        });
      } catch (e) {
        log('Error updating scheduled date for id $id: $e');
      }
    }));
  }

  Future<void> copyMultipleLocationsToDate(
      Set<String> locationIds, DateTime newDate) async {
    // Permission check at function level
    final hasAccess = await _hasWriteAccess();
    if (!hasAccess) {
      debugPrint(
          'copyMultipleLocationsToDate: Permission denied - user does not have write access');
      return;
    }

    // Same-day duplicate choke point (copy semantics: the source rows DO
    // count as occupants — copying a place onto the day it already
    // occupies duplicates it).
    final locationIdsAllowed =
        _allowedForDay(locationIds, newDate, excludeMoving: false);
    if (locationIdsAllowed.isEmpty) {
      debugPrint('copyMultipleLocationsToDate: all blocked — same place '
          'already on that day');
      return;
    }
    final locationsToCopy = state.pinnedLocations
        .where((loc) => locationIdsAllowed.contains(loc.id))
        .toList();

    // Get the REALTIME active trip to associate copied locations with it
    final activeTripAsync = _ref.read(realtimeActiveTripProvider);
    final activeTrip = activeTripAsync.valueOrNull;

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
            isDone: loc.isDone,
            isAccommodation: loc.isAccommodation,
            stayDuration: loc.stayDuration.inSeconds,
            scheduledDate: loc.scheduledDate,
            createdAt: loc.addedAt,
            // IMPORTANT: Associate with active trip if available, null if no trip is active
            tripId: activeTrip?.id,
            photoReference: loc.photoReference,
            photoReferences:
                loc.photoReferences.isEmpty ? null : loc.photoReferences,
            photoAttributions: loc.photoAttributions,
            placeId: loc.placeId,
            originalName: loc.originalName,
            googleOpeningHours: loc.googleOpeningHours,
            userClosingMinuteOverride: loc.userClosingMinuteOverride,
            hoursLastRefreshedAt: loc.hoursLastRefreshedAt,
            // Copies start fresh as a single-day stop — copying a multi-day
            // range to a new anchor would be ambiguous; user can re-set
            // the range on the new copy explicitly.
          );
          debugPrint(
              'copyMultipleLocationsToDate: Copying "${savedLoc.name}" with tripId=${savedLoc.tripId ?? "null (no trip)"}');
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

      // 3m: dedupe GPS jitter only. The heavy consumers no longer watch
      // this field (bitmaps cached; polylines/leg providers narrowed), so
      // a moving pin costs one cheap marker-set assembly per emission.
      if (distance < 3) {
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
    _routeOptimizationDebounceTimer =
        Timer(const Duration(milliseconds: 500), () {
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
    // Filter locations to only include those active on the selected date.
    // Multi-day stays (e.g. an accommodation set to span the whole trip)
    // appear on every day in their `[scheduledDate..scheduledEndDate]` range.
    final allLocations = state.pinnedLocations;
    final locationsForDate = allLocations.where((loc) {
      if (loc.isSkipped || loc.isDone) return false;
      return loc.isActiveOnDate(selectedDate);
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
        // Look up the start location in pinnedLocations (not just
        // locationsForDate). This lets the user anchor the route to a
        // skipped or done stop — those are filtered out of the optimize
        // list but their coordinates are still a useful start point
        // (e.g. "we're done with the museum, plan the rest from here").
        final startLocation = state.pinnedLocations.firstWhere(
          (loc) => loc.id == startLocationId,
          orElse: () => locationsForDate.first,
        );

        startPoint = startLocation.coordinates;
        effectiveStartLocationId = startLocation.id;
        // If the anchor IS one of the day's optimizable stops, remove it
        // from the list so the optimizer doesn't visit it twice. Skipped/
        // done anchors aren't in locationsToOptimize to begin with, so
        // removeWhere is a no-op for them — exactly what we want.
        locationsToOptimize
            .removeWhere((loc) => loc.id == effectiveStartLocationId);
      } else {
        // This is the primary fallback logic. If no start location is specified, or if the
        // specified one is invalid (e.g., from a different date), we land here.
        //
        // Only auto-anchor to the device GPS when it's plausibly near the
        // stops. Without this, paths that skip the start-point chooser (e.g.
        // the first-ever optimize) would route a leg from another region —
        // a phone in Cambodia anchoring the Lisbon sample trip. The chooser's
        // own guard handles the dialog path; this covers every other caller.
        final current = state.currentLocation;
        final currentUsable = current != null &&
            minMetersToAny(
                    current, locationsForDate.map((l) => l.coordinates)) <=
                kForeignFallbackMeters;
        if (currentUsable) {
          startPoint = current;
          effectiveStartLocationId = 'current_location';
        } else {
          // Ultimate fallback: use the first location in the list (also the
          // safe choice when the device is far from every stop). The check at
          // the top of the function ensures locationsForDate is not empty.
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

      // ── "Time saved" baseline ────────────────────────────────────────────
      // Route the SAME stops in the user's ORIGINAL order (our optimizer does
      // the reordering below; Google only routes along it). The delta between
      // this baseline and the optimized route is the product's story kernel:
      // "saved you ~1h 40m of backtracking." Runs concurrently with the
      // clustering + main route call and NEVER blocks the reveal — on any
      // failure the delta is simply zero (= not shown).
      final originalOrder = List<LocationModel>.from(locationsToOptimize);
      Future<Duration?> baselineTravelFuture = Future.value(null);
      if (originalOrder.length >= 2) {
        baselineTravelFuture = GoogleMapsService.getOptimizedRouteDetails(
          origin: startPoint,
          destination: originalOrder.last,
          waypoints: originalOrder.sublist(0, originalOrder.length - 1),
          optimizeWaypoints: false,
        ).timeout(const Duration(seconds: 20)).then<Duration?>((res) {
          final legs = res['legDetails'] as List<Map<String, dynamic>>;
          if (legs.isEmpty) return null;
          return legs.fold<Duration>(
              Duration.zero, (sum, leg) => sum + (leg['duration'] as Duration));
        }).catchError((Object e) {
          debugPrint('Baseline (original-order) route call failed: $e');
          return null;
        });
      }

      // OPTIMIZATION: Run clustering on an isolate to prevent UI blocking
      final proximityThreshold = _ref.read(proximityThresholdCommittedProvider);
      final clusterResult = await IsolateUtils.clusterLocationsIsolate(
          locationsToOptimize, proximityThreshold);

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
          clusters.remove(closestCluster);
          // WITHIN-cluster order used to be the order the user ADDED the
          // places — the "visit 2, then walk back to 3" bug. Nearest-
          // neighbor from the entry point fixes the fallback path (the
          // primary path is Google's travel-time TSP in the router, which
          // overrides this order entirely when it succeeds).
          final remaining = List<LocationModel>.from(closestCluster);
          final orderedMembers = <LocationModel>[];
          var walkPoint = currentPoint;
          while (remaining.isNotEmpty) {
            LocationModel? nearest;
            var nearestDist = double.infinity;
            for (final loc in remaining) {
              final dist = Geolocator.distanceBetween(
                  walkPoint.latitude,
                  walkPoint.longitude,
                  loc.coordinates.latitude,
                  loc.coordinates.longitude);
              if (dist < nearestDist) {
                nearestDist = dist;
                nearest = loc;
              }
            }
            orderedMembers.add(nearest!);
            remaining.remove(nearest);
            walkPoint = nearest.coordinates;
          }
          orderedClusters.add(orderedMembers);
          // Next cluster is chosen from where this one actually ENDS —
          // the old "farthest from cluster center" reference point had no
          // relationship to the walking path.
          currentPoint = orderedMembers.last.coordinates;
        } else {
          break;
        }
      }

      final finalOrderedWaypoints =
          orderedClusters.expand((cluster) => cluster).toList();

      // Multi-modal routing along OUR order: one anchor-mode chain call,
      // then per-leg mode resolution (walk/transit/drive ladder + the user's
      // per-leg overrides + failure cascades). Longer timeout than the old
      // single call: transit legs are fetched sequentially so departure
      // times can chain off cumulative arrival + stay.
      final routingTripId = locationsForDate.first.tripId ?? 'no_trip';
      final travelProfile = await LegModePrefs.travelProfile(routingTripId);
      final legOverrides = await LegModePrefs.overridesForTrip(routingTripId);
      final prefMaxWalk = await LegModePrefs.maxWalkMeters();
      // Loop home: when the day STARTS at its accommodation, that stop was
      // pulled out of the optimize list — without this, the plan just
      // ended at the last sight. The router appends a routed return leg.
      // (An accommodation elsewhere in the list is already pinned as the
      // day's destination — no return leg needed there.)
      LocationModel? returnAccommodation;
      final dayAccommodations =
          locationsForDate.where((l) => l.isAccommodation).toList();
      if (dayAccommodations.isNotEmpty &&
          effectiveStartLocationId == dayAccommodations.first.id) {
        returnAccommodation = dayAccommodations.first;
      }
      final routeResult = await MultiModalRouter.routeItinerary(
        origin: startPoint,
        originId:
            effectiveStartLocationId.isEmpty ? 'start' : effectiveStartLocationId,
        orderedStops: finalOrderedWaypoints,
        profile: travelProfile,
        departureAnchor: _ref.read(effectiveTripStartTimeProvider),
        legModeOverrides: legOverrides,
        maxWalkMeters: prefMaxWalk.toDouble(),
        returnTo: returnAccommodation,
      ).timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          debugPrint('Route optimization API call timed out');
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

      // Adopt the router's FINAL visit order: when Google's travel-time TSP
      // ordered the stops (roads, rivers, one-ways — not straight lines),
      // the legs follow THAT order, so numbering and travel-time
      // attribution must too. Falls back to the client heuristic's order
      // when the router returned nothing better.
      final routedOrder = routeResult['orderedStops'];
      final List<LocationModel> orderedWaypoints =
          (routedOrder is List<LocationModel> && routedOrder.isNotEmpty)
              ? List.from(routedOrder)
              : List.from(finalOrderedWaypoints);

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

      // Multi-day aware partitioning: a stop is "for this date" if its
      // active range covers selectedDate (single-day rows match only their
      // own day; range rows match every day in `[start..end]`).
      final otherDateLocations = state.pinnedLocations
          .where((loc) => !loc.isActiveOnDate(selectedDate))
          .toList();

      final updatedLocationsForDate = finalOptimizedLocationsForDate
          .map((loc) => locationsById[loc.id] ?? loc)
          .toList();

      final skippedLocationsForDate = allLocations
          .where((loc) => loc.isSkipped && loc.isActiveOnDate(selectedDate))
          .toList();

      final doneLocationsForDate = allLocations
          .where((loc) => loc.isDone && loc.isActiveOnDate(selectedDate))
          .toList();

      final updatedPinnedLocations = [
        ...otherDateLocations,
        ...updatedLocationsForDate,
        ...skippedLocationsForDate,
        ...doneLocationsForDate,
      ];

      final totalTravelTime =
          _calculateTotalTime(finalOptimizedLocationsForDate, legDetails);
      final totalDistance = legDetails.fold(0.0,
          (sum, leg) => sum + ((leg['distance'] as num?)?.toDouble() ?? 0.0));

      // Resolve the baseline and derive the saved-time delta. Compare pure
      // travel legs on both sides (stay durations are identical either way).
      // Clamp at zero: the greedy optimizer can occasionally lose to the
      // user's own order — never show a negative "saving."
      final optimizedTravel = legDetails.fold<Duration>(
          Duration.zero, (sum, leg) => sum + (leg['duration'] as Duration));
      var timeSaved = Duration.zero;
      final baselineTravel = await baselineTravelFuture;
      if (baselineTravel != null && legDetails.isNotEmpty) {
        final delta = baselineTravel - optimizedTravel;
        if (!delta.isNegative) timeSaved = delta;
      }

      state = state.copyWith(
        pinnedLocations: updatedPinnedLocations,
        isRoutePreview: false,
        optimizedLocationsForSelectedDate: finalOptimizedLocationsForDate,
        optimizedRoute: routePoints,
        legPolylines: legPolylines,
        legDetails: legDetails,
        totalTravelTime: totalTravelTime,
        totalDistance: totalDistance,
        timeSaved: timeSaved,
        originalOrderForSelectedDate: originalOrder,
      );

      _ref.read(zoomToFitRouteTrigger.notifier).update((state) => state + 1);

      // Funnel analytics: the activation "aha" — only when a real route was
      // produced (skip the timeout/empty-result path that still writes state).
      final optimizeSucceeded = state.optimizedRoute.isNotEmpty;
      if (optimizeSucceeded) {
        AnalyticsService.instance.routeOptimized(
          state.optimizedLocationsForSelectedDate.length,
          minutesSaved: timeSaved.inMinutes,
        );
        // Social currency: accrue the lifetime time-saved ledger. Keyed per
        // trip-day with a max policy, so re-optimizing never double-counts.
        if (timeSaved > Duration.zero) {
          final ledgerTripId =
              _ref.read(realtimeActiveTripProvider).valueOrNull?.id ?? 'local';
          final dayIso = selectedDate.toIso8601String().split('T').first;
          unawaited(TimeSavedLedgerService.instance
              .credit(dayKey: '$ledgerTripId|$dayIso', saved: timeSaved));
        }
      }

      // Delight moment: a successful optimization. Record the signal, then
      // (if all engagement/cooldown gates pass) signal the UI to run the
      // sentiment-gated review flow. The OS prompt is only ever reached after
      // the user confirms they're happy.
      //
      // The FIRST-ever optimize gets the one-time celebration instead (via
      // [firstOptimizeCelebrationTrigger]); it IS that run's delight moment,
      // so the review-prompt signal is skipped to guarantee the two dialogs
      // can never stack. The map_screen listener owns the celebrated flag —
      // it re-checks, defers to the timing-warnings sheet when one is due,
      // and only marks the flag when the celebration actually shows.
      unawaited(() async {
        var celebrationPending = false;
        if (optimizeSucceeded) {
          // Checklist step 4. If this completes the list, the notifier
          // marks the firstOptimize milestone celebrated itself, so the
          // generic celebration below is skipped in favor of the
          // checklist one — never two dialogs for one optimize.
          await _ref
              .read(checklistProvider.notifier)
              .mark(ChecklistStep.optimizeRoute);
          // FIRST-OPTIMIZE CELEBRATION DISABLED (owner request 2026-08-07).
          // celebrationPending stays false so the review-prompt cadence
          // below is unaffected. To revive, uncomment this block and the
          // firstOptimizeCelebrationTrigger listener in map_screen.dart.
          // final userId =
          //     _ref.read(currentUserIdProvider) ?? await AnonymousUserService.id;
          // if (!await OnboardingService.instance
          //     .hasCelebrated(userId, OnboardingMilestone.firstOptimize)) {
          //   celebrationPending = true;
          //   _ref
          //       .read(firstOptimizeCelebrationTrigger.notifier)
          //       .update((s) => s + 1);
          // }
        }
        await ReviewPromptService.instance.recordSuccessfulOptimize();
        if (!celebrationPending) {
          await _maybeSignalReviewPrompt();
        }
        // Plan Card: once EVERY day of the active trip has been optimized,
        // the plan is "done" — the pre-trip social-currency moment. Never
        // stacked on the first-optimize celebration (skipped this run; a
        // later optimize re-checks and fires it).
        if (optimizeSucceeded && !celebrationPending) {
          await _maybeSignalPlanComplete(selectedDate);
        }
      }());
    } catch (e) {
      log('Error generating route: $e');
    } finally {
      _ref.read(isGeneratingRouteProvider.notifier).state = false;
    }
  }

  /// Plan-complete detector for the Plan Card (authed active-trip flow only —
  /// the public itinerary link is the card's gift). Records the just-optimized
  /// day in a per-trip SharedPrefs set; when the set covers every day that has
  /// unskipped places, bumps [planCardReadyTrigger] (map_screen owns the
  /// shown-once flag, mirroring the celebration pattern).
  Future<void> _maybeSignalPlanComplete(DateTime selectedDate) async {
    try {
      final trip = _ref.read(realtimeActiveTripProvider).valueOrNull;
      if (trip == null) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('plan_card_shown_${trip.id}') ?? false) return;

      final dayIso = selectedDate.toIso8601String().split('T').first;
      final key = 'plan_days_optimized_${trip.id}';
      final done = (prefs.getStringList(key) ?? <String>[]).toSet()
        ..add(dayIso);
      await prefs.setStringList(key, done.toList());

      final tripDays = state.pinnedLocations
          .where((l) => l.scheduledDate != null && !l.isSkipped)
          .map((l) {
        final d = l.scheduledDate!;
        return DateTime(d.year, d.month, d.day)
            .toIso8601String()
            .split('T')
            .first;
      }).toSet();
      if (tripDays.isEmpty || !done.containsAll(tripDays)) return;

      _ref.read(planCardReadyTrigger.notifier).update((s) => s + 1);
    } catch (e) {
      debugPrint('TripNotifier._maybeSignalPlanComplete: $e');
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
      optimizedLocationsForSelectedDate: [],
      isRoutePreview: false, // Clear optimized list
      legPolylines: [],
      legDetails: [],
      totalTravelTime: Duration.zero,
      totalDistance: 0.0,
    );
  }

  /// Per-leg mode override (multi-modal Phase 4): re-routes ONE leg of the
  /// current optimized route in [mode], patches the route state in place,
  /// and persists the choice per (trip, fromId, toId) so every future
  /// optimize of this trip keeps it. Returns false — state untouched — when
  /// no route exists in that mode for this leg.
  Future<bool> overrideLegMode(int legIndex, String mode) async {
    final legs = List<Map<String, dynamic>>.from(state.legDetails);
    final polys = List<List<LatLng>>.from(state.legPolylines);
    if (legIndex < 0 ||
        legIndex >= legs.length ||
        legs.length != polys.length ||
        polys[legIndex].isEmpty) {
      return false;
    }
    final old = legs[legIndex];

    LatLng coordFor(String? id, LatLng fallback) {
      if (id == null) return fallback;
      if (id == 'current_location') return state.currentLocation ?? fallback;
      final match = state.pinnedLocations.where((l) => l.id == id);
      return match.isNotEmpty ? match.first.coordinates : fallback;
    }

    final from = coordFor(old['fromId'] as String?, polys[legIndex].first);
    final to = coordFor(old['toId'] as String?, polys[legIndex].last);

    // Transit schedules need a departure estimate: trip start + everything
    // before this leg (travel + dwell). Display-grade, not timetable-grade.
    var departure = _ref.read(effectiveTripStartTimeProvider);
    for (var i = 0; i < legIndex; i++) {
      departure = departure
          .add((legs[i]['duration'] as Duration?) ?? Duration.zero)
          .add(const Duration(minutes: 60));
    }

    final leg = await MultiModalRouter.routeSingleLeg(
      from: from,
      to: to,
      mode: mode,
      departureTime: departure,
    );
    if (leg == null) return false;

    return applyLegRoute(legIndex, leg);
  }

  /// Applies a specific routed [leg] to position [legIndex] — the shared
  /// patch behind BOTH the mode switcher and the route-options picker.
  /// Persists the leg's MODE (re-optimizes keep it); the specific
  /// alternative route is deliberately not persisted — Google re-ranks
  /// options with fresh schedules on every optimize, and pinning a stale
  /// route identity would silently rot.
  Future<bool> applyLegRoute(int legIndex, LegRoute leg) async {
    final legs = List<Map<String, dynamic>>.from(state.legDetails);
    final polys = List<List<LatLng>>.from(state.legPolylines);
    if (legIndex < 0 ||
        legIndex >= legs.length ||
        legs.length != polys.length ||
        leg.points.isEmpty) {
      return false;
    }
    final old = legs[legIndex];

    legs[legIndex] = {
      'duration': leg.duration,
      'distance': leg.distance,
      'mode': leg.mode,
      'fromId': old['fromId'],
      'toId': old['toId'],
      if (leg.transit != null) 'transit': leg.transit,
      if (leg.steps != null) 'transitSteps': leg.steps,
      if (leg.departureTime != null) 'departureTime': leg.departureTime,
      if (leg.arrivalTime != null) 'arrivalTime': leg.arrivalTime,
    };
    polys[legIndex] = leg.points;

    // The destination stop's travel-from-previous facts feed the list cards
    // and the timing sim — keep them in sync with the new leg.
    final toId = old['toId'] as String?;
    List<LocationModel> patch(List<LocationModel> list) => [
          for (final l in list)
            l.id == toId
                ? l.copyWith(
                    travelTimeFromPrevious: leg.duration,
                    distanceFromPrevious: leg.distance,
                  )
                : l
        ];

    state = state.copyWith(
      legDetails: legs,
      legPolylines: polys,
      optimizedRoute: polys.expand((p) => p).toList(growable: false),
      totalTravelTime: legs.fold<Duration>(Duration.zero,
          (sum, l) => sum + ((l['duration'] as Duration?) ?? Duration.zero)),
      totalDistance: legs.fold<double>(
          0, (sum, l) => sum + (((l['distance'] as num?) ?? 0).toDouble())),
      pinnedLocations: patch(state.pinnedLocations),
      optimizedLocationsForSelectedDate:
          patch(state.optimizedLocationsForSelectedDate),
    );

    // Persist so the ladder honors this leg's mode on every re-optimize.
    final tripId = state.pinnedLocations.isNotEmpty
        ? (state.pinnedLocations.first.tripId ?? 'no_trip')
        : 'no_trip';
    final fromId = old['fromId'] as String?;
    if (fromId != null && toId != null) {
      await LegModePrefs.setLegMode(tripId, fromId, toId, leg.mode);
    }
    return true;
  }

  /// Renders a single-leg route between two specific locations on the map by
  /// reusing the existing `optimizedRoute` / `legPolylines` slots that the
  /// map overlay reads from. This is the "From → To" preview triggered from
  /// the location detail sheet — it overrides any prior multi-stop optimized
  /// route, which is intentional: the user is asking to see this specific
  /// pair, and the existing Clear Route controls can wipe it just like an
  /// optimization result.
  Future<void> previewRouteBetween(LocationModel from, LocationModel to) async {
    if (from.id == to.id) return;
    _ref.read(isGeneratingRouteProvider.notifier).state = true;
    try {
      // Same brain as the optimizer: honor a stored per-leg override for
      // this exact pair, then run the AUTO ladder with the user's max-walk
      // preference — the preview used to hardcode the car.
      final previewTripId = from.tripId ?? 'no_trip';
      final previewOverrides =
          await LegModePrefs.overridesForTrip(previewTripId);
      final prefMaxWalk = await LegModePrefs.maxWalkMeters();
      final leg = await MultiModalRouter.routeLegSmart(
        from: from.coordinates,
        to: to.coordinates,
        overrideMode:
            previewOverrides[LegModePrefs.legOverrideKey(from.id, to.id)],
        maxWalkMeters: prefMaxWalk.toDouble(),
        departureTime: DateTime.now().add(const Duration(minutes: 10)),
      ).timeout(const Duration(seconds: 25), onTimeout: () => null);

      if (leg == null || leg.points.isEmpty) {
        // API failure / timeout — leave existing state alone so we don't
        // wipe a previously-rendered route on a transient error.
        return;
      }

      final routePoints = leg.points;
      final legDetails = <Map<String, dynamic>>[
        {
          'duration': leg.duration,
          'distance': leg.distance,
          'mode': leg.mode,
          'fromId': from.id,
          'toId': to.id,
          if (leg.transit != null) 'transit': leg.transit,
          if (leg.steps != null) 'transitSteps': leg.steps,
          if (leg.departureTime != null) 'departureTime': leg.departureTime,
          if (leg.arrivalTime != null) 'arrivalTime': leg.arrivalTime,
        }
      ];
      final legPolylines = <List<LatLng>>[leg.points];

      final totalTravelTime = legDetails.fold<Duration>(
        Duration.zero,
        (sum, leg) => sum + ((leg['duration'] as Duration?) ?? Duration.zero),
      );
      final totalDistance = legDetails.fold<double>(
        0.0,
        (sum, leg) => sum + ((leg['distance'] as num?)?.toDouble() ?? 0.0),
      );

      // Annotate the destination with this leg's travel info so the
      // existing "Travel from Previous Stop" UI can read it without a
      // separate code path.
      final pinned = state.pinnedLocations;
      final updatedPinned = [
        for (final loc in pinned)
          if (loc.id == to.id)
            loc.copyWith(
              travelTimeFromPrevious: legDetails.isNotEmpty
                  ? legDetails.first['duration'] as Duration?
                  : null,
              distanceFromPrevious: legDetails.isNotEmpty
                  ? (legDetails.first['distance'] as num?)?.toDouble()
                  : null,
            )
          else
            loc,
      ];

      final updatedFrom =
          updatedPinned.firstWhere((l) => l.id == from.id, orElse: () => from);
      final updatedTo =
          updatedPinned.firstWhere((l) => l.id == to.id, orElse: () => to);

      state = state.copyWith(
        pinnedLocations: updatedPinned,
        isRoutePreview: true,
        optimizedLocationsForSelectedDate: [updatedFrom, updatedTo],
        optimizedRoute: routePoints,
        legPolylines: legPolylines,
        legDetails: legDetails,
        totalTravelTime: totalTravelTime,
        totalDistance: totalDistance,
        startLocationId: from.id,
      );

      _ref.read(zoomToFitRouteTrigger.notifier).update((s) => s + 1);
    } catch (e) {
      debugPrint('previewRouteBetween failed: $e');
    } finally {
      _ref.read(isGeneratingRouteProvider.notifier).state = false;
    }
  }

  void clearTrip() {
    // Reset trip data and clear all locations from local storage
    state = state.copyWith(
      pinnedLocations: [],
      optimizedLocationsForSelectedDate: [],
      isRoutePreview: false, // Clear optimized list
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

/// Signals the UI (map screen) to run the gated review-prompt sentiment flow.
/// Bumped only after a delight moment when [ReviewPromptService.isEligibleForPrompt]
/// has already passed, so the listener can show the dialog immediately.
final reviewPromptTriggerProvider = StateProvider<int>((ref) => 0);

/// Signals the UI (map screen) that a just-finished optimize is the user's
/// FIRST ever, so it can show the one-time celebration. The listener owns
/// the per-user "celebrated" flag: it re-checks it, defers to the
/// timing-warnings sheet when one is due (leaving the flag unset so the
/// next optimize celebrates instead), and marks it only on actual show.
final firstOptimizeCelebrationTrigger = StateProvider<int>((ref) => 0);

/// Bumped when the active trip's plan becomes fully optimized (every day
/// with places has a route) — map_screen listens and shows the Plan Card
/// dialog once per trip.
final planCardReadyTrigger = StateProvider<int>((ref) => 0);

/// Bumped by "share this route" affordances that live OUTSIDE map_screen
/// (the bottom-sheet summary button) — map_screen listens, captures a live
/// map snapshot, and builds the realistic share image. Kept here so any
/// widget can request a share without holding the map controller.
final shareRouteMapTrigger = StateProvider<int>((ref) => 0);

/// A provider that exposes details of the currently selected route leg.
/// The UI can watch this to show/hide the "Open in Maps" button.
final selectedLegDetailsProvider = Provider<Map<String, dynamic>?>((ref) {
  // Narrow watches (moving-pin hygiene): the full tripProvider would
  // rebuild this on every GPS tick via currentLocation.
  final selectedIndex =
      ref.watch(tripProvider.select((s) => s.selectedLegIndex));
  final legDetails = ref.watch(tripProvider.select((s) => s.legDetails));
  final legPolylines = ref.watch(tripProvider.select((s) => s.legPolylines));

  if (selectedIndex == null || selectedIndex >= legDetails.length) {
    return null;
  }

  final legDetail = legDetails[selectedIndex];
  final legPolyline = legPolylines[selectedIndex];

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

      // Skipped/done locations active on this date, minus anything already
      // present in the optimized list. Multi-day stays match via the range
      // check, so a "done" hotel still shows on every day it covers.
      final isPreview = ref.watch(tripProvider.select((s) => s.isRoutePreview));
      final skippedForDate = pinnedLocations.where((loc) {
        if (optimizedIds.contains(loc.id)) return false;
        // Point-to-point preview: EVERY other location of the day stays on
        // the map around the previewed pair — only a real optimized route
        // narrows the extras down to skipped/done.
        if (!isPreview && !loc.isSkipped && !loc.isDone) return false;
        return loc.isActiveOnDate(selectedDate);
      }).toList();
      // Return the optimized locations first, followed by the skipped ones.
      return [...optimizedLocations, ...skippedForDate];
    }
  }

  // Fallback: every location active on this date (single-day rows match
  // only their day; range rows match every day in their `[start..end]`).
  return pinnedLocations
      .where((loc) => loc.isActiveOnDate(selectedDate))
      .toList();
});

/// Every date covered by any location's active range. Multi-day stays
/// contribute every day in their `[scheduledDate..scheduledEndDate]` so the
/// date picker's "has locations" dots show up on every covered day.
final datesWithLocationsProvider = Provider<Set<DateTime>>((ref) {
  final allLocations = ref.watch(tripProvider.select((s) => s.pinnedLocations));
  final Set<DateTime> dates = {};
  for (final loc in allLocations) {
    if (loc.scheduledDate == null) continue;
    final start = DateTime(loc.scheduledDate!.year, loc.scheduledDate!.month,
        loc.scheduledDate!.day);
    final endRaw = loc.scheduledEndDate ?? loc.scheduledDate!;
    final end = DateTime(endRaw.year, endRaw.month, endRaw.day);
    // Step by calendar day (not Duration(days:1)) so keys stay on local
    // midnight across DST transitions and match the pickers' day values.
    for (var d = start;
        !d.isAfter(end);
        d = DateTime(d.year, d.month, d.day + 1)) {
      dates.add(d);
    }
  }
  return dates;
});
