import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

class SupabaseService {
  SupabaseService._();

  static final SupabaseService instance = SupabaseService._();
  static final Completer<void> _initCompleter = Completer<void>();
  static bool _isInitialized = false;

  static Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await Supabase.initialize(
        url: dotenv.env['SUPABASE_URL'] ?? '',
        anonKey: dotenv.env['SUPABASE_ANON_KEY'] ?? '',
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
