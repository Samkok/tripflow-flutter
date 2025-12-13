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
