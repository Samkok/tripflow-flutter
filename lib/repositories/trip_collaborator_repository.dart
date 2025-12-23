import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/trip_collaborator.dart';
import '../services/supabase_service.dart';

class AddCollaboratorResult {
  final bool success;
  final String? error;
  final TripCollaborator? collaborator;

  AddCollaboratorResult({
    required this.success,
    this.error,
    this.collaborator,
  });
}

class TripCollaboratorRepository {
  final SupabaseClient _supabase = SupabaseService.instance.client;

  static const String _tableName = 'trip_collaborators';

  /// Check if a user exists by email
  Future<String?> getUserIdByEmail(String email) async {
    try {
      final response = await _supabase
          .rpc('get_user_id_by_email', params: {'user_email': email});

      if (response == null) return null;
      return response as String;
    } catch (e) {
      debugPrint('Error getting user by email: $e');
      return null;
    }
  }

  /// Add a collaborator to a trip
  Future<AddCollaboratorResult> addCollaborator({
    required String tripId,
    required String email,
    required String permission,
  }) async {
    try {
      // First, check if the email exists
      final userId = await getUserIdByEmail(email);

      if (userId == null) {
        return AddCollaboratorResult(
          success: false,
          error: 'No user found with email: $email',
        );
      }

      // Check if user is trying to add themselves
      final currentUserId = _supabase.auth.currentUser?.id;
      if (userId == currentUserId) {
        return AddCollaboratorResult(
          success: false,
          error: 'You cannot add yourself as a collaborator',
        );
      }

      // Check if collaborator already exists
      final existing = await _supabase
          .from(_tableName)
          .select()
          .eq('trip_id', tripId)
          .eq('user_id', userId)
          .maybeSingle();

      if (existing != null) {
        return AddCollaboratorResult(
          success: false,
          error: 'This user is already a collaborator on this trip',
        );
      }

      // Add the collaborator
      final data = {
        'trip_id': tripId,
        'user_id': userId,
        'email': email,
        'permission': permission,
        'invited_by': currentUserId,
        'invited_at': DateTime.now().toUtc().toIso8601String(),
      };

      final response = await _supabase
          .from(_tableName)
          .insert(data)
          .select()
          .single();

      return AddCollaboratorResult(
        success: true,
        collaborator: TripCollaborator.fromJson(response),
      );
    } catch (e) {
      debugPrint('Error adding collaborator: $e');
      return AddCollaboratorResult(
        success: false,
        error: 'Failed to add collaborator: ${e.toString()}',
      );
    }
  }

  /// Get all collaborators for a trip
  Future<List<TripCollaborator>> getCollaborators(String tripId) async {
    try {
      final response = await _supabase
          .from(_tableName)
          .select()
          .eq('trip_id', tripId)
          .order('created_at', ascending: true);

      return (response as List)
          .map((data) => TripCollaborator.fromJson(data as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Error getting collaborators: $e');
      return [];
    }
  }

  /// Update collaborator permission
  Future<bool> updatePermission({
    required String collaboratorId,
    required String permission,
  }) async {
    try {
      await _supabase
          .from(_tableName)
          .update({
            'permission': permission,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', collaboratorId);

      return true;
    } catch (e) {
      debugPrint('Error updating permission: $e');
      return false;
    }
  }

  /// Remove a collaborator from a trip
  Future<bool> removeCollaborator(String collaboratorId) async {
    try {
      await _supabase
          .from(_tableName)
          .delete()
          .eq('id', collaboratorId);

      return true;
    } catch (e) {
      debugPrint('Error removing collaborator: $e');
      return false;
    }
  }

  /// Leave a trip (remove self as collaborator)
  Future<bool> leaveTrip(String tripId) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return false;

      await _supabase
          .from(_tableName)
          .delete()
          .eq('trip_id', tripId)
          .eq('user_id', userId);

      return true;
    } catch (e) {
      debugPrint('Error leaving trip: $e');
      return false;
    }
  }

  /// Get all trips shared with the current user (where user is a collaborator)
  Future<List<Map<String, dynamic>>> getSharedTrips() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return [];

      // Get collaborator records with trip details
      final response = await _supabase
          .from(_tableName)
          .select('''
            *,
            trips:trip_id (
              id,
              user_id,
              name,
              description,
              status,
              is_active,
              start_date,
              end_date,
              total_distance,
              total_duration_minutes,
              created_at,
              updated_at
            )
          ''')
          .eq('user_id', userId);

      // Filter out trips where the current user is the owner
      // (they should only appear in "My Trips", not "Shared With You")
      final filteredResponse = (response as List)
          .where((item) {
            final trip = item['trips'] as Map<String, dynamic>?;
            if (trip == null) return false;
            final tripOwnerId = trip['user_id'] as String?;
            return tripOwnerId != userId;
          })
          .toList();

      return filteredResponse.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('Error getting shared trips: $e');
      return [];
    }
  }

  /// Check user's permission on a trip
  Future<String?> getUserPermission(String tripId) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return null;

      final response = await _supabase
          .from(_tableName)
          .select('permission')
          .eq('trip_id', tripId)
          .eq('user_id', userId)
          .maybeSingle();

      if (response == null) return null;
      return response['permission'] as String;
    } catch (e) {
      debugPrint('Error getting user permission: $e');
      return null;
    }
  }

  /// Check if current user is the trip owner
  Future<bool> isOwner(String tripId) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return false;

      final response = await _supabase
          .from('trips')
          .select('user_id')
          .eq('id', tripId)
          .single();

      return response['user_id'] == userId;
    } catch (e) {
      debugPrint('Error checking ownership: $e');
      return false;
    }
  }
}
