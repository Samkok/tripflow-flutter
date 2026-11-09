import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/trip.dart';
import '../repositories/trip_repository.dart';
import '../services/anonymous_user_service.dart';
import 'auth_provider.dart';

final tripRepositoryProvider = Provider<TripRepository>((ref) {
  return TripRepository();
});

/// Get all user trips
final userTripsProvider = FutureProvider<List<Trip>>((ref) async {
  final authState = ref.watch(authStateProvider);
  final tripRepository = ref.watch(tripRepositoryProvider);

  return authState.when(
    data: (state) async {
      // Guests keep the same trips surface, served from the local store —
      // the repository branches on auth internally.
      final userId = state.session?.user.id ?? await AnonymousUserService.id;
      return tripRepository.getUserTrips(userId);
    },
    loading: () => [],
    error: (_, __) => [],
  );
});
