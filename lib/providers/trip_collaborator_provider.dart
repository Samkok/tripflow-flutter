import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/trip_collaborator.dart';
import '../repositories/trip_collaborator_repository.dart';
import '../services/collaborator_realtime_service.dart';
import '../services/supabase_service.dart';
import 'trip_listener_provider.dart';
import 'local_active_trip_provider.dart';
import 'auth_provider.dart';

/// Provider for the TripCollaboratorRepository
final tripCollaboratorRepositoryProvider =
    Provider<TripCollaboratorRepository>((ref) {
  return TripCollaboratorRepository();
});

/// Provider for the CollaboratorRealtimeService singleton
final collaboratorRealtimeServiceProvider =
    Provider<CollaboratorRealtimeService>((ref) {
  return CollaboratorRealtimeService();
});

/// Simple counter that increments when collaborator events occur
/// This is used to trigger refreshes without causing cascading rebuilds
final _collaboratorRefreshCounterProvider = StateProvider<int>((ref) => 0);

/// Notifier that manages collaborator realtime subscriptions
class CollaboratorRealtimeNotifier extends StateNotifier<int> {
  final Ref _ref;
  StreamSubscription<CollaboratorEvent>? _subscription;

  bool _isInitialized = false;

  CollaboratorRealtimeNotifier(this._ref) : super(0) {
    // PERFORMANCE: Do NOT call _initialize() here
    // Deferred to ensureInitialized() for lazy loading
  }

  /// PERFORMANCE: Lazy initialization - defer Supabase subscription until needed
  void ensureInitialized() {
    if (_isInitialized) return;
    _isInitialized = true;
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

    // The subscription is UNFILTERED (so owners hear about other members'
    // rows too — that's how a leave shows up live). Events about MY own row
    // trigger the me-specific reactions below; events about other members
    // only need the refresh-counter bump the stream listener already did,
    // which refetches any watched collaborator list.
    final myUserId = SupabaseService.instance.client.auth.currentUser?.id;
    final isOwnRow = event.userId != null && event.userId == myUserId;

    if (event.type == CollaboratorEventType.removed) {
      // DELETE payloads on RLS tables are PK-only (see CollaboratorEvent
      // .tripId) — we usually can't tell WHOSE row vanished or from which
      // trip. The counter bump above already refetches every watched
      // collaborator list (that's how the owner's sheet updates live);
      // here we re-verify the things that depend on MY OWN membership.
      if (event.tripId == null || event.userId == null) {
        _ref.invalidate(sharedTripsProvider);
        unawaited(_recheckActiveTripMembership());
      } else if (isOwnRow) {
        // Full payload (possible only when RLS is off / future server
        // changes): my removal, handled directly.
        final activeTrip = _ref.read(realtimeActiveTripProvider).valueOrNull;
        if (activeTrip != null && event.tripId == activeTrip.id) {
          debugPrint(
              'CollaboratorRealtimeNotifier: ⚠️ Removed from active trip ${activeTrip.name}, deactivating...');
          _ref.read(localActiveTripIdProvider.notifier).deactivateTrip();
        }
        _ref.invalidate(sharedTripsProvider);
      }
      // Full payload about someone ELSE: nothing beyond the counter bump —
      // and NEVER deactivate the trip over another member leaving.
    } else if (event.type == CollaboratorEventType.updated) {
      // Permission changed - this is the MOST COMMON case
      debugPrint(
          'CollaboratorRealtimeNotifier: 🔄 Permission updated for trip ${event.tripId}');
      debugPrint(
          'CollaboratorRealtimeNotifier: New permission: ${event.permission}');

      // CRITICAL: Only invalidate the specific trip's permission providers
      // This ensures fresh data is fetched WITHOUT disrupting other trips or UI
      final updatedTripId = event.tripId;
      if (updatedTripId != null) {
        _ref.invalidate(hasWriteAccessProvider(updatedTripId));
        _ref.invalidate(userTripPermissionProvider(updatedTripId));
      }

      // Increment counter to signal permission change
      // Riverpod's caching will ensure widgets only rebuild if the actual VALUE changes
      _ref.read(_collaboratorRefreshCounterProvider.notifier).state++;

      debugPrint(
          'CollaboratorRealtimeNotifier: ✅ Permission providers invalidated, UI will update smoothly');
    } else if (event.type == CollaboratorEventType.added) {
      if (isOwnRow) {
        // New trip shared with ME — refresh my shared-trips list.
        debugPrint(
            'CollaboratorRealtimeNotifier: ➕ New trip shared: ${event.tripId}');
        _ref.invalidate(sharedTripsProvider);
      }
      // Someone joining a trip I own/view: the counter bump already
      // refetches the collaborator list.
    }
  }

  /// A collaborator row was deleted somewhere and the PK-only payload can't
  /// say whose. If a SHARED trip is currently active, re-query my own
  /// membership — if my row is the one that vanished, deactivate the trip
  /// (the same behavior the old direct check intended, now grounded in a
  /// fresh RLS-gated query instead of an event payload that never arrives).
  Future<void> _recheckActiveTripMembership() async {
    try {
      // Guests can't lose membership of their own local trips — and the raw
      // isOwner() below would return false with no session, wrongly
      // deactivating the trip if an event ever slipped through.
      if (_ref.read(currentUserIdProvider) == null) return;

      final activeTrip = _ref.read(realtimeActiveTripProvider).valueOrNull;
      if (activeTrip == null) return;

      final repository = _ref.read(tripCollaboratorRepositoryProvider);
      if (await repository.isOwner(activeTrip.id)) return; // owners stay

      final permission = await repository.getUserPermission(activeTrip.id);
      if (permission == null) {
        debugPrint(
            'CollaboratorRealtimeNotifier: ⚠️ No longer a member of active '
            'trip ${activeTrip.name}, deactivating...');
        _ref.read(localActiveTripIdProvider.notifier).deactivateTrip();
      }
    } catch (e) {
      debugPrint(
          'CollaboratorRealtimeNotifier: membership re-check failed: $e');
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
final collaboratorRealtimeInitProvider =
    StateNotifierProvider<CollaboratorRealtimeNotifier, int>((ref) {
  return CollaboratorRealtimeNotifier(ref);
});

/// Provider for getting collaborators of a specific trip.
///
/// autoDispose: the cache dies with its last watcher (the collaborators
/// sheet / trip row), so REOPENING the sheet always refetches — a missed
/// realtime event (socket down, app backgrounded) can no longer pin a
/// stale list for the rest of the app session.
final tripCollaboratorsProvider = FutureProvider.autoDispose
    .family<List<TripCollaborator>, String>((ref, tripId) async {
  // Watch auth state — re-fetches on login/logout so the list is never stuck
  // showing a stale cached result from an unauthenticated context.
  final authState = ref.watch(authStateProvider);

  // Guests: local trips have no collaborators, and the query below would
  // just error against RLS with no session.
  if (ref.watch(currentUserIdProvider) == null) return [];

  // Watch refresh counter to trigger rebuild on realtime collaborator changes
  ref.watch(_collaboratorRefreshCounterProvider);

  // Guard: don't query while unauthenticated (RLS would return nothing anyway)
  if (authState.asData?.value.session == null) return [];

  final repository = ref.watch(tripCollaboratorRepositoryProvider);
  return repository.getCollaborators(tripId);
});

/// Provider for shared trips (trips where current user is a collaborator)
final sharedTripsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
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

/// Pending invites this user has sent for a trip (email not signed up yet).
/// Shown in the collaborators sheet as "waiting to join" rows.
final pendingInvitesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, tripId) async {
  if (ref.watch(currentUserIdProvider) == null) return [];
  ref.watch(_collaboratorRefreshCounterProvider);
  final repository = ref.watch(tripCollaboratorRepositoryProvider);
  return repository.getPendingInvites(tripId);
});

/// Provider to check if user is the owner of a trip
final isTripOwnerProvider =
    FutureProvider.family<bool, String>((ref, tripId) async {
  // Guests own everything on their device: local trips have no
  // collaborator rows, and the Supabase isOwner lookup would return false
  // and lock them out of their own trip's CRUD.
  if (ref.watch(currentUserIdProvider) == null) return true;
  final repository = ref.watch(tripCollaboratorRepositoryProvider);
  return repository.isOwner(tripId);
});

/// Provider to get user's permission on a trip
final userTripPermissionProvider =
    FutureProvider.family<String?, String>((ref, tripId) async {
  // Watch refresh counter to trigger rebuild on permission changes
  ref.watch(_collaboratorRefreshCounterProvider);

  final repository = ref.watch(tripCollaboratorRepositoryProvider);
  return repository.getUserPermission(tripId);
});

/// Provider to check if user has write access to a trip
final hasWriteAccessProvider =
    FutureProvider.family<bool, String>((ref, tripId) async {
  // Watch refresh counter to trigger rebuild on permission changes
  ref.watch(_collaboratorRefreshCounterProvider);

  // Guests: same reasoning as isTripOwnerProvider — local trips are theirs.
  if (ref.watch(currentUserIdProvider) == null) return true;

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

  // RETAIN through reloads: `when(loading:)` resolved to false on every
  // realtimeActiveTripProvider reload (which every add/remove-day
  // invalidation triggers), momentarily hiding write-gated controls — the
  // half-reload flicker on the very button just pressed. Only a true first
  // load (no previous value) denies access defensively.
  if (activeTripAsync.hasError) return false;
  if (activeTripAsync.isLoading && !activeTripAsync.hasValue) return false;
  final activeTrip = activeTripAsync.valueOrNull;
  if (activeTrip == null) {
    // No active trip - user can edit their own non-trip locations
    return true;
  }

  // Fetch the LATEST write access for the active trip
  // This ensures we always have fresh permission data from Supabase
  return await ref.watch(hasWriteAccessProvider(activeTrip.id).future);
});

/// Provider to check if user is still a collaborator on the active trip
/// Used to detect when user has been removed and should deactivate the trip
final isStillCollaboratorProvider =
    FutureProvider.family<bool, String>((ref, tripId) async {
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
