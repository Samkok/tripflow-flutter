import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/auth_service.dart';
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
