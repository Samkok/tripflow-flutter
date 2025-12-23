import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

/// Event types for collaborator changes
enum CollaboratorEventType {
  added,
  updated,
  removed,
}

/// Event class for collaborator changes
class CollaboratorEvent {
  final CollaboratorEventType type;
  final String tripId;
  final String? collaboratorId;
  final String? userId;
  final String? permission;
  final Map<String, dynamic>? data;

  CollaboratorEvent({
    required this.type,
    required this.tripId,
    this.collaboratorId,
    this.userId,
    this.permission,
    this.data,
  });

  @override
  String toString() {
    return 'CollaboratorEvent(type: $type, tripId: $tripId, userId: $userId, permission: $permission)';
  }
}

/// Service for realtime subscription to collaborator changes
/// This service watches the trip_collaborators table for changes
/// and emits events when collaborators are added, updated, or removed
class CollaboratorRealtimeService {
  static final CollaboratorRealtimeService _instance =
      CollaboratorRealtimeService._internal();
  factory CollaboratorRealtimeService() => _instance;
  CollaboratorRealtimeService._internal();

  final SupabaseClient _supabase = SupabaseService.instance.client;

  final _eventController = StreamController<CollaboratorEvent>.broadcast();
  Stream<CollaboratorEvent> get eventStream => _eventController.stream;

  RealtimeChannel? _channel;
  bool _isSubscribed = false;

  /// Subscribe to collaborator changes for the current user
  void subscribe() {
    if (_isSubscribed) {
      debugPrint('CollaboratorRealtimeService: Already subscribed, skipping');
      return;
    }

    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      debugPrint('CollaboratorRealtimeService: ⚠️ No user logged in, skipping subscription');
      return;
    }

    debugPrint('CollaboratorRealtimeService: 🔔 Starting subscription for user $userId');

    try {
      _channel = _supabase
          .channel('collaborator_changes_$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'trip_collaborators',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (payload) {
              debugPrint('CollaboratorRealtimeService: 📨 Received ${payload.eventType} event');
              debugPrint('CollaboratorRealtimeService: 📨 New: ${payload.newRecord}');
              debugPrint('CollaboratorRealtimeService: 📨 Old: ${payload.oldRecord}');
              _handleChange(payload);
            },
          )
          .subscribe((status, error) {
            if (status == RealtimeSubscribeStatus.subscribed) {
              debugPrint('CollaboratorRealtimeService: ✅ Successfully subscribed to realtime updates');
              _isSubscribed = true;
            } else if (status == RealtimeSubscribeStatus.channelError) {
              debugPrint('CollaboratorRealtimeService: ❌ Channel error during subscription');
              _isSubscribed = false;
            } else if (status == RealtimeSubscribeStatus.timedOut) {
              debugPrint('CollaboratorRealtimeService: ⏱️ Subscription timed out');
              _isSubscribed = false;
            } else if (status == RealtimeSubscribeStatus.closed) {
              debugPrint('CollaboratorRealtimeService: 🔒 Channel closed');
              _isSubscribed = false;
            } else {
              debugPrint('CollaboratorRealtimeService: ℹ️ Status: $status');
            }

            if (error != null) {
              debugPrint('CollaboratorRealtimeService: ❌ Subscription error: $error');
              _isSubscribed = false;
            }
          });
    } catch (e, stackTrace) {
      debugPrint('CollaboratorRealtimeService: ❌ Exception during subscription: $e');
      debugPrint('CollaboratorRealtimeService: Stack trace: $stackTrace');
      _isSubscribed = false;
    }
  }

  void _handleChange(PostgresChangePayload payload) {
    try {
      final eventType = payload.eventType;
      final newRecord = payload.newRecord;
      final oldRecord = payload.oldRecord;

      CollaboratorEvent? event;

      switch (eventType) {
        case PostgresChangeEvent.insert:
          if (newRecord.isNotEmpty) {
            event = CollaboratorEvent(
              type: CollaboratorEventType.added,
              tripId: newRecord['trip_id'] as String,
              collaboratorId: newRecord['id'] as String,
              userId: newRecord['user_id'] as String,
              permission: newRecord['permission'] as String?,
              data: newRecord,
            );
          }
          break;
        case PostgresChangeEvent.update:
          if (newRecord.isNotEmpty) {
            event = CollaboratorEvent(
              type: CollaboratorEventType.updated,
              tripId: newRecord['trip_id'] as String,
              collaboratorId: newRecord['id'] as String,
              userId: newRecord['user_id'] as String,
              permission: newRecord['permission'] as String?,
              data: newRecord,
            );
          }
          break;
        case PostgresChangeEvent.delete:
          if (oldRecord.isNotEmpty) {
            event = CollaboratorEvent(
              type: CollaboratorEventType.removed,
              tripId: oldRecord['trip_id'] as String,
              collaboratorId: oldRecord['id'] as String?,
              userId: oldRecord['user_id'] as String?,
              data: oldRecord,
            );
          }
          break;
        default:
          break;
      }

      if (event != null) {
        debugPrint('CollaboratorRealtimeService: Emitting event - $event');
        _eventController.add(event);
      }
    } catch (e) {
      debugPrint('CollaboratorRealtimeService: Error handling change - $e');
    }
  }

  /// Unsubscribe from collaborator changes
  void unsubscribe() {
    if (!_isSubscribed) return;

    debugPrint('CollaboratorRealtimeService: Unsubscribing from collaborator changes');
    _channel?.unsubscribe();
    _channel = null;
    _isSubscribed = false;
  }

  /// Dispose the service
  void dispose() {
    unsubscribe();
    _eventController.close();
  }
}
