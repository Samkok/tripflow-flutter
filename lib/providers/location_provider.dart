import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../repositories/location_repository.dart';
import '../models/saved_location.dart';
import '../services/auth_service.dart';
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
/// This provider reacts to BOTH trip changes AND location stream changes.
///
/// Uses currentUserIdProvider (not authStateProvider) so this StreamProvider does
/// NOT restart on every Supabase token refresh.  Each restart would create a new
/// watchLocations() stream that immediately emits the full Hive snapshot, propagating
/// through TripNotifier → cachedMarkerBitmapsProvider → finalMarkersProvider →
/// map blink.  currentUserIdProvider only changes on login / logout.
final filteredLocationsForMapProvider =
    StreamProvider<List<SavedLocation>>((ref) async* {
  // Watch the realtime active trip - will trigger provider rebuild when trip changes
  final activeTripAsync = ref.watch(realtimeActiveTripProvider);

  // Watch stable user-ID provider instead of authStateProvider.
  // currentUserIdProvider is a Provider<String?> whose value is stable across
  // token refreshes — same user ID → no rebuild → no stream restart → no blink.
  final currentUserId = ref.watch(currentUserIdProvider);

  // Get the actual stream from the repository
  final repository = ref.watch(locationRepositoryProvider);

  // First, get all locations from the stream
  final locationsStream = repository.watchLocations();

  debugPrint('filteredLocationsForMapProvider: Starting to listen for location changes');

  await for (final locations in locationsStream) {
    // Get current active trip from the watched async value
    final activeTrip = activeTripAsync.asData?.value;

    // Authenticated when user ID is non-null
    final isAuthenticated = currentUserId != null;

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
      debugPrint('filteredLocationsForMapProvider: Anonymous mode → emitting ${localLocations.length} local locations');
      yield localLocations;
    } else {
      // Authenticated user with no active trip: show only their own unassigned locations.
      // The userId filter prevents stale entries from a previous user (who shared this
      // device) from appearing on the current user's map.
      final unassignedLocations = locations
          .where((loc) =>
              (loc.tripId == null || loc.tripId!.isEmpty) &&
              loc.userId == currentUserId)
          .toList();
      debugPrint('filteredLocationsForMapProvider: No trip active (authenticated) → emitting ${unassignedLocations.length} unassigned locations');
      yield unassignedLocations;
    }
  }
});


/// Manages the Supabase realtime subscription lifecycle.
///
/// Watched (not just read) from main_screen.dart so that connectivity and auth
/// changes properly start/stop the subscription — e.g. re-subscribing after a
/// network drop, or unsubscribing when the user logs out.
///
/// NOTE: This provider intentionally does NOT call _checkAndSync / fetchRemoteLocations.
/// Doing so would re-run the full data fetch on every auth-token refresh or
/// connectivity change, triggering Hive updates → marker bitmap regeneration → map blink.
/// The one-time initial fetch is handled in MainScreen.initState instead.
final syncManagerProvider = Provider<void>((ref) {
  final connectivity = ref.watch(connectivityProvider);
  final authState = ref.watch(authStateProvider);
  final repository = ref.watch(locationRepositoryProvider);

  final user = authState.asData?.value.session?.user;

  if (user != null && connectivity == ConnectivityStatus.isConnected) {
    // subscribeToRealtimeChanges() is idempotent — safe to call on every rebuild.
    repository.subscribeToRealtimeChanges();
  } else {
    // Unsubscribe when offline or logged out.
    // _subscription is set to null in unsubscribe() so re-subscribing on
    // reconnect works correctly.
    repository.unsubscribe();
  }
});

/// Becomes true once performInitialLocationSync() completes.
///
/// The map screen watches this together with cachedMarkerBitmapsProvider to
/// know when it is safe to hide its loading overlay.  Keeping them separate
/// (sync done AND bitmaps computed) prevents the overlay from disappearing
/// while marker-bitmap generation is still in progress.
final initialSyncCompleteProvider = StateProvider<bool>((ref) => false);

/// Performs the initial data sync on login / app start.
///
/// Called once from MainScreen.initState — NOT from syncManagerProvider.
/// Calling it from a watched provider would re-run it on every auth-token
/// refresh or connectivity change, causing repeated Hive updates that
/// trigger marker-bitmap regeneration and map blink.
///
/// The returned future completes as soon as the DISPLAY-CRITICAL step is done —
/// fetching remote locations into the Hive cache so the map can render. Callers
/// gate the loading overlay on this future, so it must stay short.
///
/// The heavier write-side work — re-uploading unsynced rows and merging
/// anonymous data — is kicked off in the BACKGROUND. Its results stream into the
/// map reactively via watchLocations(), so awaiting it here was pure overlay
/// latency (it never needed to gate the first paint). This is what made the map
/// linger on "Loading your locations…" after sign-in.
Future<void> performInitialLocationSync(LocationRepository repository) async {
  // Display-critical: populates the Hive cache the map renders from.
  await repository.fetchRemoteLocations();

  // Fire-and-forget. Runs AFTER the fetch above (sequential, so no racing Hive
  // writes) and surfaces through the location stream once done.
  unawaited(_runBackgroundLocationSync(repository));
}

/// Background continuation of [performInitialLocationSync]: uploads and the
/// optional anonymous-data merge. Deliberately not awaited by the overlay.
Future<void> _runBackgroundLocationSync(LocationRepository repository) async {
  try {
    await repository.syncUnsyncedLocations();

    final syncChoice = await AuthService.getSyncChoice();
    if (syncChoice == true) {
      await repository.syncOnLogin();
    }
  } catch (e) {
    debugPrint('performInitialLocationSync: background sync failed (non-fatal): $e');
  }
}
