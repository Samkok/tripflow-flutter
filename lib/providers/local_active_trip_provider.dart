import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  Future<void> _loadActiveTripId() async {
    final prefs = await SharedPreferences.getInstance();
    final tripId = prefs.getString(_activeTripKey);
    if (tripId != null) {
      debugPrint('LocalActiveTripNotifier: 📂 Loaded active trip from storage: $tripId');
    } else {
      debugPrint('LocalActiveTripNotifier: No active trip stored');
    }
    state = tripId;
  }

  Future<void> setActiveTrip(String tripId) async {
    debugPrint('LocalActiveTripNotifier: 💾 Saving active trip to storage: $tripId');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeTripKey, tripId);
    state = tripId;
    debugPrint('LocalActiveTripNotifier: ✅ Active trip saved successfully');
  }

  Future<void> deactivateTrip() async {
    debugPrint('LocalActiveTripNotifier: 🔄 Deactivating trip...');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeTripKey);
    state = null;
    debugPrint('LocalActiveTripNotifier: ✅ Trip deactivated successfully');
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
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
  if (userTripsAsync.isLoading || sharedTripsAsync.isLoading) {
    debugPrint('LocalActiveTripProvider: ⏳ Waiting for trips to load...');
    return null; // Still loading, keep the stored trip ID
  }

  debugPrint('LocalActiveTripProvider: ✅ Trips loaded, searching for active trip...');

  // Now that both providers are loaded, try to find the trip
  final userTrips = userTripsAsync.asData?.value ?? [];

  for (final trip in userTrips) {
    if (trip.id == activeTripId) {
      debugPrint('LocalActiveTripProvider: ✅ Found trip in user trips: ${trip.name}');
      return trip;
    }
  }

  // Try to find in shared trips
  final sharedTripsData = sharedTripsAsync.asData?.value ?? [];

  for (final sharedTripData in sharedTripsData) {
    final trip = sharedTripData['trips'] as Map<String, dynamic>?;
    if (trip != null && trip['id'] == activeTripId) {
      final tripObj = Trip.fromJson(trip);
      debugPrint('LocalActiveTripProvider: ✅ Found trip in shared trips: ${tripObj.name}');
      return tripObj;
    }
  }

  // Trip not found AFTER both providers finished loading
  // This means the trip was deleted or user lost access
  // NOW it's safe to clear the stored active trip ID
  debugPrint('LocalActiveTripProvider: ⚠️ Trip not found (deleted or access lost), clearing...');
  await ref.read(localActiveTripIdProvider.notifier).deactivateTrip();
  return null;
});
