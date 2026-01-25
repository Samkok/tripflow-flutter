import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/auth_service.dart';
import '../services/revenuecat_service.dart';
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

/// Provider that listens to auth state changes and links RevenueCat user ID
/// This ensures RevenueCat is always in sync with Supabase authentication
final revenueCatAuthSyncProvider = FutureProvider.autoDispose<void>((ref) async {
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

      debugPrint('AuthProvider: Current RevenueCat app user ID: $currentAppUserId');
      debugPrint('AuthProvider: Is anonymous: $isAnonymous');
      debugPrint('AuthProvider: Supabase user ID: ${user.id}');

      if (currentAppUserId != user.id) {
        debugPrint('AuthProvider: User IDs do not match - linking RevenueCat with user ${user.id}');
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
