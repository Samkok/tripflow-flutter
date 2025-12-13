import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/trip.dart';
import '../services/supabase_service.dart';

class TripRepository {
  final SupabaseClient _supabase = SupabaseService.instance.client;

  static const String _tableName = 'trips';

  /// Create a new trip
  Future<Trip> createTrip({
    required String userId,
    required String name,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final data = <String, dynamic>{
        'user_id': userId,
        'name': name,
        if (description != null) 'description': description,
        if (startDate != null) 'start_date': startDate.toIso8601String(),
        if (endDate != null) 'end_date': endDate.toIso8601String(),
        'status': 'planning',
        'is_active': false,
      };

      final response = await _supabase
          .from(_tableName)
          .insert(data)
          .select()
          .single();

      return Trip.fromJson(response);
    } catch (e) {
      rethrow;
    }
  }

  /// Get all trips for a user
  Future<List<Trip>> getUserTrips(String userId) async {
    try {
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

  /// Get active trip for a user
  Future<Trip?> getActiveTrip(String userId) async {
    try {
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
  Future<Trip> updateTrip(String tripId, {
    String? name,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
    double? totalDistance,
    int? totalDurationMinutes,
  }) async {
    try {
      final updates = <String, dynamic>{
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (startDate != null) 'start_date': startDate.toIso8601String(),
        if (endDate != null) 'end_date': endDate.toIso8601String(),
        if (totalDistance != null) 'total_distance': totalDistance,
        if (totalDurationMinutes != null)
          'total_duration_minutes': totalDurationMinutes,
        'updated_at': DateTime.now().toIso8601String(),
      };

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

  /// Delete a trip
  Future<void> deleteTrip(String tripId) async {
    try {
      await _supabase.from(_tableName).delete().eq('id', tripId);
    } catch (e) {
      rethrow;
    }
  }
}
