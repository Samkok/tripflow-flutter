import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

/// Event types for subscription changes
enum SubscriptionEventType {
  activated,
  renewed,
  expired,
  cancelled,
  billingIssue,
  updated,
}

/// Event class for subscription changes
class SubscriptionEvent {
  final SubscriptionEventType type;
  final String userId;
  final String status;
  final String entitlement;
  final DateTime? expiresAt;
  final bool willRenew;
  final String? productIdentifier;
  final String? store;
  final Map<String, dynamic>? data;

  SubscriptionEvent({
    required this.type,
    required this.userId,
    required this.status,
    required this.entitlement,
    this.expiresAt,
    required this.willRenew,
    this.productIdentifier,
    this.store,
    this.data,
  });

  @override
  String toString() {
    return 'SubscriptionEvent(type: $type, status: $status, entitlement: $entitlement, expiresAt: $expiresAt, willRenew: $willRenew)';
  }
}

/// Service for realtime subscription to subscription status changes
/// This service watches the user_subscriptions table for changes
/// and emits events when subscription status changes
class SubscriptionRealtimeService {
  static final SubscriptionRealtimeService _instance =
      SubscriptionRealtimeService._internal();
  factory SubscriptionRealtimeService() => _instance;
  SubscriptionRealtimeService._internal();

  final SupabaseClient _supabase = SupabaseService.instance.client;

  final _eventController = StreamController<SubscriptionEvent>.broadcast();
  Stream<SubscriptionEvent> get eventStream => _eventController.stream;

  RealtimeChannel? _channel;
  bool _isSubscribed = false;

  int _authRetryCount = 0;
  static const int _maxAuthRetries = 5;
  static const Duration _authRetryDelay = Duration(seconds: 3);

  /// Subscribe to subscription changes for the current user
  Future<void> subscribe() async {
    if (_isSubscribed) {
      debugPrint('SubscriptionRealtimeService: Already subscribed, skipping');
      return;
    }

    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      debugPrint('SubscriptionRealtimeService: ⚠️ No user logged in');
      // CRITICAL FIX: On iOS, auth may not be ready yet when this is called.
      // Retry with backoff instead of silently giving up.
      if (_authRetryCount < _maxAuthRetries) {
        _authRetryCount++;
        debugPrint(
            'SubscriptionRealtimeService: 🔄 Will retry auth check in ${_authRetryDelay.inSeconds}s (attempt $_authRetryCount/$_maxAuthRetries)');
        Future.delayed(_authRetryDelay, () => subscribe());
      } else {
        debugPrint(
            'SubscriptionRealtimeService: ❌ Max auth retries reached, giving up');
      }
      return;
    }
    _authRetryCount = 0; // Reset on success

    // Drop any stale (errored/closed) channel before building a new one so
    // reconnect attempts don't stack dead channel objects on the same topic.
    _removeStaleChannel();

    debugPrint(
        'SubscriptionRealtimeService: 🔔 Starting subscription for user $userId');

    try {
      _channel = _supabase
          .channel('subscription_changes_$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'user_subscriptions',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (payload) {
              debugPrint(
                  'SubscriptionRealtimeService: 📨 Received ${payload.eventType} event');
              debugPrint(
                  'SubscriptionRealtimeService: 📨 New: ${payload.newRecord}');
              debugPrint(
                  'SubscriptionRealtimeService: 📨 Old: ${payload.oldRecord}');
              _handleChange(payload);
            },
          )
          .subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          debugPrint(
              'SubscriptionRealtimeService: ✅ Successfully subscribed to realtime updates');
          _isSubscribed = true;
        } else if (status == RealtimeSubscribeStatus.channelError) {
          debugPrint(
              'SubscriptionRealtimeService: ❌ Channel error during subscription');
          _isSubscribed = false;
          _scheduleReconnect();
        } else if (status == RealtimeSubscribeStatus.timedOut) {
          debugPrint('SubscriptionRealtimeService: ⏱️ Subscription timed out');
          _isSubscribed = false;
          _scheduleReconnect();
        } else if (status == RealtimeSubscribeStatus.closed) {
          debugPrint('SubscriptionRealtimeService: 🔒 Channel closed');
          _isSubscribed = false;
          // Closed also fires on intentional unsubscribe — only
          // reconnect when the server/socket closed us.
          if (!_teardownInProgress) _scheduleReconnect();
        } else {
          debugPrint('SubscriptionRealtimeService: ℹ️ Status: $status');
        }

        if (error != null) {
          debugPrint(
              'SubscriptionRealtimeService: ❌ Subscription error: $error');
          _isSubscribed = false;
          _scheduleReconnect();
        }
      });
    } catch (e, stackTrace) {
      debugPrint(
          'SubscriptionRealtimeService: ❌ Exception during subscription: $e');
      debugPrint('SubscriptionRealtimeService: Stack trace: $stackTrace');
      _isSubscribed = false;
      _scheduleReconnect();
    }
  }

  /// Schedule automatic reconnection after connection loss
  Timer? _reconnectTimer;
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      debugPrint('SubscriptionRealtimeService: 🔄 Attempting to reconnect...');
      subscribe();
    });
  }

  /// True while an intentional channel teardown is in flight, so the
  /// resulting `closed` status doesn't trigger a reconnect.
  bool _teardownInProgress = false;

  /// Asynchronously removes a dead channel object; errors are swallowed
  /// (the socket may already be gone).
  void _removeStaleChannel() {
    final stale = _channel;
    _channel = null;
    if (stale == null) return;
    _teardownInProgress = true;
    unawaited(() async {
      try {
        await _supabase.removeChannel(stale);
      } catch (_) {
        // Already gone.
      } finally {
        _teardownInProgress = false;
      }
    }());
  }

  void _handleChange(PostgresChangePayload payload) {
    try {
      final eventType = payload.eventType;
      final newRecord = payload.newRecord;
      final oldRecord = payload.oldRecord;

      SubscriptionEvent? event;

      switch (eventType) {
        case PostgresChangeEvent.insert:
          if (newRecord.isNotEmpty) {
            event = _createEventFromRecord(newRecord, oldRecord);
          }
          break;
        case PostgresChangeEvent.update:
          if (newRecord.isNotEmpty) {
            event = _createEventFromRecord(newRecord, oldRecord);
          }
          break;
        case PostgresChangeEvent.delete:
          if (oldRecord.isNotEmpty) {
            // Subscription deleted (rare, but handle it)
            event = SubscriptionEvent(
              type: SubscriptionEventType.expired,
              userId: oldRecord['user_id'] as String,
              status: 'expired',
              entitlement: oldRecord['entitlement'] as String,
              willRenew: false,
              data: oldRecord,
            );
          }
          break;
        default:
          break;
      }

      if (event != null) {
        debugPrint('SubscriptionRealtimeService: ✨ Emitting event - $event');
        _eventController.add(event);
      }
    } catch (e, stackTrace) {
      debugPrint('SubscriptionRealtimeService: ❌ Error handling change - $e');
      debugPrint('SubscriptionRealtimeService: Stack trace: $stackTrace');
    }
  }

  /// Create a SubscriptionEvent from a database record
  SubscriptionEvent _createEventFromRecord(
    Map<String, dynamic> newRecord,
    Map<String, dynamic> oldRecord,
  ) {
    final status = newRecord['status'] as String;
    final oldStatus =
        oldRecord.isNotEmpty ? oldRecord['status'] as String? : null;

    // Determine event type based on status transition
    SubscriptionEventType eventType;
    if (oldStatus == null || oldStatus == 'expired' && status == 'active') {
      eventType = SubscriptionEventType.activated;
    } else if (status == 'active' && oldStatus == 'active') {
      eventType = SubscriptionEventType.renewed;
    } else if (status == 'expired') {
      eventType = SubscriptionEventType.expired;
    } else if (status == 'cancelled') {
      eventType = SubscriptionEventType.cancelled;
    } else if (status == 'billing_retry' || status == 'grace_period') {
      eventType = SubscriptionEventType.billingIssue;
    } else {
      eventType = SubscriptionEventType.updated;
    }

    // Parse expiration timestamp
    DateTime? expiresAt;
    final expiresAtStr = newRecord['expires_at'] as String?;
    if (expiresAtStr != null) {
      try {
        expiresAt = DateTime.parse(expiresAtStr);
      } catch (e) {
        debugPrint(
            'SubscriptionRealtimeService: Failed to parse expires_at: $e');
      }
    }

    return SubscriptionEvent(
      type: eventType,
      userId: newRecord['user_id'] as String,
      status: status,
      entitlement: newRecord['entitlement'] as String,
      expiresAt: expiresAt,
      willRenew: newRecord['will_renew'] as bool,
      productIdentifier: newRecord['product_identifier'] as String?,
      store: newRecord['store'] as String?,
      data: newRecord,
    );
  }

  /// Force resubscribe - unsubscribes and resubscribes with fresh auth
  /// Useful when auth state changes after initial subscription attempt
  Future<void> resubscribe() async {
    debugPrint(
        'SubscriptionRealtimeService: 🔄 Resubscribing with fresh auth...');
    _authRetryCount = 0;
    unsubscribe();
    await subscribe();
  }

  /// Unsubscribe from subscription changes
  void unsubscribe() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_channel == null && !_isSubscribed) return;

    debugPrint(
        'SubscriptionRealtimeService: 🔕 Unsubscribing from subscription changes');
    _removeStaleChannel();
    _isSubscribed = false;
  }

  /// Dispose the service
  void dispose() {
    unsubscribe();
    _eventController.close();
  }
}
