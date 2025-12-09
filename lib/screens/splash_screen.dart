import 'dart:async';
import 'package:flutter/material.dart';
import 'package:voyza/screens/main_screen.dart';
import 'package:voyza/services/marker_cache_service.dart';
import 'package:voyza/core/theme.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Start all initialization tasks in parallel
    final tasks = [
      // Pre-warm the entire marker cache for a smoother map experience.
      MarkerCacheService().prewarmCache(),

      // Wait for a minimum duration to show the splash screen
      Future.delayed(const Duration(seconds: 3)),
    ];

    // Wait for all tasks to complete
    await Future.wait(tasks);

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
