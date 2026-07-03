import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyza/screens/splash_screen.dart';
import 'package:voyza/screens/reset_password_screen.dart';
import 'package:voyza/screens/login_screen.dart';
import 'screens/main_screen.dart';

import 'core/theme.dart';
import 'providers/theme_provider.dart';
import 'providers/trip_collaborator_provider.dart';
import 'providers/subscription_provider.dart';
import 'providers/auth_provider.dart';

import 'widgets/connectivity_wrapper.dart';
import 'widgets/subscription_conflict_banner.dart';
import 'widgets/trial_countdown_banner.dart';

import 'services/supabase_service.dart';
import 'services/revenuecat_service.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';
import 'services/referral_service.dart';
import 'services/review_prompt_service.dart';
import 'services/analytics_consent_service.dart';
import 'repositories/location_repository.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/saved_location.dart';
import 'dart:async';

/// PERFORMANCE: Global SharedPreferences cache to avoid repeated getInstance() calls
/// Populated by [_bootstrap] before [SplashScreen] navigates away.
class SharedPrefsCache {
  static SharedPreferences? _instance;
  static SharedPreferences get instance {
    assert(_instance != null,
        'SharedPrefsCache not initialized. Wait on Bootstrap.future first.');
    return _instance!;
  }

  /// Non-throwing accessor for the rare caller that can legitimately run
  /// BEFORE [_bootstrap] has populated the cache — notably [ThemeNotifier],
  /// which is constructed during the very first frame's [MyApp.build] (a
  /// `Timer.run` macrotask scheduled by `runApp`) that can win the race
  /// against the `SharedPreferences.getInstance()` platform-channel round
  /// trip inside [_initSharedPrefs]. Returns null until the cache is ready;
  /// callers should fall back to a default and re-read after
  /// [Bootstrap.future] completes.
  static SharedPreferences? get maybeInstance => _instance;

  /// True once [_initSharedPrefs] has populated the cache.
  static bool get isReady => _instance != null;
}

/// ANR-driven startup model.
///
/// Before this refactor, `main()` awaited dotenv / SharedPreferences / Hive
/// init / Hive box open BEFORE calling runApp(), then `_initializeHeavyServices`
/// fired Supabase / RevenueCat / Firebase 100 ms after first paint. On a slow
/// device or first cold start the pre-runApp file-I/O could exceed Android's
/// 5 s "Input dispatching timed out (No focused window)" budget, and the 100 ms
/// post-runApp delay still landed RevenueCat's billing handshake on the
/// critical first-frames thread.
///
/// New model:
///   1. `main()` only ensures the binding and calls runApp() — the Android
///      Activity gets a focused window in the very first frame, before any
///      file I/O. SplashScreen renders immediately.
///   2. [_bootstrap] fires as fire-and-forget right after runApp and does
///      all the heavy startup work, completing [Bootstrap.future] when done.
///   3. [SplashScreen] awaits [Bootstrap.future] before navigating into the
///      app, so dependent surfaces (Supabase auth, Hive-backed providers)
///      see a ready system.
///   4. RevenueCat — whose `Purchases.configure` call binds to Google Play
///      Billing and is the reported ANR source — is scheduled past the FIRST
///      painted frame at idle priority via [_scheduleAfterFirstFrame], not
///      a fixed delay.
///   5. NotificationService no longer initialises at app start; AuthService
///      lazy-inits it on first sign-in via `NotificationService().registerToken`.
class Bootstrap {
  Bootstrap._();

  static final Completer<void> _completer = Completer<void>();
  static bool _hasCachedLocations = false;

  /// Resolves when Hive, SharedPreferences, Supabase, and LocationRepository
  /// are all ready. SplashScreen awaits this before navigating into the app.
  static Future<void> get future => _completer.future;

  /// True when the Hive `locations` box already had cached rows at startup —
  /// lets SplashScreen / MainScreen mark the sync overlay complete without
  /// re-fetching.
  static bool get hasCachedLocations => _hasCachedLocations;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // OPTIMIZATION: Enable memory-efficient mode
  // Reduces image cache and other memory overhead
  imageCache.maximumSize = 50; // Limit to 50 images in cache
  imageCache.maximumSizeBytes = 100 * 1024 * 1024; // 100MB image cache limit

  runApp(const ProviderScope(child: MyApp()));

  // Fire-and-forget heavy bootstrap. SplashScreen waits on its completer.
  _bootstrap();
}

/// Heavy startup. Runs after [runApp] so the Android activity already has
/// a focused window — preventing the input-dispatcher ANR cluster reported
/// from Play Store.
Future<void> _bootstrap() async {
  try {
    // Parallelise the independent file-I/O awaits. dotenv reads from
    // bundled assets, SharedPreferences hits NSUserDefaults / Android prefs,
    // and Hive.initFlutter sets up its native channel — none of these
    // depend on each other, so running them concurrently typically
    // halves cold-start file-I/O wall time.
    await Future.wait([
      dotenv.load(fileName: '.env'),
      _initSharedPrefs(),
      Hive.initFlutter().then((_) {
        // OpeningPeriod must register before SavedLocation: SavedLocation
        // rows reference OpeningPeriod values, and Hive throws on unknown
        // typeIds while decoding nested fields.
        Hive.registerAdapter(OpeningPeriodAdapter());
        Hive.registerAdapter(SavedLocationAdapter());
      }),
    ]);

    // Count this launch as a session for the review-prompt engagement gate.
    // SharedPreferences is ready after the Future.wait above; fire-and-forget.
    unawaited(ReviewPromptService.instance.recordSession());

    // Open the locations box AFTER Hive.initFlutter + registerAdapter. This
    // exposes [Bootstrap.hasCachedLocations] for the splash skip-delay
    // optimisation. A corrupted box doesn't fail bootstrap — the repository's
    // own recovery path will reopen it later.
    try {
      final box = await Hive.openBox<SavedLocation>('locations');
      Bootstrap._hasCachedLocations = box.isNotEmpty;
    } catch (_) {
      // Corrupted box — LocationRepository._ensureInitialized handles recovery.
    }

    debugPrint('Main: Initializing Supabase...');
    await SupabaseService.initialize();
    debugPrint('Main: Supabase initialized');

    // If the user opted out of "Remember Me", sign them out even if Supabase
    // restored a session from native storage.
    final rememberMe = await AuthService.getRememberMe();
    if (!rememberMe) {
      final client = SupabaseService.instance.client;
      if (client.auth.currentUser != null) {
        await client.auth.signOut();
        debugPrint('Main: Remember Me is OFF — signed out restored session');
      }
    }

    debugPrint('Main: Initializing LocationRepository...');
    await LocationRepository().init();
    debugPrint('Main: LocationRepository initialized');

    if (!Bootstrap._completer.isCompleted) {
      Bootstrap._completer.complete();
    }
    debugPrint('Main: Bootstrap complete — splash can navigate');

    // Initialise Firebase core only — separate from NotificationService.
    //
    // Reason: Firebase Performance Monitoring (added in pubspec for ANR /
    // cold-start telemetry) auto-instruments as soon as Firebase is up.
    // If we kept Firebase init fully lazy until first sign-in, anonymous
    // sessions wouldn't be measured — and most of the Play Store ANR
    // reports were on unauthenticated cold starts. We pay the small Firebase
    // SDK init cost at idle (post-frame) to unlock the monitoring without
    // pulling in FirebaseMessaging or fetching the FCM token here. That
    // heavy work still happens lazily inside NotificationService.initialize
    // when the user actually signs in (or via the restored-session branch
    // scheduled below).
    //
    // Firebase.initializeApp is idempotent — NotificationService.initialize
    // can call it again later without issue.
    _scheduleAfterFirstFrame(() async {
      try {
        debugPrint('Main: Initializing Firebase core (post-frame idle)...');
        await Firebase.initializeApp();
        debugPrint('Main: Firebase core initialized');
        // Apply analytics consent state (EU/UK/CH default OFF until opt-in).
        await AnalyticsConsentService.instance.applyAtStartup();
        // Link Firebase App Instance ID → RevenueCat so the RC↔Firebase
        // integration attributes server events to the same GA user.
        unawaited(RevenueCatService().linkFirebaseAppInstanceId());
      } catch (e) {
        debugPrint('Main: Firebase core init failed (non-fatal): $e');
      }
    });

    // Defer RevenueCat past the first painted frame at idle priority. The
    // `Purchases.configure` call inside the SDK synchronously triggers
    // `BillingWrapper.buildClient` on Android, which binds to Google Play
    // Services — historically a multi-second hang on cold launch. By waiting
    // for the first frame AND the scheduler to be idle, we keep that work
    // off the critical-startup frames entirely.
    //
    // Consumers that need RevenueCat (paywall, subscription provider) call
    // `await RevenueCatService.waitForInitialization()` and so will simply
    // suspend until this completes — no API change required.
    _scheduleAfterFirstFrame(() async {
      try {
        debugPrint('Main: Initializing RevenueCat (post-frame idle)...');
        await RevenueCatService.initialize();
        debugPrint('Main: RevenueCat initialized');
      } catch (e) {
        debugPrint('Main: RevenueCat init failed (non-fatal): $e');
      }
    });

    // NotificationService is intentionally NOT initialised here. Push only
    // matters for signed-in users, and lazily initialising it inside
    // `AuthService.signIn` removed the Firebase/FCM startup hop from the
    // Play Store ANR cluster.
    //
    // For RESTORED sessions (user already signed in from a previous
    // launch), we still need to re-register the FCM token so collab
    // pushes keep landing. Schedule it past the first painted frame at
    // idle so Firebase init doesn't compete with the first-frame work.
    // registerToken() is idempotent and itself lazy-inits Firebase, so
    // the cold-start hop is fully off the critical thread.
    _scheduleAfterFirstFrame(() async {
      final client = SupabaseService.instance.client;
      if (client.auth.currentUser == null) return;
      try {
        debugPrint('Main: Registering FCM for restored session (idle)...');
        await NotificationService().registerToken();
        debugPrint('Main: Restored-session FCM registration done');
      } catch (e) {
        debugPrint('Main: Restored-session FCM registration failed: $e');
      }
    });
  } catch (e, st) {
    debugPrint('Main: bootstrap failed: $e\n$st');
    if (!Bootstrap._completer.isCompleted) {
      Bootstrap._completer.completeError(e, st);
    }
  }
}

Future<void> _initSharedPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  SharedPrefsCache._instance = prefs;
}

/// Schedules [work] to run AFTER the first frame has painted, at idle
/// scheduler priority. Use for any expensive init that doesn't need to be
/// ready by the time the user first sees the app.
void _scheduleAfterFirstFrame(FutureOr<void> Function() work) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    SchedulerBinding.instance.scheduleTask<void>(work, Priority.idle);
  });
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // CRITICAL: Initialize RevenueCat auth sync early
    // This must happen as soon as possible after widget initialization
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeCollaboratorListener();
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // Refresh subscription when app comes to foreground
    if (state == AppLifecycleState.resumed) {
      debugPrint('App resumed - refreshing subscription status');
      _refreshSubscriptionOnResume();
    }
  }

  /// Refresh subscription status when app resumes
  Future<void> _refreshSubscriptionOnResume() async {
    try {
      // Wait for RevenueCat to be initialized
      await RevenueCatService.waitForInitialization();

      if (mounted) {
        // Import subscription provider
        final subscriptionNotifier = ref.read(subscriptionProvider.notifier);
        await subscriptionNotifier.refresh();
        debugPrint('Subscription refreshed on app resume');
      }
    } catch (e) {
      debugPrint('Failed to refresh subscription on resume: $e');
    }
  }

  /// Initialize collaborator listener after Supabase is ready
  Future<void> _initializeCollaboratorListener() async {
    try {
      debugPrint('Main: Starting _initializeCollaboratorListener');

      // Wait for Supabase to be initialized before starting realtime subscriptions
      debugPrint('Main: Waiting for Supabase initialization...');
      await SupabaseService.waitForInitialization();
      debugPrint('Main: Supabase is ready');

      if (!mounted) {
        debugPrint('Main: Widget not mounted, aborting initialization');
        return;
      }

      // Listen for auth state changes (password recovery deep links + forced sign-outs)
      _authSubscription =
          SupabaseService.instance.client.auth.onAuthStateChange.listen(
        (data) {
          if (data.event == AuthChangeEvent.passwordRecovery) {
            debugPrint(
                'Main: passwordRecovery event — navigating to ResetPasswordScreen');
            navigatorKey.currentState?.push(
              MaterialPageRoute(builder: (_) => const ResetPasswordScreen()),
            );
          } else if (data.event == AuthChangeEvent.signedOut) {
            // Fired when this device's session is revoked remotely (e.g. password
            // changed on another device and "sign out others" was chosen), or when
            // the refresh token expires. Push LoginScreen and clear the back stack
            // so the user cannot navigate back into the app.
            debugPrint('Main: signedOut event — redirecting to LoginScreen');
            navigatorKey.currentState?.pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
              (_) => false,
            );
          } else if (data.event == AuthChangeEvent.signedIn) {
            // Referral: a code entered at signup is saved locally (no session
            // exists until the email is verified) — redeem it on the first
            // verified sign-in. Idempotent + no-op without a pending code.
            unawaited(ReferralService.instance.redeemPendingCodeIfAny());
            // Collaboration invites: auto-join any trips this email was
            // invited to (as a non-user) + reward both sides. Idempotent.
            unawaited(ReferralService.instance.claimInvites());
          }
        },
      );

      // Covers the "verified earlier, app relaunched with a live session"
      // path where no signedIn event fires this run.
      if (SupabaseService.instance.client.auth.currentSession != null) {
        unawaited(ReferralService.instance.redeemPendingCodeIfAny());
        unawaited(ReferralService.instance.claimInvites());
      }

      // PERFORMANCE: Defer collaborator realtime to let UI render first
      // Initialize after a short delay so it doesn't compete with initial frame
      debugPrint('Main: Deferring collaborator realtime listener...');
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          ref
              .read(collaboratorRealtimeInitProvider.notifier)
              .ensureInitialized();
          debugPrint('Main: Collaborator realtime listener initialized');
        }
      });

      // PERFORMANCE: Trigger RevenueCat auth sync in background without blocking
      // This ensures RevenueCat user ID is linked with Supabase auth
      // but doesn't block app startup
      debugPrint('Main: Triggering RevenueCat auth sync in background...');
      ref.read(revenueCatAuthSyncProvider.future).then((_) {
        debugPrint('Main: RevenueCat auth sync completed successfully');

        // Now that auth is synced, initialize subscription realtime listener
        // This must happen AFTER RevenueCat user ID is linked to Supabase auth
        // so the realtime filter matches the correct user_id
        if (mounted) {
          ref.read(subscriptionProvider.notifier).ensureInitialized();
          debugPrint('Main: Subscription realtime listener initialized');
        }
      }).catchError((e) {
        debugPrint('Main: RevenueCat auth sync error: $e');
        // CRITICAL FIX: Still initialize subscription even if RevenueCat sync fails
        // On iOS, auth sync can fail/timeout but Supabase auth may still be valid
        // Without this, the realtime listener never starts
        if (mounted) {
          ref.read(subscriptionProvider.notifier).ensureInitialized();
          debugPrint(
              'Main: Subscription realtime listener initialized (fallback after auth sync error)');
        }
      });

      // SAFETY NET: If RevenueCat auth sync hangs (common on iOS),
      // force-initialize subscription after 10 seconds regardless
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted) {
          ref.read(subscriptionProvider.notifier).ensureInitialized();
          debugPrint(
              'Main: Subscription realtime listener initialized (timeout fallback)');
        }
      });
    } catch (e, stack) {
      // If Supabase initialization fails, log but don't crash the app
      debugPrint('Main: Failed to initialize collaborator listener: $e');
      debugPrint('Main: Stack trace: $stack');
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeProvider);

    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'VoyZa',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      builder: (context, child) {
        return Column(
          children: [
            const SubscriptionConflictBanner(),
            const TrialCountdownBanner(),
            Expanded(
              child: ConnectivityWrapper(child: child!),
            ),
          ],
        );
      },
      home: const SplashScreen(),
      routes: {
        '/home': (context) => const MainScreen(),
        '/home_anonymous': (context) => const MainScreen(),
      },
    );
  }
}
