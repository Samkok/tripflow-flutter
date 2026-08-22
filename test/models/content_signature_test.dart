import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/saved_location.dart';

void main() {
  // The exact situation after the device pushes a row: the local copy holds
  // a LOCAL-time createdAt and a fresh lastSyncedAt; the server echoes the
  // row back with created_at in UTC, an older last_synced_at, is_synced
  // false (the column is a device-local flag). The user sees no difference
  // — the app must not treat the echo as a change.
  final localCreated = DateTime(2026, 3, 10, 20, 30); // local time
  final local = SavedLocation(
    id: 'row-1',
    userId: 'u',
    name: 'Cafe',
    lat: 25.0,
    lng: 121.5,
    createdAt: localCreated,
    fingerprint: 'fp',
    scheduledDate: DateTime(2026, 9, 1),
    isSynced: true,
    lastSyncedAt: DateTime(2026, 8, 20, 10, 0),
    source: 'synced',
    stayDuration: 3600,
  );

  // What fromJson produces from the server payload.
  final echo = SavedLocation.fromJson({
    'id': 'row-1',
    'user_id': 'u',
    'name': 'Cafe',
    'lat': 25.0,
    'lng': 121.5,
    'created_at': localCreated.toUtc().toIso8601String(), // UTC on the wire
    'last_synced_at': '2026-08-01T00:00:00+00:00', // older
    'is_synced': false, // device-local flag shipped along
    'source': 'synced',
    'fingerprint': 'fp',
    'is_skipped': false,
    'is_done': false,
    'stay_duration': 3600,
    'scheduled_date': '2026-09-01T00:00:00.000',
    'is_accommodation': false,
  });

  test('toJson equality fails for an own-write echo (the old comparison)', () {
    expect(local.toJson().toString() == echo.toJson().toString(), isFalse,
        reason: 'created_at UTC vs local and last_synced_at differ');
  });

  test('contentSignature treats the echo as identical', () {
    expect(local.contentSignature(), echo.contentSignature());
  });

  test('contentSignature still detects a real change', () {
    final moved = echo.copyWith(scheduledDate: DateTime(2026, 9, 2));
    expect(local.contentSignature() == moved.contentSignature(), isFalse);
    final renamed = echo.copyWith(name: 'Cafe Nero');
    expect(local.contentSignature() == renamed.contentSignature(), isFalse);
    final unscheduled = echo.copyWith(scheduledDate: null);
    expect(local.contentSignature() == unscheduled.contentSignature(), isFalse);
  });

  test('sync-metadata-only changes are invisible', () {
    final resynced = local.copyWith(
        isSynced: false, lastSyncedAt: DateTime(2030, 1, 1));
    expect(local.contentSignature(), resynced.contentSignature());
  });
}
