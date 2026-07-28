import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/main.dart';
import '../models/trip.dart';
import 'user_trip_provider.dart';
import 'trip_collaborator_provider.dart';

/// Provider for managing local active trip state
/// This is stored locally per user and not synced to the database
/// Each user can activate their own trips independently

class LocalActiveTripNotifier extends StateNotifier<String?> {
  LocalActiveTripNotifier() : super(null) {
    _loadActiveTripId();
  }

  static const _activeTripKey = 'local_active_trip_id';

  void _loadActiveTripId() {
    // PERFORMANCE: Use cached SharedPreferences - no async needed
    final prefs = SharedPrefsCache.instance;
    final tripId = prefs.getString(_activeTripKey);
    if (tripId != null) {
      debugPrint(
          'LocalActiveTripNotifier: 📂 Loaded active trip from storage: $tripId');
    } else {
      debugPrint('LocalActiveTripNotifier: No active trip stored');
    }
    state = tripId;
  }

  Future<void> setActiveTrip(String tripId) async {
    debugPrint(
        'LocalActiveTripNotifier: 💾 Saving active trip to storage: $tripId');
    final prefs = SharedPrefsCache.instance;
    await prefs.setString(_activeTripKey, tripId);
    state = tripId;
    debugPrint('LocalActiveTripNotifier: ✅ Active trip saved successfully');
  }

  Future<void> deactivateTrip() async {
    debugPrint('LocalActiveTripNotifier: 🔄 Deactivating trip...');
    final prefs = SharedPrefsCache.instance;
    await prefs.remove(_activeTripKey);
    state = null;
    debugPrint('LocalActiveTripNotifier: ✅ Trip deactivated successfully');
  }

  Future<void> clear() async {
    final prefs = SharedPrefsCache.instance;
    await prefs.remove(_activeTripKey);
    state = null;
  }
}

/// Provider for the local active trip ID (stored in shared preferences)
final localActiveTripIdProvider =
    StateNotifierProvider<LocalActiveTripNotifier, String?>((ref) {
  return LocalActiveTripNotifier();
});

/// Provider that returns the full Trip object for the locally active trip
/// Combines the local active trip ID with trip data from userTripsProvider and sharedTripsProvider
/// IMPORTANT: This preserves the active trip across app restarts by waiting for data to load
final localActiveTripProvider = FutureProvider<Trip?>((ref) async {
  final activeTripId = ref.watch(localActiveTripIdProvider);

  if (activeTripId == null) {
    debugPrint('LocalActiveTripProvider: No active trip ID stored');
    return null;
  }

  debugPrint('LocalActiveTripProvider: Looking for trip: $activeTripId');

  // CRITICAL: Wait for both providers to finish loading before checking
  // This prevents clearing the active trip during app startup when providers are still loading
  final userTripsAsync = ref.watch(userTripsProvider);
  final sharedTripsAsync = ref.watch(sharedTripsProvider);

  // If either provider is still loading, return null but DON'T clear the stored trip ID
  // This allows the trip to persist through app restarts without interruption
  // Refreshes (e.g. a date-range edit invalidating userTripsProvider)
  // RETAIN the previous list — only a true first load has no value yet.
  // Bailing on every refresh nulled the active trip for a frame, which
  // cascaded into a visible "page reload" of the map sheet.
  if ((userTripsAsync.isLoading && !userTripsAsync.hasValue) ||
      (sharedTripsAsync.isLoading && !sharedTripsAsync.hasValue)) {
    debugPrint('LocalActiveTripProvider: ⏳ Waiting for trips to load...');
    return null; // Still loading, keep the stored trip ID
  }

  debugPrint(
      'LocalActiveTripProvider: ✅ Trips loaded, searching for active trip...');

  // Now that both providers are loaded, try to find the trip
  final userTrips = userTripsAsync.valueOrNull ?? [];

  for (final trip in userTrips) {
    if (trip.id == activeTripId) {
      debugPrint(
          'LocalActiveTripProvider: ✅ Found trip in user trips: ${trip.name}');
      return trip;
    }
  }

  // Try to find in shared trips.
  //
  // The shared-trips list embeds a SUBSET of trip columns via the
  // collaborator → trips PostgREST join. To guarantee every column is
  // populated (start_date, end_date, country_code, etc. — the badge and
  // country guard depend on these), we use the embed only to confirm the
  // active trip is one the user can see, then re-fetch the canonical row
  // from the trips table by id.
  final sharedTripsData = sharedTripsAsync.valueOrNull ?? [];

  for (final sharedTripData in sharedTripsData) {
    final trip = sharedTripData['trips'] as Map<String, dynamic>?;
    if (trip != null && trip['id'] == activeTripId) {
      try {
        final repo = ref.read(tripRepositoryProvider);
        final fresh = await repo.getTripById(activeTripId);
        if (fresh != null) {
          debugPrint(
              'LocalActiveTripProvider: ✅ Found trip in shared trips: ${fresh.name}');
          return fresh;
        }
      } catch (e) {
        debugPrint('LocalActiveTripProvider: ⚠️ getTripById failed, '
            'falling back to embedded shape: $e');
      }
      // Embed-only fallback if the direct fetch fails (network / RLS) —
      // at least the user keeps a usable active trip object.
      final tripObj = Trip.fromJson(trip);
      debugPrint(
          'LocalActiveTripProvider: ✅ Found trip in shared trips (embed fallback): ${tripObj.name}');
      return tripObj;
    }
  }

  // Trip not found. Only treat that as "deleted or access lost" when BOTH
  // providers are fully settled: during a refresh the retained lists are
  // STALE, and a just-created/just-activated trip is legitimately absent
  // from them — deactivating here erased the active trip the user set
  // milliseconds earlier (create-then-activate race). While refreshing,
  // keep the stored id and emit null for this frame; the refetch re-runs
  // this provider and resolves the trip.
  if (userTripsAsync.isLoading || sharedTripsAsync.isLoading) {
    debugPrint(
        'LocalActiveTripProvider: ⏳ Trip not in STALE lists, waiting for refresh...');
    return null;
  }
  debugPrint(
      'LocalActiveTripProvider: ⚠️ Trip not found (deleted or access lost), clearing...');
  await ref.read(localActiveTripIdProvider.notifier).deactivateTrip();
  return null;
});
