import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/trip_collaborator.dart';
import '../repositories/trip_collaborator_repository.dart';
import '../services/collaborator_realtime_service.dart';
import 'trip_listener_provider.dart';
import 'local_active_trip_provider.dart';
import 'auth_provider.dart';

/// Provider for the TripCollaboratorRepository
final tripCollaboratorRepositoryProvider = Provider<TripCollaboratorRepository>((ref) {
  return TripCollaboratorRepository();
});

/// Provider for the CollaboratorRealtimeService singleton
final collaboratorRealtimeServiceProvider = Provider<CollaboratorRealtimeService>((ref) {
  return CollaboratorRealtimeService();
});

/// Simple counter that increments when collaborator events occur
/// This is used to trigger refreshes without causing cascading rebuilds
final _collaboratorRefreshCounterProvider = StateProvider<int>((ref) => 0);

/// Notifier that manages collaborator realtime subscriptions
class CollaboratorRealtimeNotifier extends StateNotifier<int> {
  final Ref _ref;
  StreamSubscription<CollaboratorEvent>? _subscription;

  CollaboratorRealtimeNotifier(this._ref) : super(0) {
    _initialize();
  }

  void _initialize() {
    final service = _ref.read(collaboratorRealtimeServiceProvider);
    service.subscribe();

    // Listen to the event stream and handle events
    _subscription = service.eventStream.listen((event) {
      debugPrint('CollaboratorRealtime: Received event - $event');

      // Increment counter to trigger rebuilds
      state++;
      _ref.read(_collaboratorRefreshCounterProvider.notifier).state++;

      // Handle specific events
      _handleEvent(event);
    });
  }

  void _handleEvent(CollaboratorEvent event) {
    debugPrint('CollaboratorRealtimeNotifier: Handling event - $event');

    if (event.type == CollaboratorEventType.removed) {
      // User was removed from a trip
      // Check if the removed collaborator is for the currently active trip
      final activeTripAsync = _ref.read(realtimeActiveTripProvider);
      final activeTrip = activeTripAsync.asData?.value;

      if (activeTrip != null && event.tripId == activeTrip.id) {
        debugPrint('CollaboratorRealtimeNotifier: ⚠️ User removed from active trip ${activeTrip.name}, deactivating...');
        _ref.read(localActiveTripIdProvider.notifier).deactivateTrip();
      }

      // Invalidate shared trips to refresh the list
      _ref.invalidate(sharedTripsProvider);

    } else if (event.type == CollaboratorEventType.updated) {
      // Permission changed - this is the MOST COMMON case
      debugPrint('CollaboratorRealtimeNotifier: 🔄 Permission updated for trip ${event.tripId}');
      debugPrint('CollaboratorRealtimeNotifier: New permission: ${event.permission}');

      // CRITICAL: Only invalidate the specific trip's permission providers
      // This ensures fresh data is fetched WITHOUT disrupting other trips or UI
      _ref.invalidate(hasWriteAccessProvider(event.tripId));
      _ref.invalidate(userTripPermissionProvider(event.tripId));

      // Increment counter to signal permission change
      // Riverpod's caching will ensure widgets only rebuild if the actual VALUE changes
      _ref.read(_collaboratorRefreshCounterProvider.notifier).state++;

      debugPrint('CollaboratorRealtimeNotifier: ✅ Permission providers invalidated, UI will update smoothly');

    } else if (event.type == CollaboratorEventType.added) {
      // New trip shared with user
      debugPrint('CollaboratorRealtimeNotifier: ➕ New trip shared: ${event.tripId}');

      // Refresh shared trips list to show the new trip
      _ref.invalidate(sharedTripsProvider);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

/// Provider for the collaborator realtime notifier
/// Watch this in your root widget to initialize realtime subscriptions
final collaboratorRealtimeInitProvider = StateNotifierProvider<CollaboratorRealtimeNotifier, int>((ref) {
  return CollaboratorRealtimeNotifier(ref);
});

/// Provider for getting collaborators of a specific trip
final tripCollaboratorsProvider = FutureProvider.family<List<TripCollaborator>, String>((ref, tripId) async {
  // Watch refresh counter to trigger rebuild on collaborator changes
  ref.watch(_collaboratorRefreshCounterProvider);

  final repository = ref.watch(tripCollaboratorRepositoryProvider);
  return repository.getCollaborators(tripId);
});

/// Provider for shared trips (trips where current user is a collaborator)
final sharedTripsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  // Watch auth state to trigger refresh on sign in/out
  final authState = ref.watch(authStateProvider);
  
  // Watch refresh counter to trigger rebuild on collaborator changes
  ref.watch(_collaboratorRefreshCounterProvider);

  // Only fetch shared trips if user is authenticated
  return authState.when(
    data: (state) {
      if (state.session == null) return [];
      
      final repository = ref.watch(tripCollaboratorRepositoryProvider);
      return repository.getSharedTrips();
    },
    loading: () => [],
    error: (_, __) => [],
  );
});

/// Provider to check if user is the owner of a trip
final isTripOwnerProvider = FutureProvider.family<bool, String>((ref, tripId) async {
  final repository = ref.watch(tripCollaboratorRepositoryProvider);
  return repository.isOwner(tripId);
});

/// Provider to get user's permission on a trip
final userTripPermissionProvider = FutureProvider.family<String?, String>((ref, tripId) async {
  // Watch refresh counter to trigger rebuild on permission changes
  ref.watch(_collaboratorRefreshCounterProvider);

  final repository = ref.watch(tripCollaboratorRepositoryProvider);
  return repository.getUserPermission(tripId);
});

/// Provider to check if user has write access to a trip
final hasWriteAccessProvider = FutureProvider.family<bool, String>((ref, tripId) async {
  // Watch refresh counter to trigger rebuild on permission changes
  ref.watch(_collaboratorRefreshCounterProvider);

  final repository = ref.watch(tripCollaboratorRepositoryProvider);

  // Check if owner
  final isOwner = await repository.isOwner(tripId);
  if (isOwner) return true;

  // Check if collaborator with write permission
  final permission = await repository.getUserPermission(tripId);
  return permission == 'write';
});

/// Provider to check if user has write access to the currently ACTIVE trip
/// This is used by map screen, location detail sheet, etc. to protect write operations
/// Returns true if:
/// - No trip is active (user can always edit their own non-trip locations)
/// - User is the owner of the active trip
/// - User has write permission on the active trip
///
/// CRITICAL: This is a FutureProvider that re-fetches permissions on every change
/// to ensure permissions are always up-to-date, preventing RLS bypass issues
final hasActiveTripWriteAccessProvider = FutureProvider<bool>((ref) async {
  // Watch refresh counter to trigger rebuild on permission changes
  ref.watch(_collaboratorRefreshCounterProvider);

  final activeTripAsync = ref.watch(realtimeActiveTripProvider);

  return await activeTripAsync.when(
    data: (activeTrip) async {
      if (activeTrip == null) {
        // No active trip - user can edit their own non-trip locations
        return true;
      }

      // Fetch the LATEST write access for the active trip
      // This ensures we always have fresh permission data from Supabase
      final writeAccess = await ref.watch(hasWriteAccessProvider(activeTrip.id).future);
      return writeAccess;
    },
    loading: () async => false, // Loading state - deny access to be safe
    error: (e, st) async => false, // Error state - deny access to be safe
  );
});

/// Provider to check if user is still a collaborator on the active trip
/// Used to detect when user has been removed and should deactivate the trip
final isStillCollaboratorProvider = FutureProvider.family<bool, String>((ref, tripId) async {
  // Watch refresh counter
  ref.watch(_collaboratorRefreshCounterProvider);

  final repository = ref.watch(tripCollaboratorRepositoryProvider);

  // Check if owner (owner is always a "collaborator" in a sense)
  final isOwner = await repository.isOwner(tripId);
  if (isOwner) return true;

  // Check if has any permission (read or write)
  final permission = await repository.getUserPermission(tripId);
  return permission != null;
});
