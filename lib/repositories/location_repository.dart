import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
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

    // Migration: Clear old data that doesn't have tripId/scheduledDate fields
    // This ensures fresh data is loaded from the database
    if (_box!.isNotEmpty) {
      final needsMigration = _box!.values.any((loc) => loc.tripId == null && loc.source == 'synced');
      
      if (needsMigration) {
        debugPrint('Clearing Hive cache due to schema update (added tripId/scheduledDate fields)');
        await _box!.clear();
        
        // If authenticated, immediately fetch fresh remote data
        final user = _supabase.auth.currentUser;
        if (user != null) {
          await fetchRemoteLocations();
        }
      }
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

    // Create a JSON map from the existing location and apply updates
    final locationJson = localLocation.toJson();
    locationJson.addAll(updates);

    // Create an updated SavedLocation object
    final updatedLocation = SavedLocation.fromJson(locationJson).copyWith(isSynced: false);

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
      print("Add location should arrive here");
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

    // Step 1: Fetch all remote locations
    List<SavedLocation> remoteLocations = [];
    try {
      final response =
          await _supabase.from('locations').select().eq('user_id', user.id);

      remoteLocations = (response as List)
          .map((data) => SavedLocation.fromJson(data))
          .toList();
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
        // CONFLICT: Fingerprint exists. Merge local-only changes into the remote version.
        // Rule: We assume the user wants to keep the stay duration, skip status, and date
        // they set while offline.
        final remoteVersion = remoteMap[localLoc.fingerprint]!;
        final mergedLocation = remoteVersion.copyWith(
          isSkipped: localLoc.isSkipped,
          stayDuration: localLoc.stayDuration,
          scheduledDate: localLoc.scheduledDate,
          isSynced: false, // Mark for sync
        );
        // Replace the old remote version with the merged one locally
        await _box!.put(remoteVersion.id, mergedLocation);
        // Delete the old anonymous record
        await _box!.delete(localLoc.id);
        await syncLocation(mergedLocation); // Sync the merged result
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
        .where((loc) => !loc.isSynced && loc.source == 'synced')
        .toList();

    if (unsynced.isEmpty) return;
    debugPrint('Syncing ${unsynced.length} pending locations...');

    for (final loc in unsynced) {
      await syncLocation(loc);
    }
  }

  /// Fetches remote locations and updates local cache.
  /// Typically called on app start or refresh.
  Future<void> fetchRemoteLocations() async {
    await _ensureInitialized();
    final user = _supabase.auth.currentUser;
    if (user == null) return; // Anonymous user only sees local

    try {
      final response = await _supabase
          .from('locations')
          .select()
          .eq('user_id', user.id)
          .order('created_at', ascending: false);

      final List<dynamic> data = response;
      for (final item in data) {
        final remoteLoc = SavedLocation.fromJson(item);
        // Upsert to local Hive, overwriting any existing
        await _box!.put(remoteLoc.id, remoteLoc);
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
  Stream<List<SavedLocation>> _createWatchStream() async* {
    try {
      await _ensureInitialized();
      debugPrint('watchLocations: Box initialized, has ${_box!.length} items');
      
      // Emit current contents first
      final initialData = _box!.values.toList();
      debugPrint('watchLocations: Emitting initial data with ${initialData.length} items');
      yield initialData;
      
      // Then watch for future changes
      yield* _box!.watch().map((event) {
        final data = _box!.values.toList();
        debugPrint('watchLocations: Box changed, now has ${data.length} items');
        return data;
      });
    } catch (e) {
      debugPrint('watchLocations error: $e');
      yield const <SavedLocation>[];
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

  // Realtime subscription
  void subscribeToRealtimeChanges() {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    _subscription = _supabase
        .channel('public:locations')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'locations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: user.id,
          ),
          callback: (payload) {
            // Ensure box is ready before handling changes
            if (_box == null || !_box!.isOpen) {
              if (Hive.isBoxOpen(_boxName)) {
                _box = Hive.box<SavedLocation>(_boxName);
              } else {
                return; // Cannot handle update if box is closed
              }
            }

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
          },
        )
        .subscribe();
  }

  void unsubscribe() {
    if (_subscription != null) {
      _supabase.removeChannel(_subscription!);
      _subscription = null;
    }
  }
}
