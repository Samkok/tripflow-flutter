import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:voyza/main.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/saved_location.dart';
import '../services/supabase_service.dart';
import '../services/anonymous_user_service.dart';
import '../utils/fingerprint_utils.dart';

class SyncResult {
  int uploadedCount = 0;
  int skippedCount = 0;
  List<String> errors = [];

  bool get isSuccess => errors.isEmpty;

  @override
  String toString() =>
      'Uploaded: $uploadedCount, Skipped: $skippedCount, Errors: ${errors.length}';
}

class LocationRepository {
  static const String _boxName = 'locations';
  static const String _migrationKey = 'location_schema_v2_migrated';
  static const String _needsDataSyncKey = 'location_needs_data_sync';
  Box<SavedLocation>? _box; // Changed from late to nullable
  final SupabaseClient _supabase = SupabaseService.instance.client;
  RealtimeChannel? _subscription;

  Future<void> init() async {
    await _ensureInitialized();
  }

  Future<void> _ensureInitialized() async {
    if (_box != null && _box!.isOpen) return;

    try {
      if (!Hive.isBoxOpen(_boxName)) {
        _box = await Hive.openBox<SavedLocation>(_boxName);
      } else {
        _box = Hive.box<SavedLocation>(_boxName);
      }
    } catch (e) {
      // If there's a HiveError (corrupted data or unknown typeId), delete and recreate
      if (e.toString().contains('HiveError') || e.toString().contains('unknown typeId')) {
        debugPrint('Corrupted Hive cache detected: $e. Clearing and recreating...');
        
        // Close the box if it's open
        if (Hive.isBoxOpen(_boxName)) {
          await Hive.box(_boxName).clear();
          await Hive.box(_boxName).close();
        }
        
        // Delete the corrupted box
        try {
          await Hive.deleteBoxFromDisk(_boxName);
        } catch (deleteError) {
          debugPrint('Could not delete corrupted box from disk: $deleteError');
        }
        
        // Recreate the box
        _box = await Hive.openBox<SavedLocation>(_boxName);
        debugPrint('Hive cache cleared and recreated successfully');
      } else {
        rethrow;
      }
    }

    // PERFORMANCE: Non-blocking migration with lazy data sync
    // Check if migration has already been done to avoid repeated checks
    final prefs = SharedPrefsCache.instance;
    final migrationDone = prefs.getBool(_migrationKey) ?? false;

    if (!migrationDone && _box!.isNotEmpty) {
      final needsMigration = _box!.values.any((loc) => loc.tripId == null && loc.source == 'synced');

      if (needsMigration) {
        debugPrint('Clearing Hive cache due to schema update (added tripId/scheduledDate fields)');
        await _box!.clear();

        // Set flag to sync data later instead of blocking startup
        final user = _supabase.auth.currentUser;
        if (user != null) {
          await prefs.setBool(_needsDataSyncKey, true);
          debugPrint('Migration complete. Data will sync in background.');
        }
      }

      // Mark migration as done
      await prefs.setBool(_migrationKey, true);
    }
  }

  /// Adds a location. Handles anonymous vs authenticated logic.
  Future<void> addLocation(SavedLocation location) async {
    await _ensureInitialized();
    final user = _supabase.auth.currentUser;

    String userId;
    String source;

    if (user != null) {
      userId = user.id;
      source = 'synced';
    } else {
      userId = await AnonymousUserService.id;
      source = 'local';
    }

    // Generate fingerprint if empty (though model requires it, let's ensure consistency)
    final fingerprint = location.fingerprint.isNotEmpty
        ? location.fingerprint
        : FingerprintUtils.generateFingerprint(
            name: location.name, lat: location.lat, lng: location.lng);

    final newLocation = location.copyWith(
      userId: userId,
      source: source,
      fingerprint: fingerprint,
      isSynced: false,
    );

    // Save locally first
    await _box!.put(newLocation.id, newLocation);

    // If authenticated, try to sync immediately
    if (user != null) {
      await syncLocation(newLocation);
    }
  }

  Future<void> deleteLocation(String id) async {
    await _ensureInitialized();
    final location = _box!.get(id);
    await _box!.delete(id);

    // Also delete from remote if authenticated and location was synced
    final user = _supabase.auth.currentUser;
    if (user != null && location != null) {
      try {
        await _supabase.from('locations').delete().eq('id', id);
      } catch (e) {
        debugPrint('Error deleting remote location: $e');
      }
    }
  }

  /// Updates specific fields of a location in both local and remote storage.
  Future<void> updateLocation(String id, Map<String, dynamic> updates) async {
    await _ensureInitialized();
    final localLocation = _box!.get(id);
    if (localLocation == null) return;

    // BUGFIX: Use copyWith to safely update the location instead of JSON round-trip
    // This avoids potential issues with fromJson() not handling all fields
    var updatedLocation = localLocation;
    
    // Apply updates using copyWith for type-safe updates
    if (updates.containsKey('trip_id')) {
      updatedLocation = updatedLocation.copyWith(tripId: updates['trip_id'] as String?);
    }
    if (updates.containsKey('is_skipped')) {
      updatedLocation = updatedLocation.copyWith(isSkipped: updates['is_skipped'] as bool);
    }
    if (updates.containsKey('is_done')) {
      updatedLocation = updatedLocation.copyWith(isDone: updates['is_done'] as bool);
    }
    if (updates.containsKey('scheduled_date')) {
      final dateStr = updates['scheduled_date'];
      final parsedDate = dateStr is String ? DateTime.parse(dateStr) : dateStr as DateTime?;
      updatedLocation = updatedLocation.copyWith(scheduledDate: parsedDate);
    }
    if (updates.containsKey('stay_duration')) {
      updatedLocation = updatedLocation.copyWith(stayDuration: updates['stay_duration'] as int);
    }
    if (updates.containsKey('name')) {
      updatedLocation = updatedLocation.copyWith(name: updates['name'] as String);
    }
    
    // Mark as not synced since we made local changes
    updatedLocation = updatedLocation.copyWith(isSynced: false);

    // Save updated location locally
    await _box!.put(id, updatedLocation);

    // Sync update to remote if authenticated
    final user = _supabase.auth.currentUser;
    if (user != null) {
      await syncLocation(updatedLocation);
    }
  }

  /// Pushes a single location to Supabase.
  Future<void> syncLocation(SavedLocation location) async {
    // Assuming calling method ensures initialization, but safer to check if box is needed
    // However, this is usually called from addLocation/syncOnLogin which await init.
    // We only access _box at the end.

    final user = _supabase.auth.currentUser;
    if (user == null) return;

    // Ensure the location object has the correct user_id before syncing.
    final locationToSync = location.copyWith(userId: user.id);

    try {
      debugPrint("Add location should arrive here");
      await _supabase.from('locations').upsert(locationToSync.toJson());

      // Update local state to synced
      final syncedLoc = locationToSync.copyWith(
          isSynced: true, lastSyncedAt: DateTime.now(), source: 'synced');

      // We need to ensure box is ready before writing
      if (_box == null || !_box!.isOpen) await _ensureInitialized();
      await _box!.put(syncedLoc.id, syncedLoc);
    } catch (e) {
      debugPrint('Sync failed for ${location.name}: $e');
    }
  }

  /// The main sync process to be called after login.
  /// Merges anonymous local data with remote user data.
  Future<void> syncOnLogin() async {
    await _ensureInitialized();
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    // Step 1: Fetch all remote locations (including from collaborative trips)
    // RLS policies handle access control automatically
    List<SavedLocation> remoteLocations = [];
    try {
      // Don't filter by user_id - let RLS handle it
      final response = await _supabase.from('locations').select();

      remoteLocations = (response as List)
          .map((data) => SavedLocation.fromJson(data))
          .toList();

      debugPrint('syncOnLogin: Fetched ${remoteLocations.length} locations (including collaborative trips)');
    } catch (e) {
      debugPrint('Error syncing fetch remote: $e');
      return; // Stop if we can't get remote state
    }

    // Map remote locations by fingerprint for O(1) lookup
    final remoteMap = {for (var loc in remoteLocations) loc.fingerprint: loc};

    // Step 2: Load all anonymous local locations
    final localAnonymous =
        _box!.values.where((loc) => loc.source == 'local').toList();

    // Step 3: Search for conflicts and upload missing
    for (final localLoc in localAnonymous) {
      if (remoteMap.containsKey(localLoc.fingerprint)) {
        // CONFLICT: Fingerprint exists in remote DB.
        final remoteVersion = remoteMap[localLoc.fingerprint]!;

        if (remoteVersion.userId == user.id) {
          // The remote location belongs to us — merge local-only changes and sync.
          final mergedLocation = remoteVersion.copyWith(
            isSkipped: localLoc.isSkipped,
            stayDuration: localLoc.stayDuration,
            scheduledDate: localLoc.scheduledDate,
            isSynced: false,
          );
          await _box!.put(remoteVersion.id, mergedLocation);
          await _box!.delete(localLoc.id);
          await syncLocation(mergedLocation);
        } else {
          // The remote location belongs to another user (e.g. a collaborative trip).
          // We cannot write to their row — just adopt the remote version locally
          // and discard the anonymous local copy.
          if (_box!.get(remoteVersion.id) == null) {
            await _box!.put(remoteVersion.id, remoteVersion);
          }
          await _box!.delete(localLoc.id);
        }
      } else {
        // Rule: If local fingerprint does not exist in remote DB, upload it.
        // We must update the fields to match the authenticated user.
        final toUpload = localLoc.copyWith(
            userId: user.id,
            source: 'synced',
            isSynced: false // Set false initially until upload succeeds
            );

        // This effectively replaces the anonymous key with the new authenticated one locally
        // (if ID stays same, it overwrites; if ID changes, we delete old)
        // Usually UUIDs are generated locally.

        await _box!.put(toUpload.id, toUpload); // Save updated version

        try {
          await syncLocation(toUpload); // Try to sync
        } catch (e) {
          debugPrint('Failed to sync previously anonymous location: $e');
          // It remains isSynced=false, source=synced to be picked up by background sync later
        }
      }
    }

    // Step 4: Store remote locations locally for offline access (and replace any remaining anonymous)
    for (final remoteLoc in remoteLocations) {
      // Only add if it doesn't exist to avoid overwriting a just-merged location.
      final existing = _box!.get(remoteLoc.id);
      if (existing == null) {
        await _box!.put(remoteLoc.id, remoteLoc);
      }
    }
  }

  /// Syncs any local items marked as 'synced' source but isSynced = false.
  Future<void> syncUnsyncedLocations() async {
    await _ensureInitialized();
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    final unsynced = _box!.values
        .where((loc) =>
            !loc.isSynced && loc.source == 'synced' && loc.userId == user.id)
        .toList();

    if (unsynced.isEmpty) return;
    debugPrint('Syncing ${unsynced.length} pending locations...');

    for (final loc in unsynced) {
      await syncLocation(loc);
    }
  }

  /// Fetches remote locations and updates local cache.
  /// Typically called on app start or refresh.
  /// Fetches ALL locations the user has access to (owned + collaborative trips).
  /// RLS policies handle access control automatically.
  Future<void> fetchRemoteLocations() async {
    await _ensureInitialized();
    final user = _supabase.auth.currentUser;
    if (user == null) return; // Anonymous user only sees local

    try {
      // Don't filter by user_id - let RLS policies handle access control
      // This will return locations the user owns AND locations from trips they collaborate on
      final response = await _supabase
          .from('locations')
          .select()
          .order('created_at', ascending: false);

      final List<dynamic> data = response;
      debugPrint('fetchRemoteLocations: Fetched ${data.length} locations (including collaborative trips)');

      // Batch-write all locations in a single putAll call instead of N individual
      // put() calls. Each individual put fires its own Hive watch event, so N puts
      // would trigger N stream emissions → N marker redraws → N map blinks.
      if (data.isNotEmpty) {
        final Map<String, SavedLocation> batch = {};
        for (final item in data) {
          final remoteLoc = SavedLocation.fromJson(item);
          batch[remoteLoc.id] = remoteLoc;
        }
        await _box!.putAll(batch);
      }
    } catch (e) {
      debugPrint('Error fetching remote locations: $e');
    }
  }

  /// Get locations for a specific user ID
  Future<List<SavedLocation>> getLocationsByUserId(String userId) async {
    await _ensureInitialized();
    try {
      final response = await _supabase
          .from('locations')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      return (response as List)
          .map((data) => SavedLocation.fromJson(data))
          .toList();
    } catch (e) {
      debugPrint('Error getting locations by user ID: $e');
      return [];
    }
  }

  /// Sync local locations to remote with conflict resolution by fingerprint
  Future<SyncResult> syncLocalLocations({
    required List<SavedLocation> localLocations,
    required List<SavedLocation> remoteLocations,
  }) async {
    await _ensureInitialized();
    final result = SyncResult();

    // Build fingerprint map of remote locations
    final remoteByFingerprint = {
      for (var loc in remoteLocations)
        if (loc.fingerprint.isNotEmpty) loc.fingerprint: loc
    };

    for (final localLoc in localLocations) {
      try {
        final localFp = localLoc.fingerprint;
        
        // Skip if fingerprint already exists in remote
        if (remoteByFingerprint.containsKey(localFp)) {
          result.skippedCount++;
          continue;
        }

        // Upload unique location
        await syncLocation(localLoc);
        result.uploadedCount++;
      } catch (e) {
        debugPrint('Error syncing location ${localLoc.name}: $e');
        result.errors.add('${localLoc.name}: ${e.toString()}');
      }
    }

    return result;
  }

  Stream<List<SavedLocation>> watchLocations() {
    return _createWatchStream();
  }

  /// Creates a stream that properly initializes the Hive box before watching.
  /// This returns a stream that first emits current contents, then watches for changes.
  ///
  /// The watch portion is DEBOUNCED (100 ms) so that bulk writes — e.g.
  /// fetchRemoteLocations() writing N locations via putAll, or syncOnLogin()
  /// writing N individual entries — collapse into a single stream emission.
  /// Without debouncing, each individual Hive write fires its own watch event,
  /// causing the marker-bitmap FutureProvider to re-run N times → N map blinks.
  Stream<List<SavedLocation>> _createWatchStream() async* {
    try {
      await _ensureInitialized();
      debugPrint('watchLocations: Box initialized, has ${_box!.length} items');

      // PERFORMANCE: Trigger lazy background sync if migration set the flag
      _syncDataInBackgroundIfNeeded();

      // Emit current contents immediately (no debounce for the initial snapshot)
      final initialData = _box!.values.toList();
      debugPrint('watchLocations: Emitting initial data with ${initialData.length} items');
      yield initialData;

      // Watch for future changes — debounced so rapid consecutive Hive writes
      // (bulk fetch, sync loops, realtime bursts) only trigger ONE emission.
      Timer? debounceTimer;
      final controller = StreamController<void>();

      final sub = _box!.watch().listen(
        (_) {
          debounceTimer?.cancel();
          debounceTimer = Timer(const Duration(milliseconds: 100), () {
            if (!controller.isClosed) controller.add(null);
          });
        },
        onError: controller.addError,
        onDone: controller.close,
      );

      try {
        await for (final _ in controller.stream) {
          final data = _box!.values.toList();
          debugPrint('watchLocations: Box changed (debounced), now has ${data.length} items');
          yield data;
        }
      } finally {
        await sub.cancel();
        debounceTimer?.cancel();
        if (!controller.isClosed) await controller.close();
      }
    } catch (e) {
      debugPrint('watchLocations error: $e');
      yield const <SavedLocation>[];
    }
  }

  /// PERFORMANCE: Non-blocking background data sync triggered after migration
  void _syncDataInBackgroundIfNeeded() {
    Future(() async {
      try {
        final prefs = SharedPrefsCache.instance;
        final needsSync = prefs.getBool(_needsDataSyncKey) ?? false;

        if (needsSync) {
          debugPrint('Starting background data sync after migration...');
          await fetchRemoteLocations();
          await prefs.setBool(_needsDataSyncKey, false);
          debugPrint('Background data sync completed.');
        }
      } catch (e) {
        debugPrint('Error in background data sync: $e');
      }
    });
  }

  /// Deletes all locations belonging to [tripId] that are owned by the current user.
  /// Removes from both Supabase and the local Hive cache.
  /// Called before deleting a trip when the user chooses to discard locations too.
  Future<void> deleteLocationsByTripId(String tripId) async {
    await _ensureInitialized();
    final user = _supabase.auth.currentUser;

    // Delete from Supabase (filter by user_id so RLS is respected and other
    // collaborators' locations are not touched)
    await _supabase
        .from('locations')
        .delete()
        .eq('trip_id', tripId)
        .eq('user_id', user?.id ?? '');

    // Delete matching entries from the local Hive cache immediately so the map
    // updates without waiting for the realtime subscription.
    final keysToDelete = _box!.values
        .where((loc) =>
            loc.tripId == tripId &&
            (user == null || loc.userId == user.id))
        .map((loc) => loc.id)
        .toList();
    if (keysToDelete.isNotEmpty) {
      await _box!.deleteAll(keysToDelete);
    }
  }

  /// Get the count of local (anonymous) locations
  Future<int> getLocalLocationCount() async {
    await _ensureInitialized();
    return _box!.values.where((loc) => loc.source == 'local').length;
  }

  Future<void> cleanUpAnonymousData() async {
    await _ensureInitialized();
    // Remove any remaining locations with source='local' if we are logged in.
    // This is a safety cleanup, though syncOnLogin should handle it.
    if (_supabase.auth.currentUser != null) {
      final anonKeys = _box!.values
          .where((loc) => loc.source == 'local')
          .map((loc) => loc.id)
          .toList();
      await _box!.deleteAll(anonKeys);
    }
  }

  /// Clears all locations from the local Hive cache.
  /// Called on sign-out so the next user who logs in on the same device starts
  /// with an empty box and cannot see the previous user's locations.
  Future<void> clearUserData() async {
    await _ensureInitialized();
    await _box!.clear();
  }

  // Realtime subscription
  // Subscribe to ALL location changes that the user has access to
  // RLS policies on the database handle access control automatically
  void subscribeToRealtimeChanges() {
    final user = _supabase.auth.currentUser;
    if (user == null) return;
    // Guard against duplicate subscriptions. Since syncManagerProvider now uses
    // ref.watch, it can be called multiple times when connectivity/auth changes.
    // Without this guard, every reconnect would create a new leaking channel.
    if (_subscription != null) return;

    // Don't filter by user_id - let RLS policies handle access control
    // This allows receiving updates for locations in collaborative trips
    _subscription = _supabase
        .channel('public:locations')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'locations',
          // No filter - RLS policies will automatically filter what this user can see
          callback: (payload) {
            // Ensure box is ready before handling changes
            if (_box == null || !_box!.isOpen) {
              if (Hive.isBoxOpen(_boxName)) {
                _box = Hive.box<SavedLocation>(_boxName);
              } else {
                return; // Cannot handle update if box is closed
              }
            }

            debugPrint('Realtime location change: ${payload.eventType}');

            try {
              if (payload.eventType == PostgresChangeEvent.insert ||
                  payload.eventType == PostgresChangeEvent.update) {
                final newLoc = SavedLocation.fromJson(payload.newRecord);
                _box!.put(newLoc.id, newLoc);
              } else if (payload.eventType == PostgresChangeEvent.delete) {
                final oldRecord = payload.oldRecord;
                if (oldRecord.containsKey('id')) {
                  _box!.delete(oldRecord['id']);
                }
              }
            } catch (e) {
              debugPrint('Realtime callback error for ${payload.eventType}: $e');
            }
          },
        )
        .subscribe();
  }

  void unsubscribe() {
    if (_subscription != null) {
      _supabase.removeChannel(_subscription!);
      // Reset to null so subscribeToRealtimeChanges() can re-subscribe after reconnect
      _subscription = null;
    }
  }
}
