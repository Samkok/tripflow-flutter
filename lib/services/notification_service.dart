import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/services/supabase_service.dart';

// Top-level function required by Firebase for background message handling.
//
// Runs in a SEPARATE background isolate spawned by the platform — not the
// foreground engine. Any exception escaping this function gets surfaced to
// Crashlytics as `DartMessenger$Reply.reply IllegalStateException` because
// the FCM plugin's underlying MethodChannel reply pipe can be torn down
// before this handler returns. Wrap everything in try/catch so the plugin
// channel reply path stays clean.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    // Firebase must be initialized in the background isolate
    await Firebase.initializeApp();
    debugPrint(
        'NotificationService: Background message received: ${message.messageId}');
    // flutter_local_notifications handles display automatically on Android
    // iOS displays the system notification natively in background
  } catch (e) {
    // Swallow to prevent the FCM channel from reporting an IllegalStateException
    // on reply. Foreground init will recover on next app launch.
    debugPrint('NotificationService: Background handler error: $e');
  }
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
  static const _channelDescription =
      'Trip collaboration and activity notifications';

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
      FirebaseMessaging.onBackgroundMessage(
          _firebaseMessagingBackgroundHandler);

      // Configure local notifications for foreground display
      await _initLocalNotifications();

      // Listen for messages while app is in foreground
      FirebaseMessaging.onMessage.listen(_onForegroundMessage);

      // Listen for notification taps when app is in background (not terminated)
      FirebaseMessaging.onMessageOpenedApp.listen(_onNotificationTap);

      // Handle notification that launched the app from terminated state
      final initialMessage =
          await FirebaseMessaging.instance.getInitialMessage();
      if (initialMessage != null) {
        // Slight delay to allow navigator to be ready
        await Future.delayed(const Duration(milliseconds: 500));
        _handleNotificationTap(initialMessage.data);
      }

      debugPrint('NotificationService: Initialized successfully');

      // If a user session is already active (app restart / session restore),
      // re-register the token so device_tokens stays active and the
      // onTokenRefresh listener is set up for this session.
      final alreadySignedIn =
          SupabaseService.instance.client.auth.currentUser != null;
      if (alreadySignedIn) {
        // Fire-and-forget — don't block initialization
        registerToken().catchError((e) {
          debugPrint(
              'NotificationService: registerToken on restart failed: $e');
        });
      }
    } catch (e) {
      debugPrint('NotificationService: Initialization failed: $e');
      _initialized = false; // Allow retry
      rethrow;
    }
  }

  /// SharedPreferences flag: have we ever shown the OS notification prompt?
  /// Push only matters once you're signed in (collab invites, trip activity),
  /// so the prompt fires on the FIRST sign-in and never again on its own —
  /// later sign-ins and restored sessions just reuse whatever the user chose.
  /// Settings → Notifications still lets them turn it on explicitly.
  static const _kNotifPromptShown = 'notif_permission_prompted_v1';

  /// Registers the FCM token for the signed-in user.
  ///
  /// [allowPrompt] permits showing the OS permission dialog — pass true ONLY
  /// from a real sign-in. Restored sessions pass false so a returning user
  /// isn't re-prompted at launch.
  Future<void> registerToken({bool allowPrompt = false}) async {
    try {
      if (!_initialized) await initialize();

      final userId = SupabaseService.instance.client.auth.currentUser?.id;
      if (userId == null) {
        debugPrint(
            'NotificationService: registerToken skipped — no signed-in user');
        return;
      }

      // SharedPreferences directly (not SharedPrefsCache) — this service
      // never imports main.dart, see the circular-dependency note below.
      final prefs = await SharedPreferences.getInstance();
      final alreadyPrompted = prefs.getBool(_kNotifPromptShown) ?? false;

      final NotificationSettings settings;
      if (allowPrompt && !alreadyPrompted) {
        // First sign-in on this device: ask (iOS dialog; Android 13+ runtime).
        settings = await FirebaseMessaging.instance.requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );
        await prefs.setBool(_kNotifPromptShown, true);
      } else {
        // Never re-prompt on our own — just read what the user already chose.
        settings = await FirebaseMessaging.instance.getNotificationSettings();
      }

      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        debugPrint('NotificationService: Push not authorized '
            '(${settings.authorizationStatus}) — skipping token registration');
        return;
      }

      debugPrint(
          'NotificationService: Permission status: ${settings.authorizationStatus}');

      // Get the FCM registration token for this device
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
        debugPrint(
            'NotificationService: FCM token is null (simulator or permission denied)');
        return;
      }

      await _upsertToken(userId: userId, token: token);

      // Keep the token current — FCM rotates tokens occasionally.
      // Guarded with try/catch because this listener fires for the lifetime
      // of the app, including during engine teardown (e.g. hot restart on
      // dev, OS-driven activity recreation). Without the guard, an
      // _upsertToken throw during teardown surfaces as
      // DartMessenger$Reply.reply IllegalStateException in Crashlytics.
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        try {
          debugPrint('NotificationService: FCM token refreshed');
          await _upsertToken(userId: userId, token: newToken);
        } catch (e) {
          debugPrint('NotificationService: onTokenRefresh handler failed: $e');
        }
      });

      debugPrint(
          'NotificationService: Device registered for push notifications');
    } catch (e) {
      debugPrint('NotificationService: registerToken failed: $e');
    }
  }

  static const _prefKey = 'notifications_enabled';

  /// Returns the user-stored notification preference (defaults to true).
  Future<bool> getPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKey) ?? true;
  }

  /// Returns whether the OS has granted notification permission.
  Future<bool> isSystemPermissionGranted() async {
    if (!_initialized) await initialize();
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  /// Enables notifications: requests OS permission if needed, then registers
  /// the FCM token. Returns true if permission was granted, false if denied.
  Future<bool> enableNotifications() async {
    if (!_initialized) await initialize();
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    final granted =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional;

    if (granted) {
      await registerToken();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, granted);
    // The user has now seen the OS prompt (from Settings), so a later first
    // sign-in shouldn't try to raise it again.
    await prefs.setBool(_kNotifPromptShown, true);
    return granted;
  }

  /// Disables notifications: deregisters the FCM token and stores preference.
  Future<void> disableNotifications() async {
    await deregisterToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, false);
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

      await SupabaseService.instance.client.from('device_tokens').update({
        'is_active': false,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('fcm_token', token);

      debugPrint(
          'NotificationService: Device token marked inactive (sign-out)');
    } catch (e) {
      debugPrint('NotificationService: deregisterToken failed: $e');
    }
  }

  // ============================================================================
  // Private helpers
  // ============================================================================

  /// Configures flutter_local_notifications for foreground display.
  Future<void> _initLocalNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission:
          false, // Handled by FirebaseMessaging.requestPermission()
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
          debugPrint(
              'NotificationService: Local notification tapped: $payload');
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
    debugPrint(
        'NotificationService: Notification tapped — type: ${message.data["type"]}');
    _handleNotificationTap(message.data);
  }

  /// Routes to the appropriate screen based on notification type and data.
  void _handleNotificationTap(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    final tripId = data['trip_id'] as String?;
    final locationId = data['location_id'] as String?;

    debugPrint(
        'NotificationService: Handling tap — type: $type, tripId: $tripId');

    switch (type) {
      case 'collaborator_added':
      case 'location_added':
        _requestOpenTrip(tripId, locationId);
        break;
      default:
        debugPrint(
            'NotificationService: No navigation handler for type: $type');
    }
  }

  /// Set by the app layer (main.dart) once the navigator exists. Kept as a
  /// callback so this service never imports main.dart (circular dependency).
  /// [locationId] is non-null for location_added taps — the details screen
  /// opens that location's detail sheet on arrival.
  static void Function(String tripId, String? locationId)? onOpenTripRequest;

  /// A tap that arrived before the app layer registered its callback
  /// (terminated-state launch). Consumed by [consumePendingOpenTrip].
  static ({String tripId, String? locationId})? _pendingOpenTrip;

  void _requestOpenTrip(String? tripId, String? locationId) {
    if (tripId == null) return;
    final cb = onOpenTripRequest;
    if (cb != null) {
      cb(tripId, locationId);
    } else {
      debugPrint(
          'NotificationService: Navigator not ready — buffering trip open');
      _pendingOpenTrip = (tripId: tripId, locationId: locationId);
    }
  }

  /// Called by the app layer right after registering [onOpenTripRequest] to
  /// replay a tap that launched the app from the terminated state.
  static void consumePendingOpenTrip() {
    final pending = _pendingOpenTrip;
    final cb = onOpenTripRequest;
    if (pending != null && cb != null) {
      _pendingOpenTrip = null;
      cb(pending.tripId, pending.locationId);
    }
  }

  /// Registers or reactivates the FCM token for the current user.
  ///
  /// Uses SELECT → UPDATE/INSERT rather than upsert(onConflict:...) because
  /// PostgreSQL validates the ON CONFLICT target against existing constraints
  /// even when no conflict occurs — meaning if the expected unique constraint
  /// is absent the entire query fails silently. This explicit approach works
  /// regardless of which DB constraints are in place.
  ///
  /// Scenarios handled:
  ///   • Same user, same device (re-login)   → UPDATE is_active = true
  ///   • Same user, new device               → INSERT new row
  ///   • Different user, same physical device → INSERT new row (different user_id)
  Future<void> _upsertToken({
    required String userId,
    required String token,
  }) async {
    final platform = Platform.isIOS ? 'ios' : 'android';
    final now = DateTime.now().toUtc().toIso8601String();
    final supabase = SupabaseService.instance.client;

    // Check if this exact (user, device) pair already has a row
    final existing = await supabase
        .from('device_tokens')
        .select('id')
        .eq('user_id', userId)
        .eq('fcm_token', token)
        .maybeSingle();

    if (existing != null) {
      // Same user, same device — reactivate the existing row
      await supabase
          .from('device_tokens')
          .update({'is_active': true, 'updated_at': now})
          .eq('user_id', userId)
          .eq('fcm_token', token);
      debugPrint(
        'NotificationService: Token reactivated for $platform device '
        '(user: ${userId.substring(0, 8)}...)',
      );
    } else {
      // New device or new user on this device — insert a fresh row
      await supabase.from('device_tokens').insert({
        'user_id': userId,
        'fcm_token': token,
        'platform': platform,
        'is_active': true,
        'updated_at': now,
      });
      debugPrint(
        'NotificationService: Token registered for $platform device '
        '(user: ${userId.substring(0, 8)}...)',
      );
    }
  }
}
