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
import 'models/saved_location.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // OPTIMIZATION: Enable memory-efficient mode
  // Reduces image cache and other memory overhead
  imageCache.maximumSize = 50; // Limit to 50 images in cache
  imageCache.maximumSizeBytes = 100 * 1024 * 1024; // 100MB image cache limit

  await dotenv.load(fileName: ".env");

  // OPTIMIZATION: Initialize Hive first (fast)
  await Hive.initFlutter();
  Hive.registerAdapter(SavedLocationAdapter());

  // OPTIMIZATION: Defer Supabase initialization to avoid blocking UI
  // It will initialize on first use via lazy provider
  // SupabaseService.initialize() will be called in a background task

  // OPTIMIZATION: Defer LocationRepository initialization
  // It will be initialized on first access via provider

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

      // CRITICAL: Initialize collaborator realtime listener at app root
      // This ensures permission changes are detected and enforced immediately
      // across the entire app without requiring trip reactivation
      debugPrint('Main: Initializing collaborator realtime listener');
      ref.read(collaboratorRealtimeInitProvider);

      // CRITICAL: Wait for RevenueCat auth sync to complete
      // This ensures RevenueCat user ID is linked with Supabase auth
      // Prevents anonymous user issues when app starts with existing session
      debugPrint('Main: Waiting for RevenueCat auth sync...');
      try {
        await ref.read(revenueCatAuthSyncProvider.future);
        debugPrint('Main: RevenueCat auth sync completed successfully');
      } catch (e) {
        debugPrint('Main: RevenueCat auth sync error: $e');
        // Don't fail the whole initialization if RevenueCat sync fails
      }
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
