import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyza/repositories/location_repository.dart';
import 'package:voyza/repositories/user_profile_repository.dart';
import 'package:voyza/services/supabase_service.dart';
import 'package:voyza/widgets/signed_out_dialog.dart';

class AuthService {
  final SupabaseClient _supabase = SupabaseService.instance.client;
  final LocationRepository _locationRepository;
  final UserProfileRepository _userProfileRepository;

  AuthService(this._locationRepository, [UserProfileRepository? userProfileRepository])
      : _userProfileRepository = userProfileRepository ?? UserProfileRepository();

  User? get currentUser => _supabase.auth.currentUser;

  Future<void> signIn(String email, String password) async {
    try {
      final response = await _supabase.auth
          .signInWithPassword(email: email, password: password);
      if (response.user != null) {
        await _locationRepository.syncOnLogin();
      }
    } catch (e) {
      rethrow;
    }
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

  Future<void> signOut(BuildContext context) async {
    await _supabase.auth.signOut();

    // Show the signed-out dialog
    if (context.mounted) {
      showDialog(
        context: context,
        builder: (BuildContext dialogContext) => const SignedOutDialog(),
      );
    }
  }
}