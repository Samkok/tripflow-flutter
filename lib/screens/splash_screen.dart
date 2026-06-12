import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/main.dart' show Bootstrap;
import 'package:voyza/screens/main_screen.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/providers/location_provider.dart'
    show initialSyncCompleteProvider;

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Wait for the bootstrap future from main.dart (dotenv,
    // SharedPreferences, Hive, Supabase, LocationRepository). Splash is the
    // first route, so awaiting here keeps every downstream screen safe to
    // touch any of those services.
    //
    // Add a minimum delay so the logo doesn't flash on a hot restart where
    // bootstrap completes in <50ms — skipped entirely when there's no
    // cached Hive data (i.e. fresh install — bootstrap is the slow path
    // anyway).
    final minDelay = Bootstrap.hasCachedLocations
        ? Duration.zero
        : const Duration(milliseconds: 500);

    await Future.wait([
      Bootstrap.future.catchError((_) {
        // Bootstrap failed (e.g. dotenv missing, Hive corrupted beyond
        // recovery). Surface a debugPrint and proceed to navigate anyway —
        // downstream screens will show their own errors. Without this catch
        // the user is stranded on the splash forever.
      }),
      Future.delayed(minDelay),
    ]);

    if (!mounted) return;

    // Seed initialSyncCompleteProvider so the map screen's sync overlay
    // doesn't flash for returning users whose Hive cache is already
    // populated. Previously done via ProviderScope.override in main.dart,
    // but the override required Hive to be open before runApp — which is
    // the ANR-prone work we just moved AFTER runApp.
    ref.read(initialSyncCompleteProvider.notifier).state =
        Bootstrap.hasCachedLocations;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const MainScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppTheme.secondaryColor.withValues(alpha: 0.9),
              AppTheme.primaryColor.withValues(alpha: 0.9),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // App logo
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 15,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Image.asset('assets/images/logo.png'),
              ),
              const SizedBox(height: 24),
              Text(
                'VoyZa',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
