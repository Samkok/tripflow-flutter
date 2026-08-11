import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/onboarding_provider.dart';
import 'dart:ui';
import 'package:voyza/screens/trip_screen.dart';
import 'package:voyza/screens/map_screen.dart';
import 'package:voyza/screens/settings_screen.dart';
import 'package:voyza/screens/onboarding/onboarding_screen.dart';
import 'package:voyza/widgets/analytics_consent_dialog.dart';
import 'package:voyza/providers/onboarding_checklist_provider.dart';
import 'package:voyza/widgets/onboarding_checklist.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  // Everyone lands on HOME (the trips page) — owner call, Aug 2026. The old
  // map-first branches (guests always; anyone with an active trip) predate
  // guests being able to create trips, and opening on the map buried the
  // trip cards that are the app's front door.
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // Perform initial data fetch once at startup (not in build, to avoid
    // re-running on every auth-token refresh / connectivity change).
    // After sync completes, set initialSyncCompleteProvider so the map screen
    // can hide its loading overlay once marker bitmaps are also ready.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
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
      // tutorial re-evaluate in case the user is already on the map tab
      // (e.g. switched there while onboarding was up).
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
    if (index == _selectedIndex) return;
    HapticFeedback.selectionClick();
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

    // Checklist completed (4/4) → celebrate once, wherever the user is.
    // MainScreen is always on stage, so a plain listen is safe here.
    ref.listen<int>(checklistCelebrationTrigger, (prev, next) {
      if (next <= (prev ?? 0)) return;
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!mounted || !context.mounted) return;
        showChecklistCompleteCelebration(context);
      });
    });

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

  // --- Floating-orb bottom nav ---------------------------------------------
  // Frosted glass pill pinned above the home indicator. The ACTIVE tab is
  // marked by a solid cyan orb that carries the tab's icon and physically
  // slides between slots with a springy overshoot; it rides slightly above
  // the pill's top edge so it reads as floating. Inactive tabs are plain
  // 60%-opacity icons with no label; only the active tab shows its label,
  // tucked under the orb.

  static const double _pillHeight = 70;
  static const double _orbSize = 52;
  // Headroom above the pill so the orb can break its top edge without being
  // clipped by the Scaffold's bottom-bar slot.
  static const double _orbLift = 8;

  static const List<({IconData icon, IconData activeIcon, String label})>
      _tabs = [
    (
      icon: Icons.route_outlined,
      activeIcon: Icons.route_rounded,
      label: 'Trips'
    ),
    (icon: Icons.map_outlined, activeIcon: Icons.map_rounded, label: 'Map'),
    (
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings_rounded,
      label: 'Settings'
    ),
  ];

  Widget _buildCustomBottomNavBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Add system navigation bar height so the tab bar sits above it on all
    // Android versions (gesture nav on Android 10+, 3-button nav on older).
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      margin: EdgeInsets.only(left: 20, right: 20, bottom: 5 + bottomInset),
      height: _pillHeight + _orbLift,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final slotWidth = constraints.maxWidth / _tabs.length;
          final orbLeft =
              slotWidth * _selectedIndex + (slotWidth - _orbSize) / 2;

          return Stack(
            children: [
              // Glass pill (identical treatment to the previous bar).
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _pillHeight,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(35),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black
                            .withValues(alpha: isDark ? 0.35 : 0.12),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(35),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white
                              .withValues(alpha: isDark ? 0.07 : 0.25),
                          borderRadius: BorderRadius.circular(35),
                          border: Border.all(
                            color: Colors.white
                                .withValues(alpha: isDark ? 0.1 : 0.5),
                            width: 0.8,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Tap slots: inactive icon + (active-only) label.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _pillHeight,
                child: Row(
                  children: [
                    for (var i = 0; i < _tabs.length; i++)
                      Expanded(child: _buildNavSlot(i)),
                  ],
                ),
              ),
              // The orb. Drawn last so it glides OVER inactive icons while in
              // flight; IgnorePointer keeps the slots tappable beneath it.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 480),
                curve: Curves.easeOutBack,
                left: orbLeft,
                top: 0,
                width: _orbSize,
                height: _orbSize,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primaryColor
                              .withValues(alpha: isDark ? 0.45 : 0.35),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Center(
                      // Crossfade the icon mid-flight when the orb changes tab.
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        switchInCurve: Curves.easeOutBack,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, animation) =>
                            ScaleTransition(
                          scale: animation,
                          child:
                              FadeTransition(opacity: animation, child: child),
                        ),
                        child: Icon(
                          _tabs[_selectedIndex].activeIcon,
                          key: ValueKey(_selectedIndex),
                          color: AppTheme.darkBackgroundColor,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildNavSlot(int index) {
    final isSelected = _selectedIndex == index;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tab = _tabs[index];

    return GestureDetector(
      onTap: () => _onItemTapped(index),
      behavior: HitTestBehavior.opaque,
      // Tight height: without it the Row centers a shrink-wrapped Stack and
      // the bottom-anchored label ends up hidden behind the orb.
      child: SizedBox(
        height: _pillHeight,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Inactive icon — fades out when the orb takes this slot.
            AnimatedOpacity(
              opacity: isSelected ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                tab.icon,
                size: 24,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.6)
                    : Colors.black.withValues(alpha: 0.6),
              ),
            ),
            // Label — active tab only, tucked under the orb.
            Positioned(
              left: 0,
              right: 0,
              bottom: 7,
              child: AnimatedOpacity(
                opacity: isSelected ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: Text(
                  tab.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.primaryColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
