import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'screens/map_screen.dart';
import 'screens/trip_history_screen.dart';
import 'core/theme.dart';

class TripFlowApp extends StatelessWidget {
  const TripFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'TripFlow',
      theme: AppTheme.darkTheme,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}

final GoRouter _router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => MapScreen(),
    ),
    GoRoute(
      path: '/history',
      builder: (context, state) => const TripHistoryScreen(),
    ),
  ],
);