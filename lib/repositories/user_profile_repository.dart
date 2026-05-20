import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user_profile.dart';
import '../services/supabase_service.dart';

class UserProfileRepository {
  final SupabaseClient _supabase = SupabaseService.instance.client;

  static const String _tableName = 'user_profiles';

  /// Create a new user profile when user signs up
  Future<UserProfile> createUserProfile({
    required String userId,
    required String email,
    String? firstName,
    String? lastName,
    String? phoneNumber,
    String? profilePictureUrl,
    String? bio,
    String? dateOfBirth,
    String? gender,
    String? address,
    String? city,
    String? country,
    Map<String, dynamic>? preferences,
  }) async {
    try {
      // Call the RPC function that bypasses RLS with security definer
      final response = await _supabase.rpc(
        'create_user_profile',
        params: {
          'p_user_id': userId,
          'p_email': email,
          'p_first_name': firstName,
          'p_last_name': lastName,
          'p_phone_number': phoneNumber,
          'p_profile_picture_url': profilePictureUrl,
          'p_bio': bio,
          'p_date_of_birth': dateOfBirth,
          'p_gender': gender,
          'p_address': address,
          'p_city': city,
          'p_country': country,
          'p_preferences': preferences ?? {},
        },
      );

      return UserProfile.fromJson(response);
    } catch (e) {
      rethrow;
    }
  }

  /// Fetch user profile by user ID
  Future<UserProfile?> getUserProfile(String userId) async {
    try {
      final response =
          await _supabase.from(_tableName).select().eq('user_id', userId);

      if (response.isEmpty) {
        return null;
      }

      return UserProfile.fromJson(response.first);
    } catch (e) {
      rethrow;
    }
  }

  /// Fetch the *publicly visible* slice of someone else's profile by user
  /// id. Used by surfaces that need to render somebody other than the
  /// signed-in user (e.g. the trip owner pill on a collaborator's map
  /// screen).
  ///
  /// Goes through the `get_public_user_profile` RPC because the standard
  /// SELECT on `user_profiles` is RLS-restricted to `auth.uid() = user_id`
  /// — a direct fetch from a collaborator session silently returns empty.
  /// The RPC is `SECURITY DEFINER` and only exposes a minimal projection
  /// (first_name, last_name, email) so it can be safely callable for any
  /// authenticated user.
  ///
  /// Returns null if the RPC isn't deployed, the user doesn't exist, or
  /// the call fails for any other reason — callers should treat null as
  /// "unknown owner" and render a fallback.
  Future<UserProfile?> getPublicUserProfile(String userId) async {
    try {
      final response = await _supabase
          .rpc('get_public_user_profile', params: {'p_user_id': userId});

      if (response == null) return null;

      // RPC may return either a single row map or a list with one row
      // depending on how it's declared (TABLE vs SETOF). Handle both.
      final row = response is List
          ? (response.isEmpty ? null : response.first as Map<String, dynamic>)
          : response as Map<String, dynamic>?;
      if (row == null) return null;

      // The RPC returns a thin projection — fill in defaults for fields
      // it doesn't expose so UserProfile.fromJson stays happy.
      final now = DateTime.now().toIso8601String();
      return UserProfile.fromJson({
        'id': row['id'] ?? userId,
        'user_id': row['user_id'] ?? userId,
        'first_name': row['first_name'],
        'last_name': row['last_name'],
        'email': row['email'] ?? '',
        'created_at': row['created_at'] ?? now,
        'updated_at': row['updated_at'] ?? now,
      });
    } catch (e) {
      return null;
    }
  }

  /// Update user profile
  Future<UserProfile> updateUserProfile(String userId, UserProfile profile) async {
    try {
      final response = await _supabase
          .from(_tableName)
          .update({
            ...profile.toJson(),
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('user_id', userId)
          .select()
          .single();

      return UserProfile.fromJson(response);
    } catch (e) {
      rethrow;
    }
  }

  /// Delete user profile (usually called on account deletion)
  Future<void> deleteUserProfile(String userId) async {
    try {
      await _supabase.from(_tableName).delete().eq('user_id', userId);
    } catch (e) {
      rethrow;
    }
  }

  /// Update specific profile fields
  Future<UserProfile> updateProfileField(
    String userId,
    Map<String, dynamic> updates,
  ) async {
    try {
      final response = await _supabase
          .from(_tableName)
          .update({
            ...updates,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('user_id', userId)
          .select()
          .single();

      return UserProfile.fromJson(response);
    } catch (e) {
      rethrow;
    }
  }
}
