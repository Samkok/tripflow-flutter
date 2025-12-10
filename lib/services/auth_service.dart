import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyza/repositories/location_repository.dart';
import 'package:voyza/services/supabase_service.dart';
import 'package:voyza/widgets/signed_out_dialog.dart';

class AuthService {
  final SupabaseClient _supabase = SupabaseService.instance.client;
  final LocationRepository _locationRepository;

  AuthService(this._locationRepository);

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

  Future<void> signUp(String email, String password) async {
    await _supabase.auth.signUp(email: email, password: password);
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