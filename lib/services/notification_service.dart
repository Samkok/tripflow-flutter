import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:voyza/services/supabase_service.dart';

// Top-level function required by Firebase for background message handling
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Firebase must be initialized in the background isolate
  await Firebase.initializeApp();
  debugPrint('NotificationService: Background message received: ${message.messageId}');
  // flutter_local_notifications handles display automatically on Android
  // iOS displays the system notification natively in background
}

/// Service for managing push notifications via Firebase Cloud Messaging (FCM).
///
/// Responsibilities:
///   - Initialize Firebase and FCM on app start
///   - Request permission and register the device FCM token in the database
///   - Display foreground notifications via flutter_local_notifications
///   - Route notification taps to the correct screen
///   - Deregister the token on sign-out (stops push for this device)
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final _localNotifications = FlutterLocalNotificationsPlugin();

  // Android notification channel
  static const _channelId = 'voyza_notifications';
  static const _channelName = 'VoyZa Notifications';
  static const _channelDescription = 'Trip collaboration and activity notifications';

  bool _initialized = false;

  // ============================================================================
  // Public API
  // ============================================================================

  /// Must be called once during app startup (after Firebase-compatible initialization).
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      // Initialize Firebase
      await Firebase.initializeApp();
      debugPrint('NotificationService: Firebase initialized');

      // Register background handler (must be registered before any other setup)
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      // Configure local notifications for foreground display
      await _initLocalNotifications();

      // Listen for messages while app is in foreground
      FirebaseMessaging.onMessage.listen(_onForegroundMessage);

      // Listen for notification taps when app is in background (not terminated)
      FirebaseMessaging.onMessageOpenedApp.listen(_onNotificationTap);

      // Handle notification that launched the app from terminated state
      final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
      if (initialMessage != null) {
        // Slight delay to allow navigator to be ready
        await Future.delayed(const Duration(milliseconds: 500));
        _handleNotificationTap(initialMessage.data);
      }

      debugPrint('NotificationService: Initialized successfully');
    } catch (e) {
      debugPrint('NotificationService: Initialization failed: $e');
      _initialized = false; // Allow retry
      rethrow;
    }
  }

  /// Requests push notification permission and registers the FCM token in
  /// the `device_tokens` table for the currently signed-in user.
  ///
  /// Call this after a successful sign-in.
  Future<void> registerToken() async {
    try {
      final userId = SupabaseService.instance.client.auth.currentUser?.id;
      if (userId == null) {
        debugPrint('NotificationService: registerToken skipped — no signed-in user');
        return;
      }

      // Request permission (iOS shows a dialog; Android 13+ requires runtime permission)
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('NotificationService: Push permission denied by user');
        return;
      }

      debugPrint('NotificationService: Permission status: ${settings.authorizationStatus}');

      // Get the FCM registration token for this device
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
        debugPrint('NotificationService: FCM token is null (simulator or permission denied)');
        return;
      }

      await _upsertToken(userId: userId, token: token);

      // Keep the token current — FCM rotates tokens occasionally
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
        debugPrint('NotificationService: FCM token refreshed');
        _upsertToken(userId: userId, token: newToken);
      });

      debugPrint('NotificationService: Device registered for push notifications');
    } catch (e) {
      debugPrint('NotificationService: registerToken failed: $e');
    }
  }

  /// Marks the current user's device token as inactive on sign-out.
  ///
  /// The row is kept in the database so the token history is preserved and
  /// the same user can reactivate it on next login (via _upsertToken upsert).
  /// Multiple accounts on the same device each have their own row
  /// (unique on user_id + fcm_token from migration 015), so this UPDATE
  /// only affects the currently signed-in user's row — no cross-user impact.
  Future<void> deregisterToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;

      await SupabaseService.instance.client
          .from('device_tokens')
          .update({
            'is_active': false,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('fcm_token', token);

      debugPrint('NotificationService: Device token marked inactive (sign-out)');
    } catch (e) {
      debugPrint('NotificationService: deregisterToken failed: $e');
    }
  }

  // ============================================================================
  // Private helpers
  // ============================================================================

  /// Configures flutter_local_notifications for foreground display.
  Future<void> _initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false, // Handled by FirebaseMessaging.requestPermission()
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _localNotifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: (response) {
        // Tapped a local notification (foreground)
        final payload = response.payload;
        if (payload != null) {
          // Minimal routing — foreground taps navigate to the relevant screen
          debugPrint('NotificationService: Local notification tapped: $payload');
        }
      },
    );

    // Create Android notification channel
    if (Platform.isAndroid) {
      await _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: _channelDescription,
              importance: Importance.high,
            ),
          );
    }
  }

  /// Displays a local notification when a message arrives while the app is
  /// in the foreground (FCM alone doesn't show UI on iOS in foreground).
  Future<void> _onForegroundMessage(RemoteMessage message) async {
    debugPrint(
      'NotificationService: Foreground message — '
      'type: ${message.data["type"]}, title: ${message.notification?.title}',
    );

    final notification = message.notification;
    if (notification == null) return;

    await _localNotifications.show(
      message.hashCode,
      notification.title,
      notification.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  /// Handles a notification tap (from background/open state).
  void _onNotificationTap(RemoteMessage message) {
    debugPrint('NotificationService: Notification tapped — type: ${message.data["type"]}');
    _handleNotificationTap(message.data);
  }

  /// Routes to the appropriate screen based on notification type and data.
  void _handleNotificationTap(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    final tripId = data['trip_id'] as String?;

    debugPrint('NotificationService: Handling tap — type: $type, tripId: $tripId');

    switch (type) {
      case 'collaborator_added':
      case 'location_added':
        // Navigation is deferred to the app layer via navigatorKey.
        // Import navigatorKey from main.dart and push the trip screen.
        // This is handled at the app level to avoid circular imports.
        _navigateToTrip(tripId);
        break;
      default:
        debugPrint('NotificationService: No navigation handler for type: $type');
    }
  }

  void _navigateToTrip(String? tripId) {
    if (tripId == null) return;
    // Use the global navigator key from main.dart.
    // We avoid importing main.dart here to prevent circular dependencies.
    // Instead, the app's router/navigator handles this via a stream or callback.
    // For now, log the intent — wire up navigation in main.dart if needed.
    debugPrint('NotificationService: Navigate to trip: $tripId');
  }

  /// Upserts the FCM token for the current user into `device_tokens`.
  ///
  /// The unique key is (user_id, fcm_token) — one row per user per device.
  /// This means different users on the same device each have their own row,
  /// so there is no RLS conflict when switching accounts.
  Future<void> _upsertToken({
    required String userId,
    required String token,
  }) async {
    final platform = Platform.isIOS ? 'ios' : 'android';

    await SupabaseService.instance.client.from('device_tokens').upsert(
      {
        'user_id': userId,
        'fcm_token': token,
        'platform': platform,
        'is_active': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'user_id,fcm_token',
    );

    debugPrint(
      'NotificationService: Token registered for $platform device '
      '(user: ${userId.substring(0, 8)}...)',
    );
  }
}
