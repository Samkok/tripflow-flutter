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
/// - If a trip is active: show only locations from that trip
/// - If no trip is active: show NO locations (empty list)
///
/// This provider properly integrates with realtimeActiveTripProvider
/// to ensure locations update when trip activation/deactivation happens
final filteredLocationsForMapProvider =
    StreamProvider<List<SavedLocation>>((ref) async* {
  // Watch the realtime active trip (key integration point!)
  final activeTripAsync = ref.watch(realtimeActiveTripProvider);
  
  // Get the actual stream from the repository
  final repository = ref.watch(locationRepositoryProvider);
  final locationsStream = repository.watchLocations();

  // Subscribe to location updates
  await for (final locations in locationsStream) {
    // Get current active trip
    final activeTrip = activeTripAsync.asData?.value;

    if (activeTrip != null) {
      // Trip is active: filter to only locations in this trip
      yield locations
          .where((loc) => loc.tripId == activeTrip.id)
          .toList();
    } else {
      // No trip is active: yield empty list
      yield <SavedLocation>[];
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
