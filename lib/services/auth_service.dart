import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyza/repositories/location_repository.dart';
import 'package:voyza/repositories/user_profile_repository.dart';
import 'package:voyza/services/supabase_service.dart'; // Keep this if other methods use it

class AuthService {
  final SupabaseClient _supabase = SupabaseService.instance.client;
  final LocationRepository _locationRepository;
  final UserProfileRepository _userProfileRepository;

  AuthService(this._locationRepository, [UserProfileRepository? userProfileRepository])
      : _userProfileRepository = userProfileRepository ?? UserProfileRepository();

  User? get currentUser => _supabase.auth.currentUser;

  /// Returns the count of local locations that need syncing
  Future<int> signIn(String email, String password) async {
    try {
      final response = await _supabase.auth
          .signInWithPassword(email: email, password: password);

      if (response.user != null) {
        // Check if there are local locations before syncing
        await _locationRepository.init();
        final localLocationCount = await _locationRepository.getLocalLocationCount();
        return localLocationCount;
      }
      return 0;
    } catch (e) {
      rethrow;
    }
  }

  /// Performs the sync of local locations to the cloud
  Future<void> syncLocalLocations() async {
    await _locationRepository.syncOnLogin();
  }

  Future<void> signUp(
    String email,
    String password, {
    String? firstName,
    String? lastName,
    String? phoneNumber,
  }) async {
    try {
      // Create user account
      final response = await _supabase.auth.signUp(
        email: email,
        password: password,
      );

      if (response.user != null) {
        // Create user profile in user_profiles table
        await _userProfileRepository.createUserProfile(
          userId: response.user!.id,
          email: email,
          firstName: firstName,
          lastName: lastName,
          phoneNumber: phoneNumber,
        );
      }
    } catch (e) {
      print('e during sign up: $e');
      rethrow;
    }
  }

  Stream<AuthState> get authStateChanges {
    return _supabase.auth.onAuthStateChange;
  }

  /// Performs the actual sign-out operation.
  /// UI concerns like showing dialogs should be handled by the caller.
  Future<void> signOut() async {
    await _supabase.auth.signOut();
  }
}