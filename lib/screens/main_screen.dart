import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/location_provider.dart';
import 'dart:ui';
import 'package:voyza/screens/trip_screen.dart';
import 'package:voyza/screens/map_screen.dart';
import 'package:voyza/screens/settings_screen.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // Perform initial data fetch once at startup (not in build, to avoid
    // re-running on every auth-token refresh / connectivity change).
    // After sync completes, set initialSyncCompleteProvider so the map screen
    // can hide its loading overlay once marker bitmaps are also ready.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final repository = ref.read(locationRepositoryProvider);
      await performInitialLocationSync(repository);
      if (mounted) {
        ref.read(initialSyncCompleteProvider.notifier).state = true;
      }
    });
  }

  static final List<Widget> _widgetOptions = <Widget>[
    const TripScreen(),
    const MapScreen(),
    const SettingsScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Watch the sync manager so it re-evaluates when connectivity/auth changes,
    // ensuring the realtime subscription is re-established after reconnects.
    ref.watch(syncManagerProvider);

    // Re-run the location sync whenever the user logs in mid-session.
    // currentUserIdProvider is stable across token refreshes (only changes on
    // actual login / logout), so this only fires on a real sign-in event.
    // This is necessary because initState runs once at startup; after logout
    // the Hive cache is cleared, so we must re-fetch when the user signs back in.
    ref.listen<String?>(currentUserIdProvider, (previous, next) async {
      if (previous == null && next != null) {
        ref.read(initialSyncCompleteProvider.notifier).state = false;
        final repository = ref.read(locationRepositoryProvider);
        await performInitialLocationSync(repository);
        if (mounted) {
          ref.read(initialSyncCompleteProvider.notifier).state = true;
        }
      }
    });

    return Scaffold(
      extendBody: true, // Allows body to extend behind the bottom nav
      body: IndexedStack(
        index: _selectedIndex,
        children: _widgetOptions,
      ),
      bottomNavigationBar: _buildCustomBottomNavBar(),
    );
  }

  Widget _buildCustomBottomNavBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(left: 20, right: 20, bottom: 20),
      height: 70,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(35),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.1),
            blurRadius: 20,
            offset: const Offset(0, 8),
            spreadRadius: 0,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(35),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(35),
              border: Border.all(
                color: isDark
                  ? Colors.white.withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildNavItem(0, Icons.trip_origin_outlined, Icons.trip_origin_rounded, 'Trips'),
                _buildNavItem(1, Icons.map_outlined, Icons.map_rounded, 'Map'),
                _buildNavItem(2, Icons.settings_outlined, Icons.settings_rounded,
                    'Settings'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(
      int index, IconData icon, IconData activeIcon, String label) {
    final isSelected = _selectedIndex == index;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: () => _onItemTapped(index),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: isSelected
            ? BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(25),
              )
            : BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(25),
              ),
        child: Row(
          children: [
            Icon(
              isSelected ? activeIcon : icon,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : (isDark ? Colors.white.withValues(alpha: 0.6) : Colors.black.withValues(alpha: 0.6)),
              size: 24,
            ),
            if (isSelected) ...[
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
