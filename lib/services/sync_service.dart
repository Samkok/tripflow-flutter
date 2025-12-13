import 'dart:developer';
import '../models/saved_location.dart';
import '../services/fingerprint_service.dart';

class SyncService {
  /// Check if a location fingerprint exists in remote locations
  static bool fingerPrintExists(
    String localName,
    double localLat,
    double localLng,
    List<SavedLocation> remoteLocations,
  ) {
    final localFp = FingerprintService.generateFingerprint(
      localName,
      localLat,
      localLng,
    );

    return remoteLocations.any((remote) =>
        remote.fingerprint == localFp &&
        remote.fingerprint.isNotEmpty);
  }

  /// Get unique locations from local that don't exist in remote
  static List<SavedLocation> getUniqueLocalLocations(
    List<SavedLocation> localLocations,
    List<SavedLocation> remoteLocations,
  ) {
    return localLocations.where((local) {
      // Generate fingerprint for local location
      final localFp = FingerprintService.generateFingerprint(
        local.name,
        local.lat,
        local.lng,
      );

      // Check if this fingerprint exists in remote
      final exists = remoteLocations.any((remote) =>
          remote.fingerprint == localFp &&
          remote.fingerprint.isNotEmpty);

      return !exists;
    }).toList();
  }

  /// Sync local locations to remote, handling conflicts with fingerprints
  static Future<SyncResult> syncLocationsToRemote({
    required List<SavedLocation> localLocations,
    required List<SavedLocation> remoteLocations,
    required Function(SavedLocation) uploadLocation,
    required Function(String)? onError,
  }) async {
    final syncResult = SyncResult();
    final uniqueLocations = getUniqueLocalLocations(localLocations, remoteLocations);

    log('Starting sync: ${uniqueLocations.length} unique locations to upload');

    for (final location in uniqueLocations) {
      try {
        // Upload the location
        await uploadLocation(location);
        syncResult.uploadedCount++;
      } catch (e) {
        log('Error uploading location ${location.id}: $e');
        onError?.call('Failed to upload ${location.name}: $e');
        syncResult.errors.add('${location.name}: ${e.toString()}');
      }
    }

    syncResult.skippedCount = localLocations.length - uniqueLocations.length;
    return syncResult;
  }
}

class SyncResult {
  int uploadedCount = 0;
  int skippedCount = 0;
  List<String> errors = [];

  bool get isSuccess => errors.isEmpty;
  
  @override
  String toString() =>
      'Uploaded: $uploadedCount, Skipped: $skippedCount, Errors: ${errors.length}';
}
