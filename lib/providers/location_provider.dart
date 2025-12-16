import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../repositories/location_repository.dart';
import '../models/saved_location.dart';
import 'auth_provider.dart';
import 'connectivity_provider.dart';
import 'trip_listener_provider.dart';

final locationRepositoryProvider = Provider<LocationRepository>((ref) {
  return LocationRepository();
});

final savedLocationsProvider = StreamProvider<List<SavedLocation>>((ref) {
  final repository = ref.watch(locationRepositoryProvider);
  return repository.watchLocations();
});

/// Filter locations based on active trip with REAL-TIME updates
/// - If a trip is active: show only locations that belong to that trip
/// - If no trip is active BUT user is anonymous: show all local locations (for anonymous mode)
/// - If no trip is active AND user is authenticated: show locations that don't belong to any trip
///
/// This provider reacts to BOTH trip changes AND location stream changes
final filteredLocationsForMapProvider =
    StreamProvider<List<SavedLocation>>((ref) async* {
  // Watch the realtime active trip - will trigger provider rebuild when trip changes
  final activeTripAsync = ref.watch(realtimeActiveTripProvider);

  // Watch auth state to determine if user is anonymous
  final authState = ref.watch(authStateProvider);

  // Get the actual stream from the repository
  final repository = ref.watch(locationRepositoryProvider);

  // First, get all locations from the stream
  final locationsStream = repository.watchLocations();

  debugPrint('filteredLocationsForMapProvider: Starting to listen for location changes');

  // Whenever we reach here (due to trip or ref changes), start listening to locations
  // The key is that ref.watch(realtimeActiveTripProvider) will cause this entire
  // provider to rebuild when the trip changes
  await for (final locations in locationsStream) {
    // Get current active trip from the watched async value
    final activeTrip = activeTripAsync.asData?.value;

    // Check if user is authenticated
    final isAuthenticated = authState.asData?.value.session?.user != null;

    if (activeTrip != null) {
      // Trip is active: filter to only locations in this trip
      final filtered = locations
          .where((loc) => loc.tripId == activeTrip.id)
          .toList();
      debugPrint('filteredLocationsForMapProvider: ✅ Trip ${activeTrip.name} (${activeTrip.id}) active → emitting ${filtered.length}/${locations.length} locations');
      yield filtered;
    } else if (!isAuthenticated) {
      // Anonymous user with no active trip: show all local locations
      final localLocations = locations
          .where((loc) => loc.source == 'local')
          .toList();
      debugPrint('filteredLocationsForMapProvider: 👤 Anonymous mode → emitting ${localLocations.length} local locations');
      yield localLocations;
    } else {
      // Authenticated user with no active trip: show only locations that don't belong to any trip
      final unassignedLocations = locations
          .where((loc) => loc.tripId == null || loc.tripId!.isEmpty)
          .toList();
      debugPrint('filteredLocationsForMapProvider: 📍 No trip active (authenticated) → emitting ${unassignedLocations.length} unassigned locations');
      yield unassignedLocations;
    }
  }
});


// This provider listens to connectivity changes and auth state to trigger sync
final syncManagerProvider = Provider<void>((ref) {
  final connectivity = ref.watch(connectivityProvider);
  final authState = ref.watch(authStateProvider); // Watch full auth state
  final repository = ref.watch(locationRepositoryProvider);

  // Check if we have a user from the auth state data
  final user = authState.asData?.value.session?.user;

  if (user != null && connectivity == ConnectivityStatus.isConnected) {
    // Perform full sync (including anonymous migration)
    repository.syncOnLogin();

    // Start listening to realtime changes
    repository.subscribeToRealtimeChanges();
  } else {
    // If logged out or offline, might want to stop subscription
    repository.unsubscribe();
  }
});
