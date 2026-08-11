import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../repositories/location_repository.dart';
import '../repositories/trip_repository.dart';
import '../services/supabase_service.dart';
import '../models/saved_location.dart';
import '../services/auth_service.dart';
import 'auth_provider.dart';
import 'trip_listener_provider.dart';

final locationRepositoryProvider = Provider<LocationRepository>((ref) {
  return LocationRepository();
});

final savedLocationsProvider = StreamProvider<List<SavedLocation>>((ref) {
  final repository = ref.watch(locationRepositoryProvider);
  return repository.watchLocations();
});

/// Per-trip stats for the home cards ("N places" + date-span fallback),
/// computed ONCE per locations emission. Cards `select()` their own trip's
/// record — records compare structurally, so only the card whose numbers
/// actually changed rebuilds, instead of every card on every emission.
typedef TripCardStats = ({int count, DateTime? start, DateTime? end});

final tripCardStatsProvider = Provider<Map<String, TripCardStats>>((ref) {
  final locations = ref.watch(savedLocationsProvider).valueOrNull ?? const [];
  final counts = <String, int>{};
  final starts = <String, DateTime>{};
  final ends = <String, DateTime>{};
  for (final location in locations) {
    final tripId = location.tripId;
    if (tripId == null) continue;
    counts[tripId] = (counts[tripId] ?? 0) + 1;
    final d = location.scheduledDate ?? location.createdAt;
    final start = starts[tripId];
    if (start == null || d.isBefore(start)) starts[tripId] = d;
    final end = ends[tripId];
    if (end == null || d.isAfter(end)) ends[tripId] = d;
  }
  return {
    for (final id in counts.keys)
      id: (count: counts[id]!, start: starts[id], end: ends[id]),
  };
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
  // Watch ONLY the resolved trip id — never the AsyncValue itself. Every
  // reload of realtimeActiveTripProvider (manual refresh, add/remove-day,
  // any userTripsProvider invalidation) ticks loading→data with the SAME
  // trip retained; watching the AsyncValue restarted this whole stream per
  // tick — fresh initial Hive emission → pinnedLocations churn → marker and
  // list rebuilds, the "map reloads three times" refresh flash. The id only
  // changes on a real activate / switch / deactivate, which is exactly when
  // a restart is wanted.
  final activeTripId =
      ref.watch(realtimeActiveTripProvider.select((a) => a.valueOrNull?.id));

  // Watch stable user-ID provider instead of authStateProvider.
  // currentUserIdProvider is a Provider<String?> whose value is stable across
  // token refreshes — same user ID → no rebuild → no stream restart → no blink.
  final currentUserId = ref.watch(currentUserIdProvider);

  // Get the actual stream from the repository
  final repository = ref.watch(locationRepositoryProvider);

  // First, get all locations from the stream
  final locationsStream = repository.watchLocations();

  debugPrint(
      'filteredLocationsForMapProvider: Starting to listen for location changes');

  await for (final locations in locationsStream) {
    // Authenticated when user ID is non-null
    final isAuthenticated = currentUserId != null;

    if (activeTripId != null) {
      // Trip is active: filter to only locations in this trip
      final filtered =
          locations.where((loc) => loc.tripId == activeTripId).toList();
      debugPrint(
          'filteredLocationsForMapProvider: ✅ Trip $activeTripId active → emitting ${filtered.length}/${locations.length} locations');
      yield filtered;
    } else if (!isAuthenticated) {
      // Anonymous user with no active trip: show all local locations
      final localLocations =
          locations.where((loc) => loc.source == 'local').toList();
      debugPrint(
          'filteredLocationsForMapProvider: Anonymous mode → emitting ${localLocations.length} local locations');
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
      debugPrint(
          'filteredLocationsForMapProvider: No trip active (authenticated) → emitting ${unassignedLocations.length} unassigned locations');
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
  final authState = ref.watch(authStateProvider);
  final repository = ref.watch(locationRepositoryProvider);

  final user = authState.asData?.value.session?.user;

  if (user != null) {
    // Idempotent — no-op while the channel is healthy for this user.
    repository.subscribeToRealtimeChanges();
  } else if (authState.hasValue) {
    // A real auth emission with no session (signed out) — tear down.
    // While authState is still loading on cold start we do nothing.
    repository.unsubscribe();
  }
  // Deliberately NOT watching connectivity here. realtime_client reconnects
  // the socket and rejoins channels on its own after a network drop; the old
  // connectivity-driven unsubscribe/resubscribe raced those rejoins (the
  // reachability checker flaps on mobile links) and could kill a join
  // mid-flight, permanently wedging the channel on the old implementation.
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
      // Retry any guest trips that failed to upload during the sign-in sync
      // — must precede syncOnLogin (locations.trip_id FK onto trips).
      final userId = SupabaseService.instance.client.auth.currentUser?.id;
      if (userId != null) {
        await TripRepository().syncLocalTripsToAccount(userId);
      }
      await repository.syncOnLogin();
    }
  } catch (e) {
    debugPrint(
        'performInitialLocationSync: background sync failed (non-fatal): $e');
  }
}
