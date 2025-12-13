import 'dart:developer' as developer;
import '../models/trip.dart';
import '../repositories/trip_repository.dart';
import '../services/trip_event_service.dart';

/// Wrapper around TripRepository that emits events to TripEventService
/// This ensures that all trip state changes are published to subscribers
class TripRepositoryWithEvents {
  final TripRepository _repository;
  final TripEventService _eventService;

  TripRepositoryWithEvents({
    required TripRepository repository,
    required TripEventService eventService,
  })  : _repository = repository,
        _eventService = eventService;

  /// Create a new trip and emit event
  Future<Trip> createTrip({
    required String userId,
    required String name,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final trip = await _repository.createTrip(
        userId: userId,
        name: name,
        description: description,
        startDate: startDate,
        endDate: endDate,
      );
      
      developer.log(
        'TripRepositoryWithEvents: Trip created - ${trip.id}',
        name: 'trip_repository_events',
      );
      
      _eventService.notifyTripCreated(trip);
      return trip;
    } catch (e) {
      developer.log(
        'TripRepositoryWithEvents: Error creating trip - $e',
        name: 'trip_repository_events',
        error: e,
      );
      rethrow;
    }
  }

  /// Get all trips for a user
  Future<List<Trip>> getUserTrips(String userId) async {
    return _repository.getUserTrips(userId);
  }

  /// Get active trip for a user
  Future<Trip?> getActiveTrip(String userId) async {
    return _repository.getActiveTrip(userId);
  }

  /// Set a trip as active and emit event
  /// This is the PRIMARY method that triggers activation events
  Future<Trip> setActiveTrip(String userId, String tripId) async {
    try {
      final trip = await _repository.setActiveTrip(userId, tripId);
      
      developer.log(
        'TripRepositoryWithEvents: Trip activated - ${trip.id}',
        name: 'trip_repository_events',
      );
      
      // CRITICAL: Emit activation event for UI to listen to
      _eventService.notifyTripActivated(trip);
      return trip;
    } catch (e) {
      developer.log(
        'TripRepositoryWithEvents: Error activating trip - $e',
        name: 'trip_repository_events',
        error: e,
      );
      rethrow;
    }
  }

  /// Deactivate the active trip and emit event
  /// This is the PRIMARY method that triggers deactivation events
  Future<Trip> deactivateTrip(String tripId) async {
    try {
      final trip = await _repository.deactivateTrip(tripId);
      
      developer.log(
        'TripRepositoryWithEvents: Trip deactivated - ${trip.id}',
        name: 'trip_repository_events',
      );
      
      // CRITICAL: Emit deactivation event for UI to listen to
      _eventService.notifyTripDeactivated(trip.id);
      return trip;
    } catch (e) {
      developer.log(
        'TripRepositoryWithEvents: Error deactivating trip - $e',
        name: 'trip_repository_events',
        error: e,
      );
      rethrow;
    }
  }

  /// Update trip and emit event
  Future<Trip> updateTrip(
    String tripId, {
    String? name,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
    double? totalDistance,
    int? totalDurationMinutes,
  }) async {
    try {
      final trip = await _repository.updateTrip(
        tripId,
        name: name,
        description: description,
        startDate: startDate,
        endDate: endDate,
        totalDistance: totalDistance,
        totalDurationMinutes: totalDurationMinutes,
      );
      
      developer.log(
        'TripRepositoryWithEvents: Trip updated - ${trip.id}',
        name: 'trip_repository_events',
      );
      
      _eventService.notifyTripUpdated(trip);
      return trip;
    } catch (e) {
      developer.log(
        'TripRepositoryWithEvents: Error updating trip - $e',
        name: 'trip_repository_events',
        error: e,
      );
      rethrow;
    }
  }

  /// Delete a trip and emit event
  Future<void> deleteTrip(String tripId) async {
    try {
      await _repository.deleteTrip(tripId);
      
      developer.log(
        'TripRepositoryWithEvents: Trip deleted - $tripId',
        name: 'trip_repository_events',
      );
      
      _eventService.notifyTripDeleted(tripId);
    } catch (e) {
      developer.log(
        'TripRepositoryWithEvents: Error deleting trip - $e',
        name: 'trip_repository_events',
        error: e,
      );
      rethrow;
    }
  }
}
