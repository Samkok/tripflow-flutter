import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/trip.dart';
import '../repositories/trip_repository.dart';
import '../repositories/trip_repository_with_events.dart';
import '../services/trip_event_service.dart';
import 'auth_provider.dart';

final tripRepositoryProvider = Provider<TripRepository>((ref) {
  return TripRepository();
});

/// Trip repository with event emission
/// Use this when you need trip state changes to be broadcast to subscribers
final tripRepositoryWithEventsProvider =
    Provider<TripRepositoryWithEvents>((ref) {
  final repository = ref.watch(tripRepositoryProvider);
  final eventService = TripEventService();
  return TripRepositoryWithEvents(
    repository: repository,
    eventService: eventService,
  );
});

/// Get all user trips
final userTripsProvider = FutureProvider<List<Trip>>((ref) async {
  final authState = ref.watch(authStateProvider);
  final tripRepository = ref.watch(tripRepositoryProvider);

  return authState.when(
    data: (state) {
      final userId = state.session?.user.id;
      if (userId == null) return [];
      return tripRepository.getUserTrips(userId);
    },
    loading: () => [],
    error: (_, __) => [],
  );
});

/// Get active trip
final activeTripsProvider = FutureProvider<Trip?>((ref) async {
  final authState = ref.watch(authStateProvider);
  final tripRepository = ref.watch(tripRepositoryProvider);

  return authState.when(
    data: (state) {
      final userId = state.session?.user.id;
      if (userId == null) return null;
      return tripRepository.getActiveTrip(userId);
    },
    loading: () => null,
    error: (_, __) => null,
  );
});
