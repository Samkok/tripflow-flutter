import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:voyza/screens/splash_screen.dart';
import 'screens/main_screen.dart';

import 'core/theme.dart';
import 'providers/theme_provider.dart';

import 'widgets/connectivity_wrapper.dart';

import 'services/supabase_service.dart';
import 'repositories/location_repository.dart';

import 'package:hive_flutter/hive_flutter.dart';
import 'models/saved_location.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await SupabaseService.initialize();

  await Hive.initFlutter();
  Hive.registerAdapter(SavedLocationAdapter());

  await LocationRepository().init();

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
