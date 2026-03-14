import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/screens/main_screen.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/providers/location_provider.dart' show initialSyncCompleteProvider;
import 'package:voyza/services/supabase_service.dart';

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
    // If Hive cache already has locations (e.g. restart after permission change),
    // skip the minimum splash delay so the app feels instant.
    final hasCachedData = ref.read(initialSyncCompleteProvider);
    final minDelay = hasCachedData
        ? Duration.zero
        : const Duration(milliseconds: 500);

    // Wait for Supabase to finish initializing before navigating.
    // On slow Android devices the async init in main.dart can take >500ms,
    // causing a "No host specified in URI" error if the user reaches auth screens first.
    await Future.wait([
      SupabaseService.waitForInitialization(),
      Future.delayed(minDelay),
    ]);

    // Navigate to the home screen
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const MainScreen()),
      );
    }
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
