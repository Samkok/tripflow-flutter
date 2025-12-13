import 'dart:async';
import 'dart:developer' as developer;

import '../models/trip.dart';

/// Represents different trip-related events
enum TripEventType {
  tripActivated,
  tripDeactivated,
  tripCreated,
  tripUpdated,
  tripDeleted,
}

/// Event fired when trip status changes
class TripEvent {
  final TripEventType type;
  final Trip? trip; // null for deactivation
  final DateTime timestamp;

  TripEvent({
    required this.type,
    this.trip,
  }) : timestamp = DateTime.now();

  @override
  String toString() => 'TripEvent(type: $type, tripId: ${trip?.id}, time: $timestamp)';
}

/// Pub/Sub service for trip state changes
/// Provides centralized event streaming for trip activation/deactivation
class TripEventService {
  static final TripEventService _instance = TripEventService._internal();

  factory TripEventService() {
    return _instance;
  }

  TripEventService._internal();

  /// Stream controller for trip events
  final _tripEventController = StreamController<TripEvent>.broadcast();

  /// Get the stream of trip events
  Stream<TripEvent> get tripEventStream => _tripEventController.stream;

  /// Emit a trip event
  void emitTripEvent(TripEvent event) {
    developer.log(
      'TripEventService: Emitting event - $event',
      name: 'trip_event_service',
    );
    _tripEventController.add(event);
  }

  /// Emit trip activated event
  void notifyTripActivated(Trip trip) {
    emitTripEvent(
      TripEvent(
        type: TripEventType.tripActivated,
        trip: trip,
      ),
    );
  }

  /// Emit trip deactivated event
  void notifyTripDeactivated(String tripId) {
    emitTripEvent(
      TripEvent(
        type: TripEventType.tripDeactivated,
        trip: null,
      ),
    );
  }

  /// Emit trip created event
  void notifyTripCreated(Trip trip) {
    emitTripEvent(
      TripEvent(
        type: TripEventType.tripCreated,
        trip: trip,
      ),
    );
  }

  /// Emit trip updated event
  void notifyTripUpdated(Trip trip) {
    emitTripEvent(
      TripEvent(
        type: TripEventType.tripUpdated,
        trip: trip,
      ),
    );
  }

  /// Emit trip deleted event
  void notifyTripDeleted(String tripId) {
    emitTripEvent(
      TripEvent(
        type: TripEventType.tripDeleted,
        trip: null,
      ),
    );
  }

  /// Clear all listeners and reset state
  void dispose() {
    _tripEventController.close();
  }
}
