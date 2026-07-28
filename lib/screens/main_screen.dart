import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/onboarding_provider.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'dart:ui';
import 'package:voyza/screens/trip_screen.dart';
import 'package:voyza/screens/map_screen.dart';
import 'package:voyza/screens/settings_screen.dart';
import 'package:voyza/screens/onboarding/onboarding_screen.dart';
import 'package:voyza/widgets/analytics_consent_dialog.dart';

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
    // Anonymous users land on the MAP tab: they can't create trips, so the
    // Trips tab is a dead end for them — the map (search → add places) is
    // where their journey starts. Authenticated users keep Trips first.
    if (ref.read(currentUserIdProvider) == null) {
      _selectedIndex = 1;
    }
    // Perform initial data fetch once at startup (not in build, to avoid
    // re-running on every auth-token refresh / connectivity change).
    // After sync completes, set initialSyncCompleteProvider so the map screen
    // can hide its loading overlay once marker bitmaps are also ready.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // An ACTIVE trip means the user is mid-trip — open straight onto the
      // map where that trip lives, whatever their auth state. (Post-frame:
      // the active-trip id loads from SharedPrefsCache, which is guaranteed
      // ready by now — see the first-frame cache race note in memory.)
      if (ref.read(localActiveTripIdProvider) != null &&
          _selectedIndex != 1 &&
          mounted) {
        setState(() => _selectedIndex = 1);
      }

      // Publish the initial tab so offstage IndexedStack children (MapScreen)
      // know whether they're actually visible. Post-frame: providers must
      // not be mutated during build/init.
      ref.read(selectedTabIndexProvider.notifier).state = _selectedIndex;

      final repository = ref.read(locationRepositoryProvider);
      // Cap how long the loading overlay can block: if the fetch is slow, reveal
      // the map anyway (cached/empty) and let it populate reactively via the
      // location stream. The fetch keeps running; it just no longer holds the UI.
      try {
        await performInitialLocationSync(repository)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // Timed out or failed — map is revealed; stream fills it in when ready.
      }
      if (mounted) {
        ref.read(initialSyncCompleteProvider.notifier).state = true;
      }
      // One-time analytics consent prompt for EU/UK/CH users (no-op elsewhere).
      if (mounted) {
        await maybeShowAnalyticsConsent(context);
      }
      // One-time first-run onboarding for fresh users with zero trips
      // (no-op for everyone else). Sequenced AFTER consent so the two
      // full-screen surfaces never stack.
      if (mounted) {
        await maybeShowOnboarding(context, ref);
      }
      // Onboarding resolved (shown, skipped, or not needed) — let the map
      // tutorial re-evaluate. The anonymous flow is already ON the map tab,
      // so no tab event would otherwise fire.
      if (mounted) {
        ref.read(mapTutorialRecheckProvider.notifier).state++;
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
    ref.read(selectedTabIndexProvider.notifier).state = index;
  }

  @override
  Widget build(BuildContext context) {
    // Watch the sync manager so it re-evaluates when connectivity/auth changes,
    // ensuring the realtime subscription is re-established after reconnects.
    ref.watch(syncManagerProvider);

    // One-shot tab-switch requests (e.g. trip activated → jump to Map).
    ref.listen<int?>(mainTabRequestProvider, (prev, next) {
      if (next == null) return;
      ref.read(mainTabRequestProvider.notifier).state = null; // consume
      if (next != _selectedIndex && next >= 0 && next < _widgetOptions.length) {
        setState(() => _selectedIndex = next);
        ref.read(selectedTabIndexProvider.notifier).state = next;
      }
    });

    // Re-run the location sync whenever the user logs in mid-session.
    // currentUserIdProvider is stable across token refreshes (only changes on
    // actual login / logout), so this only fires on a real sign-in event.
    // This is necessary because initState runs once at startup; after logout
    // the Hive cache is cleared, so we must re-fetch when the user signs back in.
    ref.listen<String?>(currentUserIdProvider, (previous, next) async {
      if (previous == null && next != null) {
        ref.read(initialSyncCompleteProvider.notifier).state = false;
        final repository = ref.read(locationRepositoryProvider);
        // Same overlay cap as initState: don't let a slow fetch make the map
        // hang on "Loading…" after sign-in. Reveal it; the stream populates it.
        try {
          await performInitialLocationSync(repository)
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          // Timed out or failed — map is revealed; stream fills it in when ready.
        }
        if (mounted) {
          ref.read(initialSyncCompleteProvider.notifier).state = true;
        }
        // A user who signed up mid-session (anonymous → account) gets the
        // one-time onboarding too, once their sync has settled.
        if (mounted && context.mounted) {
          await maybeShowOnboarding(context, ref);
        }
        if (mounted) {
          ref.read(mapTutorialRecheckProvider.notifier).state++;
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
    // Add system navigation bar height so the tab bar sits above it on all
    // Android versions (gesture nav on Android 10+, 3-button nav on older).
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      margin: EdgeInsets.only(left: 20, right: 20, bottom: 20 + bottomInset),
      height: 70,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(35),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
            spreadRadius: 0,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(35),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: isDark ? 0.07 : 0.25),
              borderRadius: BorderRadius.circular(35),
              border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.1 : 0.5),
                width: 0.8,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildNavItem(0, Icons.trip_origin_outlined,
                    Icons.trip_origin_rounded, 'Trips'),
                _buildNavItem(1, Icons.map_outlined, Icons.map_rounded, 'Map'),
                _buildNavItem(2, Icons.settings_outlined,
                    Icons.settings_rounded, 'Settings'),
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
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.2),
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
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.6)
                      : Colors.black.withValues(alpha: 0.6)),
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
