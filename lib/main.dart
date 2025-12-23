import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:voyza/screens/splash_screen.dart';
import 'screens/main_screen.dart';

import 'core/theme.dart';
import 'providers/theme_provider.dart';
import 'providers/trip_collaborator_provider.dart';

import 'widgets/connectivity_wrapper.dart';

import 'services/supabase_service.dart';
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
      await SupabaseService.initialize();
      await LocationRepository().init();
    } catch (e) {
      print('Error initializing heavy services: $e');
    }
  });
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  @override
  void initState() {
    super.initState();
    _initializeCollaboratorListener();
  }

  /// Initialize collaborator listener after Supabase is ready
  Future<void> _initializeCollaboratorListener() async {
    try {
      // Wait for Supabase to be initialized before starting realtime subscriptions
      await SupabaseService.waitForInitialization();

      if (mounted) {
        // CRITICAL: Initialize collaborator realtime listener at app root
        // This ensures permission changes are detected and enforced immediately
        // across the entire app without requiring trip reactivation
        ref.read(collaboratorRealtimeInitProvider);
      }
    } catch (e) {
      // If Supabase initialization fails, log but don't crash the app
      print('Failed to initialize collaborator listener: $e');
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
        return ConnectivityWrapper(child: child!);
      },
      home: const SplashScreen(),
      routes: {
        '/home': (context) => const MainScreen(),
        '/home_anonymous': (context) => const MainScreen(),
      },
    );
  }
}
