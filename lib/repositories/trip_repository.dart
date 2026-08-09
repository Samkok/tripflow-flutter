import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/trip.dart';
import '../services/supabase_service.dart';

class TripRepository {
  final SupabaseClient _supabase = SupabaseService.instance.client;

  static const String _tableName = 'trips';

  // ── Local (guest) trip store ──────────────────────────────────────────
  // Mirrors LocationRepository's anonymous branch: signed-out users get the
  // same CRUD surface, backed by a SharedPreferences JSON list instead of
  // Supabase. Trips are stamped with AnonymousUserService.id as user_id and
  // re-stamped with the real uid by [syncLocalTripsToAccount] on sign-in.
  static const String _localTripsKey = 'local_trips_v1';

  bool get _isAnonymous => _supabase.auth.currentUser == null;

  Future<List<Trip>> _readLocalTrips() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localTripsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Trip.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      debugPrint('TripRepository: corrupt local trips, resetting: $e');
      await prefs.remove(_localTripsKey);
      return [];
    }
  }

  Future<void> _writeLocalTrips(List<Trip> trips) async {
    final prefs = await SharedPreferences.getInstance();
    if (trips.isEmpty) {
      await prefs.remove(_localTripsKey);
    } else {
      await prefs.setString(
          _localTripsKey, jsonEncode(trips.map((t) => t.toJson()).toList()));
    }
  }

  /// How many trips a guest has created on this device. Drives the
  /// "sync your trips?" prompt on sign-in.
  Future<int> getLocalTripCount() async => (await _readLocalTrips()).length;

  /// Replicates local trips into the signed-in account, keeping their local
  /// UUIDs so the Hive locations that reference them (trip_id) stay valid
  /// when LocationRepository.syncOnLogin uploads afterwards. MUST run before
  /// syncOnLogin — locations.trip_id is a foreign key onto these rows.
  ///
  /// is_active is stripped: the account may already have an active trip, and
  /// getActiveTrip's maybeSingle() would throw on two. The device-side
  /// active-trip id (localActiveTripIdProvider) is untouched, so the trip
  /// the guest was using stays selected on this device.
  ///
  /// Returns how many synced. Failed rows stay local for a later retry.
  Future<int> syncLocalTripsToAccount(String newUserId) async {
    final locals = await _readLocalTrips();
    if (locals.isEmpty) return 0;

    final failed = <Trip>[];
    var synced = 0;
    for (final trip in locals) {
      try {
        final json = trip.toJson()
          ..['user_id'] = newUserId
          ..['is_active'] = false
          // Guest trips can never have been published — never upload
          // sharing state (a stale code here could collide or leak).
          ..['is_public'] = false
          ..['share_code'] = null
          // Server-owned counter — an upsert must never reset it.
          ..remove('copy_count')
          ..['status'] = trip.status == 'active' ? 'planning' : trip.status;
        await _supabase.from(_tableName).upsert(json);
        synced++;
      } catch (e) {
        debugPrint('TripRepository: failed to sync trip ${trip.id}: $e');
        failed.add(trip);
      }
    }
    await _writeLocalTrips(failed);
    return synced;
  }

  /// Discards guest trips (user declined sync, or logout cleanup).
  Future<void> clearLocalTrips() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_localTripsKey);
  }

  /// Create a new trip
  Future<Trip> createTrip({
    required String userId,
    required String name,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
    String? countryCode,
  }) async {
    try {
      final data = <String, dynamic>{
        'user_id': userId,
        'name': name,
        if (description != null) 'description': description,
        if (startDate != null) 'start_date': startDate.toIso8601String(),
        if (endDate != null) 'end_date': endDate.toIso8601String(),
        if (countryCode != null) 'country_code': countryCode.toUpperCase(),
        'status': 'planning',
        'is_active': false,
      };

      if (_isAnonymous) {
        final now = DateTime.now().toIso8601String();
        data
          ..['id'] = const Uuid().v4()
          ..['created_at'] = now
          ..['updated_at'] = now;
        final trip = Trip.fromJson(data);
        final locals = await _readLocalTrips();
        await _writeLocalTrips([...locals, trip]);
        return trip;
      }

      final response =
          await _supabase.from(_tableName).insert(data).select().single();

      return Trip.fromJson(response);
    } catch (e) {
      rethrow;
    }
  }

  /// Get all trips for a user
  Future<List<Trip>> getUserTrips(String userId) async {
    try {
      if (_isAnonymous) {
        final locals = (await _readLocalTrips())
            .where((t) => t.userId == userId)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return locals;
      }

      final response = await _supabase
          .from(_tableName)
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      return (response as List)
          .map((trip) => Trip.fromJson(trip as Map<String, dynamic>))
          .toList();
    } catch (e) {
      rethrow;
    }
  }

  /// Fetch a single trip by id. Used when we have the trip id from
  /// somewhere other than [getUserTrips] (e.g. a collaborator looking up
  /// their currently active shared trip) and need the canonical row with
  /// every column, instead of whatever subset an embedded join projected.
  Future<Trip?> getTripById(String tripId) async {
    try {
      if (_isAnonymous) {
        final locals = await _readLocalTrips();
        for (final t in locals) {
          if (t.id == tripId) return t;
        }
        return null;
      }

      final response = await _supabase
          .from(_tableName)
          .select()
          .eq('id', tripId)
          .maybeSingle();

      if (response == null) return null;
      return Trip.fromJson(response);
    } catch (e) {
      rethrow;
    }
  }

  /// Get active trip for a user
  Future<Trip?> getActiveTrip(String userId) async {
    try {
      if (_isAnonymous) {
        final locals = await _readLocalTrips();
        for (final t in locals) {
          if (t.userId == userId && t.isActive) return t;
        }
        return null;
      }

      final response = await _supabase
          .from(_tableName)
          .select()
          .eq('user_id', userId)
          .eq('is_active', true)
          .maybeSingle();

      if (response == null) return null;
      return Trip.fromJson(response);
    } catch (e) {
      rethrow;
    }
  }

  /// Set a trip as active (and deactivate others)
  Future<Trip> setActiveTrip(String userId, String tripId) async {
    try {
      if (_isAnonymous) {
        final now = DateTime.now().toIso8601String();
        final locals = await _readLocalTrips();
        Trip? activated;
        final updated = locals.map((t) {
          if (t.id == tripId) {
            activated = Trip.fromJson(t.toJson()
              ..['is_active'] = true
              ..['status'] = 'active'
              ..['updated_at'] = now);
            return activated!;
          }
          if (t.isActive) {
            return Trip.fromJson(t.toJson()..['is_active'] = false);
          }
          return t;
        }).toList();
        if (activated == null) {
          throw StateError('Local trip $tripId not found');
        }
        await _writeLocalTrips(updated);
        return activated!;
      }

      // Deactivate all other trips
      await _supabase
          .from(_tableName)
          .update({'is_active': false})
          .eq('user_id', userId)
          .neq('id', tripId);

      // Activate the selected trip
      final response = await _supabase
          .from(_tableName)
          .update({
            'is_active': true,
            'status': 'active',
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', tripId)
          .select()
          .single();

      return Trip.fromJson(response);
    } catch (e) {
      rethrow;
    }
  }

  /// Deactivate the active trip
  Future<Trip> deactivateTrip(String tripId) async {
    try {
      if (_isAnonymous) {
        final now = DateTime.now().toIso8601String();
        final locals = await _readLocalTrips();
        Trip? deactivated;
        final updated = locals.map((t) {
          if (t.id == tripId) {
            deactivated = Trip.fromJson(t.toJson()
              ..['is_active'] = false
              ..['status'] = 'planning'
              ..['updated_at'] = now);
            return deactivated!;
          }
          return t;
        }).toList();
        if (deactivated == null) {
          throw StateError('Local trip $tripId not found');
        }
        await _writeLocalTrips(updated);
        return deactivated!;
      }

      final response = await _supabase
          .from(_tableName)
          .update({
            'is_active': false,
            'status': 'planning',
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', tripId)
          .select()
          .single();

      return Trip.fromJson(response);
    } catch (e) {
      rethrow;
    }
  }

  /// Update trip details
  ///
  /// Pass [countryCode] to set a country (uppercased ISO 3166-1 alpha-2).
  /// Pass [clearCountryCode] = true to explicitly clear it back to NULL.
  /// Pass [clearDates] = true to explicitly clear start_date and end_date back
  /// to NULL — distinct from passing null for [startDate]/[endDate], which
  /// leaves the existing values untouched.
  Future<Trip> updateTrip(
    String tripId, {
    String? name,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
    double? totalDistance,
    int? totalDurationMinutes,
    String? countryCode,
    bool clearCountryCode = false,
    bool clearDates = false,
  }) async {
    try {
      final updates = <String, dynamic>{
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (clearDates)
          'start_date': null
        else if (startDate != null)
          'start_date': startDate.toIso8601String(),
        if (clearDates)
          'end_date': null
        else if (endDate != null)
          'end_date': endDate.toIso8601String(),
        if (totalDistance != null) 'total_distance': totalDistance,
        if (totalDurationMinutes != null)
          'total_duration_minutes': totalDurationMinutes,
        if (clearCountryCode)
          'country_code': null
        else if (countryCode != null)
          'country_code': countryCode.toUpperCase(),
        'updated_at': DateTime.now().toIso8601String(),
      };

      if (_isAnonymous) {
        final locals = await _readLocalTrips();
        Trip? changed;
        final next = locals.map((t) {
          if (t.id != tripId) return t;
          // Same semantics as the remote UPDATE: the map's explicit nulls
          // (clearDates / clearCountryCode) null the column; absent keys
          // leave it untouched.
          changed = Trip.fromJson(t.toJson()..addAll(updates));
          return changed!;
        }).toList();
        if (changed == null) {
          throw StateError('Local trip $tripId not found');
        }
        await _writeLocalTrips(next);
        return changed!;
      }

      final response = await _supabase
          .from(_tableName)
          .update(updates)
          .eq('id', tripId)
          .select()
          .single();

      return Trip.fromJson(response);
    } catch (e) {
      rethrow;
    }
  }

  /// Publish/unpublish a trip for copy-by-code sharing. Returns the share
  /// code (minted on first publish; stable across re-publishes). Signed-in
  /// owners only — the RPC enforces both.
  Future<String?> setTripPublic(String tripId, bool public) async {
    final result = await _supabase.rpc('set_trip_public', params: {
      'p_trip_id': tripId,
      'p_public': public,
    });
    return result as String?;
  }

  /// Whitelisted snapshot of a public trip by its share code, or null when
  /// the code is unknown OR the trip is private (indistinguishable by
  /// design). Throws [TripCodeException] for rate limiting.
  Future<Map<String, dynamic>?> getPublicTripPreview(String code) async {
    try {
      final result = await _supabase.rpc('get_public_trip_preview', params: {
        'p_code': code,
      });
      if (result == null) return null;
      return Map<String, dynamic>.from(result as Map);
    } on PostgrestException catch (e) {
      throw TripCodeException.fromMessage(e.message);
    }
  }

  /// Duplicates a public trip into the caller's account (server-side, one
  /// transaction: new trip + all locations re-anchored to [startDate],
  /// progress reset, copy born private). Returns the new trip id.
  Future<String> duplicatePublicTrip(String code, DateTime startDate) async {
    try {
      final result = await _supabase.rpc('duplicate_public_trip', params: {
        'p_code': code,
        'p_start_date': '${startDate.year.toString().padLeft(4, '0')}-'
            '${startDate.month.toString().padLeft(2, '0')}-'
            '${startDate.day.toString().padLeft(2, '0')}',
      });
      return result as String;
    } on PostgrestException catch (e) {
      throw TripCodeException.fromMessage(e.message);
    }
  }

  /// Delete a trip
  Future<void> deleteTrip(String tripId) async {
    try {
      if (_isAnonymous) {
        final locals = await _readLocalTrips();
        await _writeLocalTrips(locals.where((t) => t.id != tripId).toList());
        return;
      }

      await _supabase.from(_tableName).delete().eq('id', tripId);
    } catch (e) {
      rethrow;
    }
  }
}

/// Typed failures from the trip-code RPCs, mapped from the SQL RAISE
/// keywords so screens can show honest, specific messages.
enum TripCodeError { notPublic, copyLimit, rateLimited, ownTrip, unknown }

class TripCodeException implements Exception {
  TripCodeException(this.error, this.raw);

  final TripCodeError error;
  final String raw;

  factory TripCodeException.fromMessage(String message) {
    final m = message.toLowerCase();
    if (m.contains('not_public')) {
      return TripCodeException(TripCodeError.notPublic, message);
    }
    if (m.contains('copy_limit')) {
      return TripCodeException(TripCodeError.copyLimit, message);
    }
    if (m.contains('rate_limited')) {
      return TripCodeException(TripCodeError.rateLimited, message);
    }
    if (m.contains('own_trip')) {
      return TripCodeException(TripCodeError.ownTrip, message);
    }
    return TripCodeException(TripCodeError.unknown, message);
  }

  @override
  String toString() => 'TripCodeException(${error.name}): $raw';
}
