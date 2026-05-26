import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyza/repositories/location_repository.dart';
import 'package:voyza/repositories/user_profile_repository.dart';
import 'package:voyza/services/supabase_service.dart';
import 'package:voyza/services/revenuecat_service.dart';
import 'package:voyza/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/saved_location.dart';

/// Raised by [AuthService.signUp] when the email is already in use by an
/// existing confirmed account. Supabase intentionally suppresses an
/// explicit "duplicate" error from `auth.signUp` to prevent email
/// enumeration — instead it returns a stub `User` with an empty
/// `identities` list. We detect that pattern and convert it into this
/// typed exception so the UI can surface a clear message and offer the
/// password-reset flow.
class EmailAlreadyRegisteredException implements Exception {
  final String email;
  const EmailAlreadyRegisteredException(this.email);

  @override
  String toString() =>
      'EmailAlreadyRegisteredException: $email is already registered';
}

class AuthService {
  final SupabaseClient _supabase = SupabaseService.instance.client;
  final LocationRepository _locationRepository;
  final UserProfileRepository _userProfileRepository;

  static const String _syncChoiceKey = 'sync_anonymous_locations_choice';
  static const String _rememberMeKey = 'remember_me';
  static const String _savedEmailKey = 'saved_email';

  /// SharedPreferences key holding the lowercase emails for which the
  /// user has already been prompted to save their password to the
  /// device's password manager. We can't ask the OS "is this credential
  /// already in Keychain / Google Password Manager?" from Flutter, so
  /// instead we remember per-email whether we've already shown our
  /// in-app save prompt — that way users don't get nagged on every
  /// sign-in.
  static const String _passwordSavePromptedEmailsKey =
      'password_save_prompted_emails';

  AuthService(this._locationRepository, [UserProfileRepository? userProfileRepository])
      : _userProfileRepository = userProfileRepository ?? UserProfileRepository();

  User? get currentUser => _supabase.auth.currentUser;

  /// Returns the count of local locations that need syncing
  Future<int> signIn(String email, String password) async {
    try {
      final response = await _supabase.auth
          .signInWithPassword(email: email, password: password);

      if (response.user != null) {
        // Link RevenueCat user identity with Supabase user
        try {
          await RevenueCatService().login(response.user!.id);

          // Set user attributes for analytics
          await RevenueCatService().setUserAttributes(
            email: response.user!.email,
          );
        } catch (e) {
          debugPrint('Failed to link RevenueCat user: $e');
          // Don't fail the whole login if RevenueCat fails
        }

        // Register device for push notifications (fire-and-forget)
        try {
          await NotificationService().registerToken();
        } catch (e) {
          debugPrint('AuthService: Failed to register push token: $e');
        }

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
  /// Also sets the sync choice flag to allow auto-sync in providers
  Future<void> syncLocalLocations() async {
    // Mark that user chose to sync
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_syncChoiceKey, true);

    await _locationRepository.syncOnLogin();
  }

  /// Sets the sync choice flag when user declines to sync.
  /// Also removes anonymous local locations from Hive so they don't appear
  /// on the authenticated user's map.
  Future<void> declineSync() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_syncChoiceKey, false);
    await _locationRepository.cleanUpAnonymousData();
  }

  /// Checks if user has chosen to sync anonymous locations
  /// Returns null if user hasn't been asked yet
  static Future<bool?> getSyncChoice() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_syncChoiceKey);
  }

  /// Clears the sync choice (used on logout)
  static Future<void> clearSyncChoice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_syncChoiceKey);
  }

  /// Saves the "Remember Me" preference and email after a successful sign-in.
  /// Only the email is stored (never the password).
  static Future<void> saveRememberMe(bool remember, String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rememberMeKey, remember);
    if (remember) {
      await prefs.setString(_savedEmailKey, email);
    } else {
      await prefs.remove(_savedEmailKey);
    }
  }

  /// Returns the saved "Remember Me" preference.
  /// Defaults to true so existing users are not unexpectedly signed out.
  static Future<bool> getRememberMe() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_rememberMeKey) ?? true;
  }

  /// Returns the saved email address, or null if none was stored.
  static Future<String?> getSavedEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_savedEmailKey);
  }

  /// Clears Remember Me data (called on sign-out so the next user starts fresh).
  static Future<void> clearRememberMe() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_rememberMeKey);
    await prefs.remove(_savedEmailKey);
  }

  /// Returns true when the user has already responded (Save or Not now)
  /// to the "save password to device" prompt for [email] — keeps the
  /// login screen from re-asking every time they sign in with a known
  /// account. Email comparison is case-insensitive.
  static Future<bool> hasPromptedSavePassword(String email) async {
    if (email.isEmpty) return true;
    final prefs = await SharedPreferences.getInstance();
    final list =
        prefs.getStringList(_passwordSavePromptedEmailsKey) ?? const [];
    return list.contains(email.trim().toLowerCase());
  }

  /// Records that the user has been asked about saving [email]'s
  /// password — appended whether they said Save or Not now, so we
  /// never nag again for the same address.
  static Future<void> markPromptedSavePassword(String email) async {
    if (email.isEmpty) return;
    final normalized = email.trim().toLowerCase();
    final prefs = await SharedPreferences.getInstance();
    final list =
        prefs.getStringList(_passwordSavePromptedEmailsKey) ?? const [];
    if (list.contains(normalized)) return;
    await prefs.setStringList(
      _passwordSavePromptedEmailsKey,
      [...list, normalized],
    );
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

      // Anti-enumeration guard.
      //
      // Supabase's behavior for a re-signup with an existing email
      // varies by project config and gotrue version, but every shape
      // we've seen falls into one of these:
      //
      //   a) Returns a "stub" User with an empty `identities` list
      //      (anti-enumeration on, the default in recent versions).
      //   b) Returns response.user == null with no thrown error
      //      (older configurations).
      //   c) Throws an `AuthException` directly with a "User already
      //      registered" / "already exists" / "user_already_exists"
      //      message — handled by the screen's `on AuthException`
      //      arm.
      //
      // (a) and (b) are both caught here. (c) bubbles up as
      // AuthException.
      final user = response.user;
      final identities = user?.identities;
      final looksLikeDuplicate = user == null ||
          identities == null ||
          identities.isEmpty;
      if (looksLikeDuplicate) {
        throw EmailAlreadyRegisteredException(email);
      }

      if (response.user != null) {
        // Link RevenueCat user identity with Supabase user
        try {
          await RevenueCatService().login(response.user!.id);

          // Set user attributes for analytics
          await RevenueCatService().setUserAttributes(
            email: email,
            displayName: firstName != null && lastName != null
                ? '$firstName $lastName'
                : firstName ?? lastName,
            phoneNumber: phoneNumber,
          );
        } catch (e) {
          debugPrint('Failed to link RevenueCat user: $e');
          // Don't fail the whole signup if RevenueCat fails
        }

        // Create user profile in user_profiles table.
        //
        // Defensive duplicate-email backstop: if (a) and (b) above
        // both missed (e.g. an unusual Supabase config that returns a
        // re-confirmed identity for an existing account), the INSERT
        // here will fail with a Postgres unique violation because the
        // user_profiles row for this user_id already exists. We
        // translate that into the same typed exception so the UI
        // surfaces the same "account exists" dialog instead of an
        // opaque "Unexpected error".
        try {
          await _userProfileRepository.createUserProfile(
            userId: response.user!.id,
            email: email,
            firstName: firstName,
            lastName: lastName,
            phoneNumber: phoneNumber,
          );
        } on PostgrestException catch (e) {
          // 23505 = unique_violation. The only path to that on a
          // fresh user_id is if the row already existed — i.e. this
          // email/account already had a profile, which means the
          // sign-up was actually a duplicate that the earlier checks
          // missed.
          final isDuplicate = e.code == '23505' ||
              e.message.toLowerCase().contains('duplicate') ||
              e.message.toLowerCase().contains('unique');
          if (isDuplicate) {
            throw EmailAlreadyRegisteredException(email);
          }
          rethrow;
        }
      }
    } catch (e) {
      debugPrint('e during sign up: $e');
      rethrow;
    }
  }

  Stream<AuthState> get authStateChanges {
    return _supabase.auth.onAuthStateChange;
  }

  /// Sends a password reset email with the app's custom scheme redirect.
  Future<void> sendPasswordResetEmail(String email) async {
    await _supabase.auth.resetPasswordForEmail(
      email,
      redirectTo: 'voyza://reset-password',
    );
  }

  /// Updates the authenticated user's password during a recovery session.
  Future<void> updatePassword(String newPassword) async {
    await _supabase.auth.updateUser(
      UserAttributes(password: newPassword),
    );
  }

  /// Performs the actual sign-out operation.
  /// UI concerns like showing dialogs should be handled by the caller.
  ///
  /// Ordering matters for UX: the previous implementation awaited two
  /// network round trips (FCM token deregister + RevenueCat logout) and
  /// a Hive wipe BEFORE calling Supabase's signOut. That left the user
  /// staring at the settings screen for several seconds before the
  /// onAuthStateChange listener in main.dart could swap to LoginScreen.
  ///
  /// New order:
  ///   1. Fast local cleanups in parallel (Hive wipe, prefs).
  ///   2. Fire-and-forget the network cleanups. Both use the still-valid
  ///      JWT — the request goes out before Supabase's signOut tears
  ///      down the client session, and the access token remains valid
  ///      server-side until expiry, so the in-flight request still
  ///      succeeds. Worst case it fails silently — a stale token row
  ///      is harmless (it's not used for anything until the next login).
  ///   3. Supabase signOut — this fires the `signedOut` event that the
  ///      navigator listener in main.dart watches for. UI flips
  ///      immediately.
  Future<void> signOut() async {
    // 1. Fast local cleanups — these never block on the network.
    await Future.wait([
      clearSyncChoice(),
      clearRememberMe(),
      _locationRepository.clearUserData().catchError((e) {
        debugPrint('AuthService: clearUserData failed: $e');
        return null;
      }),
    ]);

    // 2. Network cleanups — kick off, don't block. Wrapped in
    // safe-helpers that swallow their own errors so a failure here
    // can't surface to the caller after we've already torn things down.
    unawaited(_deregisterPushTokenSafely());
    unawaited(_logoutRevenueCatSafely());

    // 3. Tear down the Supabase session — fires signedOut, listener
    // navigates the user to LoginScreen.
    await _supabase.auth.signOut();
  }

  Future<void> _deregisterPushTokenSafely() async {
    try {
      await NotificationService().deregisterToken();
    } catch (e) {
      debugPrint('AuthService: Failed to deregister push token: $e');
    }
  }

  Future<void> _logoutRevenueCatSafely() async {
    try {
      await RevenueCatService().logout();
    } catch (e) {
      debugPrint('AuthService: Failed to logout from RevenueCat: $e');
    }
  }

  /// Permanently delete the current user's account and all associated data
  /// This includes:
  /// - All locations created by the user
  /// - All trips owned by the user
  /// - Trip collaborations
  /// - User profile
  /// - Subscription records (via CASCADE)
  /// - Local cache and storage
  /// - Supabase auth account
  Future<void> deleteAccount() async {
    final user = _supabase.auth.currentUser;
    if (user == null) {
      throw Exception('No user logged in');
    }

    try {
      debugPrint('AuthService: Starting account deletion for user ${user.id}');

      // Step 1: Delete all user's locations
      debugPrint('AuthService: Deleting user locations...');
      await _supabase
          .from('locations')
          .delete()
          .eq('user_id', user.id);
      debugPrint('AuthService: User locations deleted');

      // Step 2: Delete all trips owned by user
      debugPrint('AuthService: Deleting user trips...');
      await _supabase
          .from('trips')
          .delete()
          .eq('user_id', user.id);
      debugPrint('AuthService: User trips deleted');

      // Step 3: Delete user profile (this will CASCADE delete subscriptions and collaborations)
      debugPrint('AuthService: Deleting user profile...');
      await _userProfileRepository.deleteUserProfile(user.id);
      debugPrint('AuthService: User profile deleted');

      // Step 4: Clear local storage
      debugPrint('AuthService: Clearing local storage...');
      await _clearLocalStorage();
      debugPrint('AuthService: Local storage cleared');

      // Step 5: Logout from RevenueCat (creates new anonymous user)
      debugPrint('AuthService: Logging out from RevenueCat...');
      try {
        await RevenueCatService.waitForInitialization();
        final revenueCatService = RevenueCatService();
        await revenueCatService.logout();
        debugPrint('AuthService: RevenueCat logout successful');
      } catch (e) {
        debugPrint('AuthService: RevenueCat logout failed (non-critical): $e');
        // Continue with deletion even if RevenueCat logout fails
      }

      // Step 6: Delete Supabase auth account (this signs the user out)
      debugPrint('AuthService: Deleting Supabase auth account...');

      // Use admin API to delete user account
      // Note: This requires RLS policies to allow users to delete their own account
      // or using a Supabase Edge Function with service role key
      await _supabase.rpc('delete_user_account');

      debugPrint('AuthService: Account deletion completed successfully');
    } catch (e) {
      debugPrint('AuthService: Account deletion failed - $e');
      rethrow;
    }
  }

  /// Clear all local storage and cache
  Future<void> _clearLocalStorage() async {
    try {
      // Clear Hive boxes
      final locationBox = await Hive.openBox<SavedLocation>('locations');
      await locationBox.clear();
      debugPrint('AuthService: Hive location box cleared');

      // Clear SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      debugPrint('AuthService: SharedPreferences cleared');
    } catch (e) {
      debugPrint('AuthService: Error clearing local storage: $e');
      // Don't throw - local storage cleanup is best-effort
    }
  }
}