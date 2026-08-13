import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/auth_service.dart';
import '../services/revenuecat_service.dart';
import '../models/user_profile.dart';
import '../repositories/user_profile_repository.dart';
import 'location_provider.dart';

final userProfileRepositoryProvider = Provider<UserProfileRepository>((ref) {
  return UserProfileRepository();
});

final authServiceProvider = Provider<AuthService>((ref) {
  final locationRepository = ref.watch(locationRepositoryProvider);
  final userProfileRepository = ref.watch(userProfileRepositoryProvider);
  return AuthService(locationRepository, userProfileRepository);
});

final authStateProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(authServiceProvider).authStateChanges;
});

final currentUserProvider = Provider<User?>((ref) {
  final authState = ref.watch(authStateProvider);
  return authState.asData?.value.session?.user ??
      ref.watch(authServiceProvider).currentUser;
});

/// Stable user-ID provider — only emits a new value on login / logout,
/// NOT on every Supabase token refresh.
///
/// authStateProvider emits a new AsyncValue<AuthState> on every token refresh
/// (roughly every hour). If providers that control expensive UI (like
/// filteredLocationsForMapProvider or realtimeActiveTripProvider) watch
/// authStateProvider directly, they restart their streams on every refresh,
/// which immediately re-emits the full location list and triggers marker-bitmap
/// regeneration → map blink.
///
/// By watching this Provider<String?> instead, dependents only rebuild when the
/// user ID actually changes (login / logout), because String equality is
/// value-based: "same-id" == "same-id" → true → Riverpod skips the rebuild.
final currentUserIdProvider = Provider<String?>((ref) {
  final authState = ref.watch(authStateProvider);
  return authState.asData?.value.session?.user.id;
});

/// True while the session belongs to an INSTANT account (Supabase anonymous
/// sign-in): a real auth.uid with server-synced data, but no email yet.
/// Guests (no session at all) are `false` here — check
/// [currentUserIdProvider] == null for that state.
final isAnonymousUserProvider = Provider<bool>((ref) {
  final authState = ref.watch(authStateProvider);
  return authState.asData?.value.session?.user.isAnonymous ?? false;
});

/// THE gate for features that genuinely need an email identity:
/// collaborators (inviting and being invited), referral redeem/earn,
/// publishing a trip, copying by code. True only for a signed-in,
/// non-anonymous user with an email on the account.
///
/// Guests and instant accounts both read `false` — surfaces route them to
/// sign-up or the link-email screen respectively (see
/// showSignUpRequiredSheet, which branches on [isAnonymousUserProvider]).
final hasLinkedEmailProvider = Provider<bool>((ref) {
  final authState = ref.watch(authStateProvider);
  final user = authState.asData?.value.session?.user;
  if (user == null || user.isAnonymous) return false;
  return (user.email ?? '').isNotEmpty;
});

/// Profile lookup keyed by user_id. Used by surfaces that need to render
/// somebody OTHER than the signed-in user — chiefly the shared-trip badge
/// on the map screen, which shows the trip's owner. Riverpod caches the
/// per-userId result so flipping back to the same trip doesn't re-query.
///
/// Routes through the `get_public_user_profile` RPC because user_profiles
/// is RLS-locked to the row's own user; a direct SELECT from a
/// collaborator's session silently returns empty.
final userProfileByIdProvider =
    FutureProvider.family<UserProfile?, String>((ref, userId) async {
  final repo = ref.read(userProfileRepositoryProvider);
  return repo.getPublicUserProfile(userId);
});

/// Provider that listens to auth state changes and links RevenueCat user ID
/// This ensures RevenueCat is always in sync with Supabase authentication
final revenueCatAuthSyncProvider =
    FutureProvider.autoDispose<void>((ref) async {
  debugPrint('AuthProvider: revenueCatAuthSyncProvider started');

  // Wait for auth state to have data (not loading)
  final authState = await ref.watch(authStateProvider.future);
  final user = authState.session?.user;

  debugPrint('AuthProvider: Auth state received - user: ${user?.id ?? "null"}');

  if (user != null) {
    // User is authenticated - link RevenueCat with Supabase user ID
    try {
      debugPrint('AuthProvider: Waiting for RevenueCat initialization...');
      await RevenueCatService.waitForInitialization();
      final revenueCatService = RevenueCatService();

      // Check if already logged in with this user ID
      final currentAppUserId = await revenueCatService.getAppUserId();
      final isAnonymous = await revenueCatService.isAnonymous();

      debugPrint(
          'AuthProvider: Current RevenueCat app user ID: $currentAppUserId');
      debugPrint('AuthProvider: Is anonymous: $isAnonymous');
      debugPrint('AuthProvider: Supabase user ID: ${user.id}');

      if (currentAppUserId != user.id) {
        debugPrint(
            'AuthProvider: User IDs do not match - linking RevenueCat with user ${user.id}');
        await revenueCatService.login(user.id);
        debugPrint('AuthProvider: RevenueCat linked successfully');

        // Verify the link
        final newAppUserId = await revenueCatService.getAppUserId();
        debugPrint('AuthProvider: Verified - new app user ID: $newAppUserId');
      } else {
        debugPrint('AuthProvider: RevenueCat already linked to ${user.id}');
      }
    } catch (e) {
      debugPrint('AuthProvider: Failed to link RevenueCat user: $e');
      rethrow;
    }
  } else {
    // User logged out - logout from RevenueCat (creates new anonymous user)
    debugPrint('AuthProvider: No user session - handling logout');
    try {
      await RevenueCatService.waitForInitialization();
      final revenueCatService = RevenueCatService();

      // Only logout if not already anonymous
      final isAnonymous = await revenueCatService.isAnonymous();
      debugPrint('AuthProvider: Current anonymous status: $isAnonymous');

      if (!isAnonymous) {
        debugPrint('AuthProvider: Logging out RevenueCat user');
        await revenueCatService.logout();
        debugPrint('AuthProvider: RevenueCat logged out successfully');
      } else {
        debugPrint('AuthProvider: Already anonymous, no logout needed');
      }
    } catch (e) {
      debugPrint('AuthProvider: Failed to logout RevenueCat user: $e');
    }
  }

  debugPrint('AuthProvider: revenueCatAuthSyncProvider completed');
});
