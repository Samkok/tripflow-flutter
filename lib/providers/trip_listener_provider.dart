import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/trip.dart';
import '../repositories/trip_repository.dart';
import '../services/trip_event_service.dart';
import 'auth_provider.dart';
import 'user_trip_provider.dart';

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
/// Combines database polling with event streaming for instant updates
/// when user activates/deactivates a trip
final realtimeActiveTripProvider = StreamProvider<Trip?>((ref) async* {
  final authState = ref.watch(authStateProvider);
  final tripRepository = ref.watch(tripRepositoryProvider);
  final eventService = ref.watch(tripEventServiceProvider);

  final userId = authState.asData?.value.session?.user.id;
  
  if (userId == null) {
    yield null;
    return;
  }

  // Initial fetch of active trip from database
  try {
    final activeTrip = await tripRepository.getActiveTrip(userId);
    debugPrint(
      'realtimeActiveTripProvider: Initial active trip fetch - ${activeTrip?.id}');
    yield activeTrip;
  } catch (e) {
    developer.log(
      'realtimeActiveTripProvider: Error fetching initial active trip - $e',
      name: 'realtime_active_trip',
      error: e,
    );
    yield null;
  }

  // Subscribe to trip events and update in real-time
  await for (final event in eventService.tripEventStream) {
    switch (event.type) {
      case TripEventType.tripActivated:
        developer.log(
          'realtimeActiveTripProvider: Trip activated - ${event.trip?.id}',
          name: 'realtime_active_trip',
        );
        debugPrint(
          'realtimeActiveTripProvider: Trip activated - ${event.trip?.id}');
        yield event.trip;

      case TripEventType.tripDeactivated:
        developer.log(
          'realtimeActiveTripProvider: Trip deactivated',
          name: 'realtime_active_trip',
        );
        debugPrint(
          'realtimeActiveTripProvider: Trip deactivated - ${event.trip?.id}');
        yield null;

      case TripEventType.tripUpdated:
        // Refresh active trip on update (status might have changed)
        try {
          final updated = await tripRepository.getActiveTrip(userId);
          yield updated;
        } catch (e) {
          developer.log(
            'realtimeActiveTripProvider: Error on trip update - $e',
            name: 'realtime_active_trip',
            error: e,
          );
        }

      case TripEventType.tripDeleted:
      case TripEventType.tripCreated:
        // These don't affect the active trip display
        break;
    }
  }
});
