import 'package:flutter/foundation.dart';
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

  /// Log a trial start event and update the trial_start_at field
  Future<void> logTrialStart({
    required String userId,
    required String deviceId,
    required String productIdentifier,
  }) async {
    try {
      // Update user_profile with trial_start_at
      await _supabase
          .from(_tableName)
          .update({
            'trial_start_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('user_id', userId);

      // Log to trial_devices table
      await _supabase.from('trial_devices').insert({
        'user_id': userId,
        'device_id': deviceId,
        'product_identifier': productIdentifier,
        'trial_started_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      rethrow;
    }
  }

  /// Ensure user_subscriptions record exists for an active trial.
  /// Used as fallback when RevenueCat webhook hasn't fired yet or user is anonymous.
  /// Assumes the trial is already active in RevenueCat SDK.
  ///
  /// [revenueCatAppUserId] should be the subscriber's ORIGINAL RevenueCat app
  /// user id (CustomerInfo.originalAppUserId) — typically the $RCAnonymousID the
  /// trial was bought under before signup. Storing it lets the revenuecat-webhook
  /// map later anonymous-keyed lifecycle events (CANCELLATION/EXPIRATION) back to
  /// this row when RevenueCat's transfer behavior keeps the purchase on the
  /// original id. Without it, this row can get stuck 'active' = free access.
  Future<void> syncTrialSubscription({
    required String userId,
    required String productIdentifier,
    required DateTime? trialExpiresAt,
    String? revenueCatAppUserId,
  }) async {
    try {
      // Try to upsert so existing record isn't overwritten if webhook beat us here
      final now = DateTime.now().toIso8601String();
      final expiresAtStr = trialExpiresAt?.toIso8601String() ??
          DateTime.now().add(const Duration(days: 3)).toIso8601String(); // Default 3-day trial

      await _supabase.from('user_subscriptions').upsert(
        {
          'user_id': userId,
          'entitlement': 'premium',
          'status': 'active',
          'product_identifier': productIdentifier,
          'will_renew': false, // Trial doesn't auto-renew
          'expires_at': expiresAtStr,
          if (revenueCatAppUserId != null)
            'revenuecat_app_user_id': revenueCatAppUserId,
          'created_at': now,
          'updated_at': now,
        },
        onConflict: 'user_id',
      );

      debugPrint('UserProfileRepository: ✅ Trial subscription synced for user $userId');
    } catch (e) {
      debugPrint('UserProfileRepository: ⚠️ Failed to sync trial subscription: $e');
      // Non-fatal — webhook will eventually create the record
    }
  }
}
