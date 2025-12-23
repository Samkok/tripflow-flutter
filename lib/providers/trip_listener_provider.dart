import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/trip.dart';
import '../repositories/trip_repository.dart';
import '../services/trip_event_service.dart';
import 'auth_provider.dart';
import 'user_trip_provider.dart';
import 'local_active_trip_provider.dart';

/// Service that syncs database trip changes to the event service
class TripSyncService {
  final TripRepository _tripRepository;
  final TripEventService _eventService;

  TripSyncService({
    required TripRepository tripRepository,
    required TripEventService eventService,
  })  : _tripRepository = tripRepository,
        _eventService = eventService;

  /// Watch for active trip changes from database and emit events
  Future<Trip?> watchActiveTrip(String userId) async {
    try {
      final activeTrip = await _tripRepository.getActiveTrip(userId);
      
      if (activeTrip != null) {
        developer.log(
          'TripSyncService: Active trip detected - ${activeTrip.id}',
          name: 'trip_sync_service',
        );
        _eventService.notifyTripActivated(activeTrip);
      }
      
      return activeTrip;
    } catch (e) {
      developer.log(
        'TripSyncService: Error watching active trip - $e',
        name: 'trip_sync_service',
        error: e,
      );
      rethrow;
    }
  }
}

/// Provides singleton instance of trip sync service
final tripSyncServiceProvider = Provider<TripSyncService>((ref) {
  final tripRepository = ref.watch(tripRepositoryProvider);
  final eventService = TripEventService();
  return TripSyncService(
    tripRepository: tripRepository,
    eventService: eventService,
  );
});

/// Stream of trip events - emitted when trip activation/deactivation happens
final tripEventStreamProvider = StreamProvider<TripEvent>((ref) {
  final eventService = ref.watch(tripEventServiceProvider);
  return eventService.tripEventStream;
});

/// Real-time active trip with Riverpod integration
/// Now uses LOCAL storage instead of database for trip activation
/// This allows each user to independently activate/deactivate trips
final realtimeActiveTripProvider = StreamProvider<Trip?>((ref) async* {
  final authState = ref.watch(authStateProvider);

  final userId = authState.asData?.value.session?.user.id;

  if (userId == null) {
    yield null;
    return;
  }

  // Watch the local active trip provider
  // This emits whenever the locally stored active trip ID changes
  final localActiveTripAsync = ref.watch(localActiveTripProvider);

  final activeTrip = localActiveTripAsync.asData?.value;
  debugPrint(
    'realtimeActiveTripProvider: Local active trip - ${activeTrip?.id}');

  yield activeTrip;

  // Note: We no longer listen to trip events for activation/deactivation
  // since those are now purely local operations
  // The localActiveTripProvider will automatically update when changed
});
