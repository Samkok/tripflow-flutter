import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

class SupabaseService {
  SupabaseService._();

  static final SupabaseService instance = SupabaseService._();
  static final Completer<void> _initCompleter = Completer<void>();
  static bool _isInitialized = false;

  /// Sent with every request from builds that ask for VoyZa Pro before a
  /// place is added (2026-11-10 onwards). The optional server rule in
  /// supabase/manual/locations_pro_gate_old_builds.sql skips any request
  /// that carries it, so that rule can only ever touch older builds.
  static const proGateHeader = 'x-voyza-pro-gate';

  static Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await Supabase.initialize(
        url: dotenv.env['SUPABASE_URL'] ?? '',
        anonKey: dotenv.env['SUPABASE_ANON_KEY'] ?? '',
        headers: const {proGateHeader: '1'},
      );
      _isInitialized = true;
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
    } catch (e) {
      if (!_initCompleter.isCompleted) {
        _initCompleter.completeError(e);
      }
      rethrow;
    }
  }

  /// Wait for Supabase to be initialized before using it
  static Future<void> waitForInitialization() async {
    if (_isInitialized) return;
    await _initCompleter.future;
  }

  /// Check if Supabase is already initialized
  static bool get isInitialized => _isInitialized;

  SupabaseClient get client => Supabase.instance.client;
  GoTrueClient get auth => client.auth;
}
