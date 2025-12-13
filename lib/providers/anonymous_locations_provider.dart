import 'dart:developer';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/saved_location.dart';
import '../services/anonymous_user_service.dart';
import '../services/storage_service.dart';
import '../repositories/location_repository.dart';
import 'location_provider.dart';

/// Provider for anonymous user ID
final anonymousUserIdProvider = FutureProvider<String>((ref) async {
  return await AnonymousUserService.id;
});

/// Provider for loading anonymous (local) locations
final anonymousLocationsProvider = FutureProvider<List<SavedLocation>>((ref) async {
  try {
    final userId = await ref.read(anonymousUserIdProvider.future);
    // Load local locations from storage
    final locations = await StorageService.getHiveLocations(userId);
    return locations.where((loc) => loc.source == 'local').toList();
  } catch (e) {
    log('Error loading anonymous locations: $e');
    return [];
  }
});

/// Provider for synced (but offline) locations from authenticated users
final unSyncedLocationsProvider = FutureProvider<List<SavedLocation>>((ref) async {
  try {
    final userId = ref.read(authStateProvider).maybeWhen(
      data: (state) => state?.session?.user.id,
      orElse: () => null,
    );
    
    if (userId == null) return [];
    
    // Load local unsynced locations
    final locations = await StorageService.getHiveLocations(userId);
    return locations.where((loc) => !loc.isSynced && loc.source == 'synced').toList();
  } catch (e) {
    log('Error loading unsynced locations: $e');
    return [];
  }
});

/// Sync anonymous locations when user logs in
final syncAnonymousLocationsProvider = FutureProvider.family<SyncResult?, String>(
  (ref, userId) async {
    try {
      // Get anonymous locations
      final anonLocations = await ref.read(anonymousLocationsProvider.future);
      
      if (anonLocations.isEmpty) {
        return null; // No anonymous locations to sync
      }

      // Get remote locations
      final repository = ref.read(locationRepositoryProvider);
      final remoteLocations = await repository.getLocationsByUserId(userId);

      // Determine unique locations and sync
      final result = await repository.syncLocalLocations(
        localLocations: anonLocations,
        remoteLocations: remoteLocations,
      );

      if (result.isSuccess) {
        // Clear synced anonymous locations
        final box = await StorageService.getHiveBox();
        for (final loc in anonLocations) {
          await box.delete(loc.key);
        }
      }

      return result;
    } catch (e) {
      log('Error syncing anonymous locations: $e');
      rethrow;
    }
  },
);

// Helper provider (requires auth_provider to be present)
final authStateProvider = FutureProvider<dynamic>((ref) async {
  // This should reference your actual auth provider
  // For now returning null as placeholder
  return null;
});
