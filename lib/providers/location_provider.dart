import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../repositories/location_repository.dart';
import '../models/saved_location.dart';
import 'auth_provider.dart';
import 'connectivity_provider.dart';

final locationRepositoryProvider = Provider<LocationRepository>((ref) {
  return LocationRepository();
});

final savedLocationsProvider = StreamProvider<List<SavedLocation>>((ref) {
  final repository = ref.watch(locationRepositoryProvider);
  return repository.watchLocations();
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
