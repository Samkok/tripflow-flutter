import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:voyza/screens/splash_screen.dart';
import 'screens/main_screen.dart';

import 'core/theme.dart';
import 'providers/theme_provider.dart';
import 'providers/trip_collaborator_provider.dart';
import 'providers/subscription_provider.dart';
import 'providers/auth_provider.dart';

import 'widgets/connectivity_wrapper.dart';
import 'widgets/subscription_conflict_banner.dart';

import 'services/supabase_service.dart';
import 'services/revenuecat_service.dart';
import 'repositories/location_repository.dart';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/saved_location.dart';

/// PERFORMANCE: Global SharedPreferences cache to avoid repeated getInstance() calls
/// Pre-initialized in main() before any provider accesses it
class SharedPrefsCache {
  static SharedPreferences? _instance;
  static SharedPreferences get instance {
    assert(_instance != null, 'SharedPrefsCache not initialized. Call main() first.');
    return _instance!;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // OPTIMIZATION: Enable memory-efficient mode
  // Reduces image cache and other memory overhead
  imageCache.maximumSize = 50; // Limit to 50 images in cache
  imageCache.maximumSizeBytes = 100 * 1024 * 1024; // 100MB image cache limit

  await dotenv.load(fileName: ".env");

  // PERFORMANCE: Pre-initialize SharedPreferences once for all providers
  // This prevents multiple blocking getInstance() calls during startup
  final prefs = await SharedPreferences.getInstance();
  SharedPrefsCache._instance = prefs;

  // OPTIMIZATION: Initialize Hive first (fast)
  await Hive.initFlutter();
  Hive.registerAdapter(SavedLocationAdapter());

  runApp(const ProviderScope(child: MyApp()));

  // OPTIMIZATION: Initialize heavy services in the background after app render
  _initializeHeavyServices();
}

/// Initialize heavy services after the app has rendered
/// This prevents blocking the UI during startup
void _initializeHeavyServices() {
  Future.delayed(const Duration(milliseconds: 100), () async {
    try {
      debugPrint('Main: Initializing Supabase...');
      await SupabaseService.initialize();
      debugPrint('Main: Supabase initialized');

      debugPrint('Main: Initializing LocationRepository...');
      await LocationRepository().init();
      debugPrint('Main: LocationRepository initialized');

      // Initialize RevenueCat for subscription management
      debugPrint('Main: Initializing RevenueCat...');
      await RevenueCatService.initialize();
      debugPrint('Main: RevenueCat initialized');
    } catch (e) {
      debugPrint('Main: Error initializing heavy services: $e');
    }
  });
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
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

      // PERFORMANCE: Defer collaborator realtime to let UI render first
      // Initialize after a short delay so it doesn't compete with initial frame
      debugPrint('Main: Deferring collaborator realtime listener...');
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          ref.read(collaboratorRealtimeInitProvider.notifier).ensureInitialized();
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
          debugPrint('Main: Subscription realtime listener initialized (fallback after auth sync error)');
        }
      });

      // SAFETY NET: If RevenueCat auth sync hangs (common on iOS),
      // force-initialize subscription after 10 seconds regardless
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted) {
          ref.read(subscriptionProvider.notifier).ensureInitialized();
          debugPrint('Main: Subscription realtime listener initialized (timeout fallback)');
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
      debugShowCheckedModeBanner: false,
      title: 'VoyZa',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      builder: (context, child) {
        return Column(
          children: [
            const SubscriptionConflictBanner(),
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
