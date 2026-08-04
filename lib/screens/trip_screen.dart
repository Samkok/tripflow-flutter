import 'dart:ui' show ImageFilter;

import 'package:voyza/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:uuid/uuid.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/all_days_route_provider.dart';
import 'package:voyza/providers/onboarding_provider.dart';
import 'package:voyza/screens/login_screen.dart';
import 'package:voyza/screens/trip_details_screen.dart';
import 'package:voyza/services/analytics_service.dart';
import 'package:voyza/services/anonymous_user_service.dart';
import 'package:voyza/services/route_share_card_service.dart';
import 'package:voyza/services/time_saved_ledger_service.dart';
import 'package:voyza/widgets/celebration_dialogs.dart';
import 'package:voyza/utils/countries.dart';
import 'package:voyza/utils/trip_date_validator.dart';
import 'package:voyza/widgets/app_toast.dart';
import 'package:voyza/widgets/country_flag_icon.dart';
import 'package:voyza/utils/same_day_place_guard.dart';
import 'package:voyza/utils/trip_dates.dart';
import 'package:voyza/widgets/country_picker_sheet.dart';
import 'package:voyza/widgets/pulsing_glow.dart';
import 'package:voyza/screens/create_trip_wizard.dart';
import 'package:voyza/widgets/referral_prompt.dart';
import 'package:voyza/widgets/rotating_globe_background.dart';
import 'package:voyza/widgets/trip_collaborators_row.dart';
import 'package:voyza/widgets/trip_skeleton.dart';

class TripScreen extends ConsumerStatefulWidget {
  const TripScreen({super.key});

  @override
  ConsumerState<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends ConsumerState<TripScreen> {
  bool _creatingSampleTrip = false;

  // Drives the scroll-to-top after activating a trip, so the Active Trip
  // section (pinned at the top) is immediately in view.
  final ScrollController _tripsScrollController = ScrollController();

  // Multi-select state
  bool _selectionMode = false;
  final Set<String> _selectedTripIds = {};

  @override
  void dispose() {
    _tripsScrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Post-trip recap: check once per launch, after the first frame + a
    // settle delay so it never races onboarding or the map tutorial.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 3), _maybeShowTripRecap);
    });
  }

  /// Shows the one-time "trip, by the numbers" recap for a trip that ended
  /// 1–3 days ago (mirrors the trip-date-nudges post_trip window — the T+1
  /// push brings the user back; this dialog is what they land on). One trip
  /// per launch; each trip only ever recaps once (SharedPreferences flag).
  Future<void> _maybeShowTripRecap() async {
    try {
      if (!mounted) return;
      final userId = ref.read(currentUserIdProvider);
      if (userId == null) return; // trips (and their dates) are authed-only
      final trips = await ref.read(userTripsProvider.future);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      for (final trip in trips) {
        final end = trip.endDate;
        if (end == null) continue;
        final endDay = DateTime(end.year, end.month, end.day);
        final daysSinceEnd = today.difference(endDay).inDays;
        if (daysSinceEnd < 1 || daysSinceEnd > 3) continue;

        final prefs = await SharedPreferences.getInstance();
        final shownKey = 'trip_recap_shown_${trip.id}';
        if (prefs.getBool(shownKey) ?? false) continue;

        // The trip's places (all saved, incl. done/skipped — it's a recap).
        final locationsAsync = ref.read(savedLocationsProvider);
        final places = locationsAsync.maybeWhen(
          data: (all) => all.where((l) => l.tripId == trip.id).length,
          orElse: () => 0,
        );
        if (places == 0) continue; // nothing to recap

        final start = trip.startDate;
        final days = start != null
            ? endDay
                    .difference(DateTime(start.year, start.month, start.day))
                    .inDays +
                1
            : 1;
        final saved =
            await TimeSavedLedgerService.instance.totalForTrip(trip.id);

        await prefs.setBool(shownKey, true);
        if (!mounted) return;
        AnalyticsService.instance.tripRecapShown();
        await showTripRecapDialog(
          context,
          tripName: trip.name,
          days: days < 1 ? 1 : days,
          places: places,
          timeSaved: saved,
          onShare: () => RouteShareCardService.instance.shareRecapCard(
            tripName: trip.name,
            days: days < 1 ? 1 : days,
            places: places,
            timeSaved: saved,
            anonymous: false,
            tripId: trip.id,
          ),
        );
        return; // at most one recap per launch
      }
    } catch (e) {
      debugPrint('TripScreen._maybeShowTripRecap: $e');
    }
  }

  void _showLoginRequiredModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: AppTheme.sheetBarrierColor(context),
      // Same glass as the trip plan / search / collaborators sheets — all
      // four read their blur + fill from AppTheme.sheet*.
      builder: (_) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(
              sigmaX: AppTheme.sheetBlurSigma, sigmaY: AppTheme.sheetBlurSigma),
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .scaffoldBackgroundColor
                  .withValues(alpha: AppTheme.sheetFillAlpha(context)),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(
                color: AppTheme.sheetBorderColor(context),
                width: 0.8,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.lock_outline_rounded,
                    size: 40,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Sign in to Create Trips',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'You need to be signed in to create and manage trips.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.color
                            ?.withValues(alpha: 0.6),
                      ),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LoginScreen(),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Sign In',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                      'Not now',
                      style: TextStyle(
                        color: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.color
                            ?.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openCreateWizard() {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) {
      _showLoginRequiredModal(context);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CreateTripWizard()),
    );
  }

  /// Activation stays on the current screen — the active card's "Go to map"
  /// button is the explicit way over to the Map tab.
  Future<void> _setActiveTrip(Trip trip) async {
    try {
      // Clear cached locations on the map before activating a new trip
      ref.read(tripProvider.notifier).clearTrip();

      // Set active trip locally (no database update)
      await ref.read(localActiveTripIdProvider.notifier).setActiveTrip(trip.id);

      if (mounted) {
        AppToast.success(context, '${trip.name} is now active');
        // Bring the Active Trip section (top of the page) into view so the
        // just-activated trip is immediately visible and actionable.
        if (_tripsScrollController.hasClients) {
          _tripsScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
          );
        }
      }
    } catch (e) {
      debugPrint('Error setting active trip: $e');
      if (mounted) {
        AppToast.error(context, 'Could not activate trip. Please try again.');
      }
    }
  }

  /// "Go to map" on the active trip card: pre-select the trip's first day
  /// (when it has dates) so the map opens on day one, then jump tabs.
  void _goToMapForTrip(Trip trip) {
    final start = trip.startDate;
    if (start != null) {
      ref.read(allDaysModeProvider.notifier).state = false;
      ref.read(selectedDateProvider.notifier).state =
          DateTime(start.year, start.month, start.day);
      // Nudge the trip sheet onto the "Selected Day" toggle so the landing
      // actually shows day one (the toggle otherwise keeps its last state).
      ref.read(mapDayFocusRequestProvider.notifier).state++;
    }
    ref.read(mainTabRequestProvider.notifier).state = 1; // Map tab
  }

  /// Activation lever: drops the user into a pre-built, editable sample trip
  /// (Lisbon, 5 stops) so they can tap Optimize and reach the route "aha" in
  /// one tap — without forcing demo data on everyone. Fully editable/deletable.
  Future<void> _createSampleTrip() async {
    // Re-entrancy guard: reachable from both the empty-state button and the
    // onboarding trigger; a double-fire would create two demo trips.
    if (_creatingSampleTrip) return;
    _creatingSampleTrip = true;
    try {
      await _createSampleTripInner();
    } finally {
      _creatingSampleTrip = false;
    }
  }

  Future<void> _createSampleTripInner() async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) {
      // Anonymous: no Supabase trip. Seed trip-less LOCAL places instead so the
      // user reaches the optimize aha in one tap (see _seedAnonymousSampleTrip).
      await _seedAnonymousSampleTrip();
      return;
    }
    try {
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day);
      final tripRepository = ref.read(tripRepositoryProvider);
      final locationRepository = ref.read(locationRepositoryProvider);

      final trip = await tripRepository.createTrip(
        userId: userId,
        name: 'Lisbon — sample trip ✨',
        description: 'A demo trip so you can see route optimization in action. '
            'Delete it anytime to free up your free places.',
        countryCode: 'PT',
        startDate: day,
        endDate: day,
      );

      // Real Lisbon spots, intentionally out of geographic order so Optimize
      // visibly reorders them. (name, lat, lng)
      //
      // Exactly 5 — the sample writes straight to the repository (bypassing
      // the LocationAddService gate), so it must not exceed
      // SubscriptionLimitService.freePlaceAllowance or a brand-new free user
      // would be over their allowance the moment they tap the demo.
      const places = <(String, double, double)>[
        ('Time Out Market', 38.7067, -9.1459),
        ('Belém Tower', 38.6916, -9.2160),
        ('São Jorge Castle', 38.7139, -9.1335),
        ('Jerónimos Monastery', 38.6979, -9.2065),
        ('Praça do Comércio', 38.7077, -9.1366),
      ];
      const uuid = Uuid();
      for (final p in places) {
        await locationRepository.addLocation(SavedLocation(
          id: uuid.v4(),
          userId: '', // repository fills from auth state
          name: p.$1,
          lat: p.$2,
          lng: p.$3,
          createdAt: DateTime.now(),
          fingerprint: '', // repository fills
          tripId: trip.id,
          scheduledDate: day,
          stayDuration: 60,
        ));
      }

      ref.invalidate(userTripsProvider);
      AnalyticsService.instance.tripCreated();
      AnalyticsService.instance
          .sampleTripSeeded(anonymous: false, placeCount: places.length);
      if (!mounted) return;
      await _setActiveTrip(trip);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => TripDetailsScreen(trip: trip)),
      );
    } catch (e) {
      debugPrint('Error creating sample trip: $e');
      if (mounted) {
        AppToast.error(
          context,
          'Could not create the sample trip. Please try again.',
        );
      }
    }
  }

  /// Anonymous variant of [_createSampleTripInner]: seeds the same demo places
  /// as trip-less LOCAL locations (no account, no Supabase, no network) so an
  /// anonymous user reaches the optimize "aha" in one tap. The places render on
  /// the Map tab; Optimize runs purely on the in-memory list. On signup they
  /// sync to the new account like any other local place.
  Future<void> _seedAnonymousSampleTrip() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final anonId = await AnonymousUserService.id;
      final seededKey = 'sample_seeded_$anonId';
      // Idempotency: the sample CTA is reachable from BOTH onboarding and the
      // Trips empty state. Re-seeding would push the user to 8/5 places and slam
      // them into the paywall on their next add, so seed at most once per device.
      if (prefs.getBool(seededKey) ?? false) {
        ref.read(mainTabRequestProvider.notifier).state = 1; // Map tab
        return;
      }

      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day);
      final locationRepository = ref.read(locationRepositoryProvider);

      // Same Lisbon spots as the authed sample, but 4 (not 5): these local rows
      // count toward SubscriptionLimitService.freePlaceAllowance (5), so seeding
      // 4 leaves one free slot before the paywall. Still > the aha threshold, so
      // Optimize visibly reorders them.
      const places = <(String, double, double)>[
        ('Time Out Market', 38.7067, -9.1459),
        ('Belém Tower', 38.6916, -9.2160),
        ('São Jorge Castle', 38.7139, -9.1335),
        ('Jerónimos Monastery', 38.6979, -9.2065),
      ];
      const uuid = Uuid();
      for (final p in places) {
        // tripId: null → trip-less. locationRepository.addLocation forks on auth
        // state: for anon it writes to the local Hive box (source 'local',
        // userId = AnonymousUserService.id) and skips Supabase entirely.
        await locationRepository.addLocation(SavedLocation(
          id: uuid.v4(),
          userId: '', // repository fills from anon id
          name: p.$1,
          lat: p.$2,
          lng: p.$3,
          createdAt: DateTime.now(),
          fingerprint: '', // repository fills
          tripId: null,
          scheduledDate: day,
          stayDuration: 60,
        ));
      }

      await prefs.setBool(seededKey, true);
      AnalyticsService.instance
          .sampleTripSeeded(anonymous: true, placeCount: places.length);
      if (!mounted) return;
      // Land on the Map tab; the seeded local places render there and the
      // Optimize button lights up once the list is picked up.
      ref.read(mainTabRequestProvider.notifier).state = 1;
    } catch (e) {
      debugPrint('Error seeding anonymous sample trip: $e');
      if (mounted) {
        AppToast.error(
          context,
          'Could not set up the sample trip. Please try again.',
        );
      }
    }
  }

  Future<void> _deleteTrip(Trip trip, {bool deleteLocations = false}) async {
    try {
      final locationRepository = ref.read(locationRepositoryProvider);
      final tripRepository = ref.read(tripRepositoryProvider);

      if (deleteLocations) {
        // Delete locations first while we can still filter by trip_id.
        // Once the trip row is gone, ON DELETE SET NULL fires and the trip_id
        // reference is lost.
        await locationRepository.deleteLocationsByTripId(trip.id);
      }

      await tripRepository.deleteTrip(trip.id);
      ref.invalidate(userTripsProvider);

      if (mounted) {
        AppToast.success(
          context,
          deleteLocations
              ? 'Trip and its locations deleted'
              : 'Trip deleted. Locations kept.',
        );
      }
    } catch (e) {
      debugPrint('Error deleting trip: $e');
      if (mounted) {
        AppToast.error(
          context,
          'Could not delete trip. Please check your connection and try again.',
        );
      }
    }
  }

  void _enterSelectionMode(String tripId) {
    setState(() {
      _selectionMode = true;
      _selectedTripIds.add(tripId);
    });
  }

  void _toggleSelection(String tripId) {
    setState(() {
      if (_selectedTripIds.contains(tripId)) {
        _selectedTripIds.remove(tripId);
        if (_selectedTripIds.isEmpty) _selectionMode = false;
      } else {
        _selectedTripIds.add(tripId);
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedTripIds.clear();
    });
  }

  void _selectAll(List<Trip> trips) {
    setState(() => _selectedTripIds.addAll(trips.map((t) => t.id)));
  }

  void _deselectAll() {
    setState(() => _selectedTripIds.clear());
  }

  Future<void> _refreshTrips() async {
    // Invalidate all trip-related providers to trigger refresh
    ref.invalidate(userTripsProvider);
    ref.invalidate(localActiveTripProvider);
    ref.invalidate(sharedTripsProvider);

    // Fetch remote locations to ensure location counts are accurate
    try {
      final locationRepository = ref.read(locationRepositoryProvider);
      await locationRepository.fetchRemoteLocations();
      debugPrint('TripScreen: Refreshed remote locations');
    } catch (e) {
      debugPrint('TripScreen: Error refreshing locations: $e');
    }

    // Wait a bit for the providers to refresh
    await Future.delayed(const Duration(milliseconds: 500));
  }

  @override
  Widget build(BuildContext context) {
    // Note: Collaborator realtime listener is now initialized at app root (main.dart)
    // No need to initialize it here anymore

    // Onboarding hand-offs. TripScreen lives in MainScreen's IndexedStack, so
    // it's alive and listening when the onboarding route pops.
    ref.listen<String?>(tripFormPrefillProvider, (prev, code) {
      if (code == null) return;
      ref.read(tripFormPrefillProvider.notifier).state = null; // consume
      // Same auth gate as the New Trip button — without it a signed-out
      // user could fill all four wizard steps and only learn at Confirm.
      if (ref.read(currentUserIdProvider) == null) {
        _showLoginRequiredModal(context);
        return;
      }
      // '' = "start without a country" (user skipped the question) — the
      // wizard shows its country step either way so they can revise.
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CreateTripWizard(initialCountryCode: code),
        ),
      );
    });
    ref.listen<int>(sampleTripRequestProvider, (prev, next) {
      if (prev == next) return;
      _createSampleTrip();
    });

    final tripsAsync = ref.watch(userTripsProvider);
    final activeTripAsync = ref.watch(localActiveTripProvider);
    final sharedTripsAsync = ref.watch(sharedTripsProvider);

    final ownedTrips = tripsAsync.asData?.value ?? [];
    final allSelected = ownedTrips.isNotEmpty &&
        ownedTrips.every((t) => _selectedTripIds.contains(t.id));

    // Build the selected trips list for bulk actions
    final selectedTrips =
        ownedTrips.where((t) => _selectedTripIds.contains(t.id)).toList();

    // The active trip is pulled OUT of the lists below and pinned in its own
    // "Active Trip" section at the top.
    final activeTrip = activeTripAsync.valueOrNull;
    final activeTripId = activeTrip?.id;
    final hideYourTripsHeader =
        ownedTrips.isNotEmpty && ownedTrips.every((t) => t.id == activeTripId);

    return Scaffold(
      bottomNavigationBar: _selectionMode && _selectedTripIds.isNotEmpty
          ? Container(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                MediaQuery.of(context).padding.bottom + 12,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                border: Border(
                  top: BorderSide(
                    color:
                        Theme.of(context).dividerColor.withValues(alpha: 0.3),
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: ElevatedButton.icon(
                onPressed: () =>
                    _showBulkDeleteConfirmation(context, selectedTrips),
                icon: const Icon(Icons.delete_rounded),
                label: Text(
                  'Delete ${_selectedTripIds.length} trip${_selectedTripIds.length == 1 ? '' : 's'}',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            )
          : null,
      body: Stack(
        children: [
          // Ambient rotating globe behind the whole page. Paused while this
          // tab is offstage so the ticker doesn't burn frames from inside
          // the IndexedStack.
          Positioned.fill(
            child: RotatingGlobeBackground(
              animate: ref.watch(selectedTabIndexProvider) == 0,
            ),
          ),
          RefreshIndicator(
            onRefresh: _refreshTrips,
            // Spawn the spinner below the status bar — the page has no header.
            edgeOffset: MediaQuery.of(context).padding.top,
            child: CustomScrollView(
              controller: _tripsScrollController,
              slivers: [
                // No header in normal mode — content starts under the status bar.
                // Multi-select keeps its contextual bar (exit / count / select
                // all); without it the mode would be unusable.
                if (!_selectionMode)
                  SliverToBoxAdapter(
                    child: SizedBox(
                        height: MediaQuery.of(context).padding.top + 12),
                  )
                else
                  SliverAppBar(
                    floating: true,
                    pinned: true,
                    elevation: 0,
                    backgroundColor: _selectionMode
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).scaffoldBackgroundColor,
                    leading: _selectionMode
                        ? IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: _exitSelectionMode,
                          )
                        : null,
                    title: _selectionMode
                        ? Text(
                            '${_selectedTripIds.length} selected',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          )
                        : Text(
                            'My Trips',
                            style: Theme.of(context)
                                .textTheme
                                .headlineMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                    actions: _selectionMode
                        ? [
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Tooltip(
                                message:
                                    allSelected ? 'Deselect All' : 'Select All',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: allSelected
                                      ? _deselectAll
                                      : () => _selectAll(ownedTrips),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: Checkbox(
                                            value: allSelected
                                                ? true
                                                : _selectedTripIds.isNotEmpty
                                                    ? null
                                                    : false,
                                            tristate: true,
                                            onChanged: (_) => allSelected
                                                ? _deselectAll()
                                                : _selectAll(ownedTrips),
                                            materialTapTargetSize:
                                                MaterialTapTargetSize
                                                    .shrinkWrap,
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          allSelected
                                              ? 'Deselect All'
                                              : 'Select All',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                  fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ]
                        : null,
                  ),

                // Persistent referral banner — self-suppresses for signed-out
                // users and advocates (already shared / have referrals).
                if (!_selectionMode)
                  const SliverToBoxAdapter(child: ReferralHomeBanner()),

                // Active Trip Section
                SliverToBoxAdapter(
                  child: activeTripAsync.when(
                    data: (activeTrip) {
                      if (activeTrip == null) {
                        return Padding(
                          padding: const EdgeInsets.all(16),
                          child: _buildEmptyActiveTrip(context),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: _buildActiveTrip(context, activeTrip),
                      );
                    },
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: ActiveTripSkeleton(),
                    ),
                    error: (_, __) => const SizedBox.shrink(),
                  ),
                ),

                const SliverPadding(padding: EdgeInsets.symmetric(vertical: 8)),

                // Create Trip Button or Form (hidden during multi-select)
                if (!_selectionMode)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      // THE creation affordance — glowing, big, unmissable.
                      child: PulsingGlow(
                        shape: BoxShape.rectangle,
                        borderRadius: BorderRadius.circular(18),
                        glowColor: Theme.of(context).colorScheme.primary,
                        // Toned down from the defaults — the full glow read as
                        // overwhelming on the home screen.
                        minBlur: 6,
                        maxBlur: 16,
                        maxSpread: 2,
                        minAlpha: 0.15,
                        maxAlpha: 0.4,
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _openCreateWizard,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 18),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18)),
                              textStyle: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.6,
                                  ),
                            ),
                            child: const Text('New Trip'),
                          ),
                        ),
                      ),
                    ),
                  ),

                const SliverPadding(padding: EdgeInsets.symmetric(vertical: 8)),

                // Active trip section — its full card, pinned above the
                // lists (and excluded from them so it never shows twice).
                if (activeTrip != null) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Icon(
                            Icons.navigation_rounded,
                            size: 20,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Active Trip',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    sliver: SliverToBoxAdapter(
                      child: Builder(builder: (context) {
                        // A shared trip can be active too — render it with
                        // the shared card so its actions match the user's
                        // permission; owned (or still-loading) trips get the
                        // regular card.
                        String? sharedPermission;
                        for (final row
                            in sharedTripsAsync.valueOrNull ?? const []) {
                          final t = row['trips'] as Map<String, dynamic>?;
                          if (t != null && t['id'] == activeTrip.id) {
                            sharedPermission = row['permission'] as String?;
                            break;
                          }
                        }
                        if (sharedPermission != null) {
                          return _buildSharedTripCard(
                              context, activeTrip, sharedPermission);
                        }
                        return _buildTripCard(context, activeTrip);
                      }),
                    ),
                  ),
                ],

                // Trips List
                if (!hideYourTripsHeader)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Your Trips',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ),

                tripsAsync.when(
                  data: (trips) {
                    if (trips.isEmpty) {
                      // Activation empty state: the lever for the ~77% who never
                      // create a trip. Teach the 3-step value (save places →
                      // optimize → smarter route) so the first trip feels worth it.
                      final t = Theme.of(context);
                      Widget step(IconData icon, String text) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(icon,
                                    size: 18, color: t.colorScheme.primary),
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(text,
                                      style: t.textTheme.bodyMedium?.copyWith(
                                          color:
                                              t.colorScheme.onSurfaceVariant)),
                                ),
                              ],
                            ),
                          );
                      return SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(28, 20, 28, 8),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.route_rounded,
                                    size: 46, color: t.colorScheme.primary),
                                const SizedBox(height: 14),
                                Text('Plan your first trip',
                                    style: t.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(height: 14),
                                step(Icons.place_outlined,
                                    'Save 3+ places you want to visit'),
                                step(Icons.auto_awesome_rounded,
                                    'Tap Optimize — VoyZa orders them smartly'),
                                step(Icons.timelapse_rounded,
                                    'See more, backtrack less'),
                                const SizedBox(height: 18),
                                ElevatedButton.icon(
                                  onPressed: _createSampleTrip,
                                  icon: const Icon(Icons.auto_awesome_rounded,
                                      size: 18),
                                  label: const Text('Try a sample trip'),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                    'or tap "New Trip" above to start from scratch',
                                    textAlign: TextAlign.center,
                                    style: t.textTheme.bodySmall?.copyWith(
                                        color: t.colorScheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ),
                      );
                    }

                    // The active trip already has its own section above.
                    final listTrips =
                        trips.where((t) => t.id != activeTripId).toList();
                    if (listTrips.isEmpty) {
                      return const SliverToBoxAdapter(child: SizedBox.shrink());
                    }

                    return SliverPadding(
                      padding: const EdgeInsets.only(
                        left: 16,
                        right: 16,
                        top: 12,
                        bottom: 16,
                      ),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final trip = listTrips[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _buildTripCard(context, trip),
                            );
                          },
                          childCount: listTrips.length,
                        ),
                      ),
                    );
                  },
                  loading: () => const SliverToBoxAdapter(
                    child: TripsListSkeleton(),
                  ),
                  error: (_, __) => SliverToBoxAdapter(
                    child: _buildConnectionError(context),
                  ),
                ),

                // Shared Trips Section
                sharedTripsAsync.when(
                  data: (allSharedTrips) {
                    // The active trip already has its own section above.
                    final sharedTrips = allSharedTrips.where((d) {
                      final t = d['trips'] as Map<String, dynamic>?;
                      return t?['id'] != activeTripId;
                    }).toList();
                    if (sharedTrips.isEmpty) {
                      return const SliverToBoxAdapter(child: SizedBox.shrink());
                    }

                    return SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.group_outlined,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Shared With You',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          ...sharedTrips.map((data) {
                            final tripData =
                                data['trips'] as Map<String, dynamic>?;
                            final permission = data['permission'] as String;
                            if (tripData == null)
                              return const SizedBox.shrink();

                            final trip = Trip.fromJson(tripData);
                            return Padding(
                              padding: const EdgeInsets.only(
                                left: 16,
                                right: 16,
                                bottom: 12,
                              ),
                              child: _buildSharedTripCard(
                                  context, trip, permission),
                            );
                          }),
                        ],
                      ),
                    );
                  },
                  loading: () =>
                      const SliverToBoxAdapter(child: SizedBox.shrink()),
                  error: (_, __) =>
                      const SliverToBoxAdapter(child: SizedBox.shrink()),
                ),

                // Clear the floating bottom tab bar (~70px + safe-area inset)
                // — MainScreen sets `extendBody: true`, so the list scrolls
                // behind the bar and the last card otherwise tucks under it.
                // The previous 50px wasn't enough once the safe-area inset
                // was included, especially on iOS devices with a home
                // indicator.
                SliverPadding(
                  padding: EdgeInsets.only(
                    bottom: 90 + MediaQuery.of(context).padding.bottom,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionError(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Column(
        children: [
          Icon(
            Icons.wifi_off_rounded,
            size: 40,
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            'Connection issue',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Could not load your trips. Please check your connection and try refreshing.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _refreshTrips,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyActiveTrip(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      // Transparent body — the ambient globe shows through; only the border
      // defines the card.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.25),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.trip_origin_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            'No Active Trip',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Select or create a trip to get started',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withOpacity(0.7),
                ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildActiveTrip(BuildContext context, Trip trip) {
    return Container(
      padding: const EdgeInsets.all(20),
      // Transparent body (matches the empty-state card) — border only.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.35),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.navigation_rounded,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Active Trip',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      trip.name,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => _deactivateTrip(trip),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .secondary
                        .withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    color: Theme.of(context).colorScheme.secondary,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
          if (trip.description != null && trip.description!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              trip.description!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withOpacity(0.7),
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTripCard(BuildContext context, Trip trip) {
    final locationsAsync = ref.watch(savedLocationsProvider);
    final isSelected = _selectedTripIds.contains(trip.id);

    Widget buildContent(
        int locationCount, DateTime? startDate, DateTime? endDate) {
      return _buildTripCardContent(
        context,
        trip,
        locationCount,
        startDate,
        endDate,
        isSelected: isSelected,
      );
    }

    final card = locationsAsync.when(
      data: (allLocations) {
        final tripLocations =
            allLocations.where((loc) => loc.tripId == trip.id).toList();

        // Prefer the trip's explicit date range; otherwise derive from the
        // earliest/latest scheduled date among the trip's locations so the
        // user still sees a meaningful range on cards that haven't been
        // tagged with planning dates.
        DateTime? startDate = trip.startDate;
        DateTime? endDate = trip.endDate;
        if (startDate == null && endDate == null && tripLocations.isNotEmpty) {
          final dates = tripLocations
              .map((loc) => loc.scheduledDate ?? loc.createdAt)
              .toList()
            ..sort();
          startDate = dates.first;
          endDate = dates.last;
        }
        return buildContent(tripLocations.length, startDate, endDate);
      },
      loading: () => buildContent(0, trip.startDate, trip.endDate),
      error: (_, __) => buildContent(0, trip.startDate, trip.endDate),
    );

    return GestureDetector(
      onLongPress: _selectionMode ? null : () => _enterSelectionMode(trip.id),
      onTap: _selectionMode ? () => _toggleSelection(trip.id) : null,
      child: card,
    );
  }

  Widget _buildSharedTripCard(
      BuildContext context, Trip trip, String permission) {
    final isWriteAccess = permission == 'write';
    final permissionColor = isWriteAccess ? Colors.orange : Colors.blue;
    final permissionText = isWriteAccess ? 'Can Edit' : 'Read Only';

    // Check if this trip is the locally active trip
    final localActiveTripId = ref.watch(localActiveTripIdProvider);
    final isActive = localActiveTripId == trip.id;

    // Derive locationCount + an effective date range the same way the
    // owner card does so shared trips read with the same metadata.
    // Prefer the trip's explicit start/end; fall back to the earliest /
    // latest scheduled date among the trip's locations when null.
    final locationsAsync = ref.watch(savedLocationsProvider);
    final tripLocations = locationsAsync.maybeWhen(
      data: (all) => all.where((l) => l.tripId == trip.id).toList(),
      orElse: () => const [],
    );
    final locationCount = tripLocations.length;
    DateTime? startDate = trip.startDate;
    DateTime? endDate = trip.endDate;
    if (startDate == null && endDate == null && tripLocations.isNotEmpty) {
      final dates = tripLocations
          .map((loc) => loc.scheduledDate ?? loc.createdAt)
          .toList()
        ..sort();
      startDate = dates.first;
      endDate = dates.last;
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TripDetailsScreen(trip: trip),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          // Translucent to match the owned-trip cards — globe shows through.
          color: Theme.of(context).cardColor.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)
                : Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
            width: isActive ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: isActive
                  ? Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.05),
              blurRadius: isActive ? 8 : 4,
              offset: Offset(0, isActive ? 4 : 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with shared indicator
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.05),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.group_outlined,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Shared with you',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: permissionColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isWriteAccess ? Icons.edit : Icons.visibility,
                          size: 12,
                          color: permissionColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          permissionText,
                          style: TextStyle(
                            fontSize: 11,
                            color: permissionColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Trip content
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          trip.name,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (trip.description != null &&
                            trip.description!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            trip.description!,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.color
                                          ?.withValues(alpha: 0.6),
                                    ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],

                        // Location count + date range — same chrome as
                        // the owner card so shared trips read with
                        // identical metadata.
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.location_on,
                              size: 14,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '$locationCount ${locationCount == 1 ? 'location' : 'locations'}',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                        if (startDate != null && endDate != null) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                Icons.calendar_today,
                                size: 14,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Builder(builder: (context) {
                                  final s = DateTime(startDate!.year,
                                      startDate.month, startDate.day);
                                  final e = DateTime(endDate!.year,
                                      endDate.month, endDate.day);
                                  final dayCount = daySpanDays(s, e) + 1;
                                  final dateText = startDate == endDate
                                      ? DateFormat('MMM d, y').format(startDate)
                                      : '${DateFormat('MMM d').format(startDate)} - ${DateFormat('MMM d, y').format(endDate)}';
                                  return Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(text: dateText),
                                        TextSpan(
                                          text:
                                              '  ·  $dayCount day${dayCount == 1 ? '' : 's'}',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                          ),
                                        ),
                                      ],
                                    ),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(fontWeight: FontWeight.w500),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  );
                                }),
                              ),
                            ],
                          ),
                        ],

                        // Co-collaborators on this shared trip (read-only —
                        // guests can see who else they're planning with).
                        const SizedBox(height: 10),
                        TripCollaboratorsRow(
                          tripId: trip.id,
                          tripName: trip.name,
                          canManage: false,
                        ),

                        const SizedBox(height: 8),
                        // Activate/Deactivate (+ Go to map when active) for
                        // shared trips
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isActive) ...[
                              SizedBox(
                                height: 28,
                                child: ElevatedButton.icon(
                                  onPressed: () => _goToMapForTrip(trip),
                                  icon: const Icon(Icons.map_rounded, size: 16),
                                  label: const Text(
                                    'Go to map',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        Theme.of(context).colorScheme.primary,
                                    foregroundColor:
                                        Theme.of(context).colorScheme.onPrimary,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            SizedBox(
                              height: 28,
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  if (isActive) {
                                    _deactivateTrip(trip);
                                  } else {
                                    _setActiveTrip(trip);
                                  }
                                },
                                icon: Icon(
                                  isActive
                                      ? Icons.stop_circle_outlined
                                      : Icons.play_circle_outline,
                                  size: 16,
                                ),
                                label: Text(
                                  isActive ? 'Deactivate' : 'Activate',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                style: ElevatedButton.styleFrom(
                                  // Neutral styling: managing the active trip is
                                  // housekeeping, not a warning (orange) or a
                                  // success (green).
                                  backgroundColor: isActive
                                      ? Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.12)
                                      : Theme.of(context).colorScheme.primary,
                                  foregroundColor: isActive
                                      ? Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.85)
                                      : Theme.of(context).colorScheme.onPrimary,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_vert_rounded,
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withValues(alpha: 0.6),
                    ),
                    itemBuilder: (context) => [
                      const PopupMenuItem<String>(
                        value: 'leave',
                        child: Row(
                          children: [
                            Icon(
                              Icons.exit_to_app_rounded,
                              size: 18,
                              color: Colors.red,
                            ),
                            SizedBox(width: 12),
                            Text(
                              'Leave Trip',
                              style: TextStyle(color: Colors.red),
                            ),
                          ],
                        ),
                      ),
                    ],
                    onSelected: (value) {
                      if (value == 'leave') {
                        _showLeaveConfirmation(context, trip);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLeaveConfirmation(BuildContext context, Trip trip) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.exit_to_app_rounded,
                color: Colors.orange,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Leave Trip?'),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to leave "${trip.name}"?',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'You will no longer have access to this trip unless the owner adds you again.',
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _leaveTrip(trip);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
  }

  Future<void> _leaveTrip(Trip trip) async {
    try {
      final repository = ref.read(tripCollaboratorRepositoryProvider);
      final success = await repository.leaveTrip(trip.id);

      if (success) {
        ref.invalidate(sharedTripsProvider);
        if (mounted) {
          AppToast.warning(context, 'You left "${trip.name}"');
        }
      } else {
        if (mounted) {
          AppToast.error(context, 'Failed to leave trip');
        }
      }
    } catch (e) {
      debugPrint('Error leaving trip: $e');
      if (mounted) {
        AppToast.error(
          context,
          'Could not leave trip. Please check your connection and try again.',
        );
      }
    }
  }

  Widget _buildTripCardContent(
    BuildContext context,
    Trip trip,
    int locationCount,
    DateTime? startDate,
    DateTime? endDate, {
    bool isSelected = false,
  }) {
    final localActiveTripId = ref.watch(localActiveTripIdProvider);
    final isActive = localActiveTripId == trip.id;

    // Green = active is a status semantic; "Inactive" is a neutral state,
    // not a warning — grey, never orange.
    final statusColor = isActive ? Colors.green : Colors.grey;
    final statusText = isActive ? 'Active' : 'Inactive';

    // Border and shadow change based on active / selected state
    final borderColor = isSelected
        ? Theme.of(context).colorScheme.primary
        : isActive
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)
            : Theme.of(context).dividerColor.withValues(alpha: 0.2);
    final borderWidth = (isSelected || isActive) ? 2.0 : 1.0;

    return GestureDetector(
      // In selection mode the outer GestureDetector in _buildTripCard handles
      // taps; here we only navigate when NOT in selection mode.
      onTap: _selectionMode
          ? null
          : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => TripDetailsScreen(trip: trip),
                ),
              ),
      child: AnimatedOpacity(
        opacity: _selectionMode && !isSelected ? 0.55 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                // Translucent so the ambient globe stays visible behind the
                // list; the border carries the card's shape.
                color: Theme.of(context).cardColor.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: borderColor, width: borderWidth),
                boxShadow: [
                  BoxShadow(
                    color: isSelected
                        ? Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.12)
                        : isActive
                            ? Colors.green.withValues(alpha: 0.1)
                            : Colors.black.withValues(alpha: 0.05),
                    blurRadius: (isSelected || isActive) ? 8 : 4,
                    offset: Offset(0, (isSelected || isActive) ? 4 : 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header with name, country chip, and action menu
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                trip.name,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (trip.countryCode != null) ...[
                                const SizedBox(height: 6),
                                Builder(builder: (context) {
                                  final country =
                                      findCountryByCode(trip.countryCode);
                                  if (country == null)
                                    return const SizedBox.shrink();
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      CountryFlagIcon(country.code, height: 14),
                                      const SizedBox(width: 5),
                                      Text(
                                        country.name,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              fontWeight: FontWeight.w500,
                                            ),
                                      ),
                                    ],
                                  );
                                }),
                              ],
                            ],
                          ),
                        ),
                        if (!_selectionMode)
                          PopupMenuButton<String>(
                            icon: Icon(
                              Icons.more_vert_rounded,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.color
                                  ?.withValues(alpha: 0.6),
                            ),
                            itemBuilder: (context) => [
                              PopupMenuItem<String>(
                                value: 'rename',
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.edit_rounded,
                                      size: 18,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                                    const SizedBox(width: 12),
                                    const Text('Edit'),
                                  ],
                                ),
                              ),
                              PopupMenuItem<String>(
                                value: 'reschedule',
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.event_repeat_rounded,
                                      size: 18,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                                    const SizedBox(width: 12),
                                    const Text('Reschedule'),
                                  ],
                                ),
                              ),
                              const PopupMenuDivider(),
                              const PopupMenuItem<String>(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.delete_rounded,
                                      size: 18,
                                      color: Colors.red,
                                    ),
                                    SizedBox(width: 12),
                                    Text(
                                      'Delete',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            onSelected: (value) {
                              if (value == 'rename') {
                                _showEditTripDialog(context, trip);
                              } else if (value == 'reschedule') {
                                _rescheduleTripFromCard(trip);
                              } else if (value == 'delete') {
                                _showDeleteConfirmation(context, trip);
                              }
                            },
                          ),
                      ],
                    ),
                  ),

                  // Trip info
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Location count
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Icon(
                                Icons.location_on,
                                size: 16,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$locationCount ${locationCount == 1 ? 'location' : 'locations'}',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                          ],
                        ),

                        // Date range
                        if (startDate != null && endDate != null) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Icon(
                                  Icons.calendar_today,
                                  size: 16,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Builder(builder: (context) {
                                  // Inclusive day count — Mar 5 → Mar 7 is 3 days,
                                  // not 2. Normalize to midnight before diffing so
                                  // a stored time component doesn't shave a day.
                                  final s = DateTime(startDate.year,
                                      startDate.month, startDate.day);
                                  final e = DateTime(
                                      endDate.year, endDate.month, endDate.day);
                                  final dayCount = daySpanDays(s, e) + 1;
                                  final dateText = startDate == endDate
                                      ? DateFormat('MMM d, y').format(startDate)
                                      : '${DateFormat('MMM d').format(startDate)} - ${DateFormat('MMM d, y').format(endDate)}';
                                  return Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(text: dateText),
                                        TextSpan(
                                          text:
                                              '  ·  $dayCount day${dayCount == 1 ? '' : 's'}',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                          ),
                                        ),
                                      ],
                                    ),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w500),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  );
                                }),
                              ),
                            ],
                          ),
                        ],

                        // Collaborators + add-collaborator button (owned
                        // trips only — this content builder isn't used for
                        // shared cards). Hidden during multi-select.
                        if (!_selectionMode) ...[
                          const SizedBox(height: 12),
                          TripCollaboratorsRow(
                            tripId: trip.id,
                            tripName: trip.name,
                          ),
                        ],

                        const SizedBox(height: 12),
                        const Divider(height: 1),
                        const SizedBox(height: 12),

                        // Status and activate button
                        Row(
                          children: [
                            // Status indicator
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: statusColor.withValues(alpha: 0.3),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: statusColor,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    statusText,
                                    style: TextStyle(
                                      color: statusColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const Spacer(),

                            // Active trip: explicit hop over to the Map tab
                            // (activation itself no longer auto-switches).
                            if (isActive) ...[
                              SizedBox(
                                height: 32,
                                child: ElevatedButton.icon(
                                  onPressed: () => _goToMapForTrip(trip),
                                  icon: const Icon(Icons.map_rounded, size: 18),
                                  label: const Text('Go to map'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        Theme.of(context).colorScheme.primary,
                                    foregroundColor:
                                        Theme.of(context).colorScheme.onPrimary,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],

                            // Activate/Deactivate button
                            SizedBox(
                              height: 32,
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  if (isActive) {
                                    _deactivateTrip(trip);
                                  } else {
                                    _setActiveTrip(trip);
                                  }
                                },
                                icon: Icon(
                                  isActive
                                      ? Icons.stop_circle_outlined
                                      : Icons.play_circle_outline,
                                  size: 18,
                                ),
                                label:
                                    Text(isActive ? 'Deactivate' : 'Activate'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      isActive ? Colors.orange : Colors.green,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Checkbox badge — overlays the card in selection mode
            if (_selectionMode)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).cardColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context)
                              .colorScheme
                              .outline
                              .withValues(alpha: 0.5),
                      width: 2,
                    ),
                  ),
                  child: isSelected
                      ? const Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: Colors.white,
                        )
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deactivateTrip(Trip trip) async {
    try {
      // Deactivate trip locally (no database update)
      await ref.read(localActiveTripIdProvider.notifier).deactivateTrip();

      if (mounted) {
        AppToast.info(context, 'Trip deactivated');
      }
    } catch (e) {
      debugPrint('Error deactivating trip: $e');
      if (mounted) {
        AppToast.error(context, 'Could not deactivate trip. Please try again.');
      }
    }
  }

  void _showDeleteConfirmation(BuildContext context, Trip trip) {
    final locationsAsync = ref.read(savedLocationsProvider);

    locationsAsync.whenData((allLocations) {
      final locationCount =
          allLocations.where((loc) => loc.tripId == trip.id).length;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          // Buttons live inside content so they can be full-width stacked
          // vertically — three items in an actions row look cramped on mobile.
          actionsPadding: EdgeInsets.zero,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.warning_rounded,
                  color: Colors.red,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(child: Text('Delete Trip?')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Are you sure you want to delete "${trip.name}"?',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              if (locationCount > 0) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.blue.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline,
                          color: Colors.blue, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'This trip has $locationCount ${locationCount == 1 ? 'location' : 'locations'}. '
                          'What would you like to do with them?',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'This action cannot be undone.',
                style: TextStyle(
                  color: Colors.red,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              // ── Action buttons ──────────────────────────────────────────
              if (locationCount > 0) ...[
                // Destructive option
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _deleteTrip(trip, deleteLocations: true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Delete Trip & Locations'),
                ),
                const SizedBox(height: 8),
                // Safe option
                OutlinedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _deleteTrip(trip, deleteLocations: false);
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Delete Trip, Keep Locations'),
                ),
              ] else
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _deleteTrip(trip);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Delete'),
                ),
              const SizedBox(height: 4),
              // Cancel is always a low-prominence text button at the bottom
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      );
    });
  }

  void _showEditTripDialog(BuildContext context, Trip trip) {
    showDialog(
      context: context,
      builder: (context) => _EditTripDialog(
        trip: trip,
        onSave: ({
          required String newName,
          required String newDescription,
          required String? newCountryCode,
          required bool clearCountry,
          required DateTime? newStartDate,
          required DateTime? newEndDate,
          required bool clearDates,
        }) {
          _updateTripDetails(
            trip,
            newName: newName,
            newDescription: newDescription,
            newCountryCode: newCountryCode,
            clearCountry: clearCountry,
            newStartDate: newStartDate,
            newEndDate: newEndDate,
            clearDates: clearDates,
          );
        },
      ),
    );
  }

  /// Card action: move the whole trip to a new start date. The duration is
  /// preserved, the start can't be in the past, and every planned place
  /// shifts with it — same day-by-day grouping, same order.
  Future<void> _rescheduleTripFromCard(Trip trip) async {
    // Never reschedule against a list that hasn't loaded — an empty
    // fallback would move the trip's range while shifting zero places.
    final allAsync = ref.read(savedLocationsProvider);
    final all = allAsync.valueOrNull;
    if (all == null) {
      AppToast.info(context, 'Still loading your places — try again.');
      return;
    }
    final tripLocs = all.where((l) => l.tripId == trip.id).toList();
    final days = contiguousTripDates([
      trip.startDate,
      trip.endDate,
      for (final l in tripLocs) ...[
        l.scheduledDate ?? l.createdAt,
        l.scheduledEndDate ?? l.scheduledDate ?? l.createdAt,
      ],
    ]);
    if (days.isEmpty) {
      AppToast.info(context, 'Add dates or places first, then reschedule.');
      return;
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final newStart = await showDatePicker(
      context: context,
      initialDate: days.first.isBefore(today) ? today : days.first,
      firstDate: today,
      lastDate: DateTime(today.year + 5),
      helpText: 'New start date',
    );
    if (newStart == null || !mounted) return;

    final startKey = DateTime(newStart.year, newStart.month, newStart.day);
    final span = daySpanDays(days.first, days.last);
    final newEnd = DateTime(startKey.year, startKey.month, startKey.day + span);
    try {
      final scheduled = tripLocs.where((l) => l.scheduledDate != null).toList();
      var moved = 0;
      if (scheduled.isNotEmpty) {
        // Span preserved → no clamping → the plan can never contain
        // merge-deletions on this path.
        final plan = _planTripShift(
          scheduled,
          oldStart: days.first,
          newStart: startKey,
          newEnd: newEnd,
        );
        await _executeShiftPlan(plan);
        moved = plan.moved;
      }
      await ref.read(tripRepositoryProvider).updateTrip(
            trip.id,
            startDate: startKey,
            endDate: newEnd,
          );
      ref.invalidate(userTripsProvider);
      if (mounted) {
        final fmt = DateFormat('MMM d');
        final movedNote = moved > 0
            ? ' · $moved ${moved == 1 ? 'place' : 'places'} moved'
            : '';
        AppToast.success(
            context,
            'Trip moved — ${fmt.format(startKey)} to '
            '${fmt.format(newEnd)}$movedNote');
      }
    } catch (e) {
      debugPrint('_rescheduleTripFromCard: $e');
      if (mounted) {
        AppToast.error(
            context,
            'Couldn\'t finish rescheduling — some places may not have '
            'moved. Check the trip and try again.');
      }
    }
  }

  /// "Trip dates changed — what about the planned places?" Returns 'move'
  /// (shift them with the trip), 'keep' (leave them on their dates), or
  /// null (cancel the whole edit).
  Future<String?> _askRescheduleMode({
    required int count,
    required DateTime newStart,
  }) {
    final fmt = DateFormat('MMM d');
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Reschedule the plan too?'),
          content: Text(
            '$count planned ${count == 1 ? 'place' : 'places'} follow the '
            'old dates. Move ${count == 1 ? 'it' : 'them'} with the trip — '
            'day by day, in the same order, starting ${fmt.format(newStart)} '
            '— or keep ${count == 1 ? 'it' : 'them'} on '
            '${count == 1 ? 'its' : 'their'} current dates?',
            style: theme.textTheme.bodyMedium,
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          actions: [
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, 'keep'),
                    child: const Text('Keep'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, 'move'),
                    child: const Text('Move'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// A shift decided entirely BEFORE any write: per-row updates, rows to
  /// delete (same-place squashed onto one day by a shortening clamp), and
  /// counts for the caller's single toast. Rows whose stored dates would
  /// not change are skipped outright.
  ({
    Map<String, Map<String, dynamic>> updates,
    List<String> deletions,
    int moved,
    int merged,
  }) _planTripShift(
    List<SavedLocation> tripLocations, {
    required DateTime oldStart,
    required DateTime newStart,
    required DateTime newEnd,
  }) {
    final oldStartKey = dayKey(oldStart);
    final rangeStart = dayKey(newStart);
    final rangeEnd = dayKey(newEnd);
    // Calendar-day delta (NOT difference().inDays — that truncates across a
    // DST spring-forward and shifted every place one day early).
    final delta = daySpanDays(oldStartKey, rangeStart);

    DateTime clamp(DateTime d) {
      if (d.isBefore(rangeStart)) return rangeStart;
      if (d.isAfter(rangeEnd)) return rangeEnd;
      return d;
    }

    final sorted = [...tripLocations]
      ..sort((a, b) => a.scheduledDate!.compareTo(b.scheduledDate!));
    final updates = <String, Map<String, dynamic>>{};
    final deletions = <String>[];
    final claimedAccommodationDays = <DateTime>{};
    final placedByDay = <DateTime, List<PlaceKey>>{};
    var moved = 0, merged = 0;

    for (final loc in sorted) {
      final sched = dayKey(loc.scheduledDate!);
      final newSched =
          clamp(DateTime(sched.year, sched.month, sched.day + delta));
      DateTime? newSpanEnd;
      final end = loc.scheduledEndDate;
      if (end != null) {
        final e = dayKey(end);
        final shifted = clamp(DateTime(e.year, e.month, e.day + delta));
        if (shifted.isAfter(newSched)) newSpanEnd = shifted;
      }

      // Same-day duplicate rule: clamping a shortened trip can squash two
      // copies of a place onto one day — planned as a deletion the caller
      // must get CONSENT for before executing.
      final key = placeKeyOfSaved(loc);
      final placedHere = placedByDay.putIfAbsent(newSched, () => []);
      if (placedHere.any((o) => isSamePlace(o, key))) {
        deletions.add(loc.id);
        merged++;
        continue;
      }
      placedHere.add(key);

      var unmarkAccommodation = false;
      if (loc.isAccommodation) {
        final covered = <DateTime>[];
        for (var d = newSched;
            !d.isAfter(newSpanEnd ?? newSched);
            d = DateTime(d.year, d.month, d.day + 1)) {
          covered.add(d);
        }
        if (covered.any(claimedAccommodationDays.contains)) {
          unmarkAccommodation = true;
        } else {
          claimedAccommodationDays.addAll(covered);
        }
      }

      final endUnchanged = (newSpanEnd == null && end == null) ||
          (newSpanEnd != null &&
              end != null &&
              newSpanEnd.isAtSameMomentAs(dayKey(end)));
      if (newSched.isAtSameMomentAs(sched) &&
          endUnchanged &&
          !unmarkAccommodation) {
        continue; // no-op — don't rewrite identical rows
      }

      updates[loc.id] = {
        'scheduled_date': newSched.toIso8601String(),
        'scheduled_end_date': newSpanEnd?.toIso8601String(),
        if (unmarkAccommodation) 'is_accommodation': false,
      };
      moved++;
    }
    return (
      updates: updates,
      deletions: deletions,
      moved: moved,
      merged: merged,
    );
  }

  /// Executes a [_planTripShift] result: updates dispatched together
  /// (single round-trip wall-clock), deletions LAST so a mid-flight
  /// failure can't have destroyed rows before the moves landed.
  Future<void> _executeShiftPlan(
      ({
        Map<String, Map<String, dynamic>> updates,
        List<String> deletions,
        int moved,
        int merged,
      }) plan) async {
    final repo = ref.read(locationRepositoryProvider);
    await Future.wait(
        plan.updates.entries.map((e) => repo.updateLocation(e.key, e.value)));
    await Future.wait(plan.deletions.map(repo.deleteLocation));
  }

  Future<void> _updateTripDetails(
    Trip trip, {
    required String newName,
    required String newDescription,
    required String? newCountryCode,
    required bool clearCountry,
    required DateTime? newStartDate,
    required DateTime? newEndDate,
    required bool clearDates,
  }) async {
    if (newName.isEmpty) {
      AppToast.warning(context, 'Trip name cannot be empty');
      return;
    }

    final nameUnchanged = newName == trip.name;
    final descriptionUnchanged = newDescription == (trip.description ?? '');
    final countryUnchanged = !clearCountry &&
        (newCountryCode?.toUpperCase() ?? trip.countryCode) == trip.countryCode;
    final datesUnchanged = !clearDates &&
        newStartDate == trip.startDate &&
        newEndDate == trip.endDate;
    if (nameUnchanged &&
        descriptionUnchanged &&
        countryUnchanged &&
        datesUnchanged) {
      return; // No changes made
    }

    // When the user changed the trip's date range, planned places need a
    // decision. If both old and new ranges have a start, offer the
    // RESCHEDULE path: shift every place by the start-date delta so the
    // day-by-day plan survives on the new dates, in the same order. If
    // they'd rather keep places on their current dates (or ranges don't
    // support a shift), fall back to the fit check.
    ({
      Map<String, Map<String, dynamic>> updates,
      List<String> deletions,
      int moved,
      int merged,
    })? pendingShift;
    if (!datesUnchanged &&
        !clearDates &&
        (newStartDate != null || newEndDate != null)) {
      // Never plan against a list that hasn't loaded — an empty fallback
      // silently skipped the reschedule question AND the fit check.
      final allAsync = ref.read(savedLocationsProvider);
      final allLocations = allAsync.valueOrNull;
      if (allLocations == null) {
        AppToast.info(context, 'Still loading your places — try again.');
        return;
      }
      final tripLocations = allLocations
          .where((loc) => loc.tripId == trip.id && loc.scheduledDate != null)
          .toList();
      if (tripLocations.isNotEmpty) {
        if (!mounted) return;
        var shifted = false;
        if (newStartDate != null && trip.startDate != null) {
          final mode = await _askRescheduleMode(
            count: tripLocations.length,
            newStart: newStartDate,
          );
          if (mode == null) return; // cancelled
          if (mode == 'move') {
            pendingShift = _planTripShift(
              tripLocations,
              oldStart: trip.startDate!,
              newStart: newStartDate,
              newEnd: newEndDate ?? newStartDate,
            );
            // A shortened range can squash same-place duplicates together;
            // those rows get DELETED — never without explicit consent.
            if (pendingShift.merged > 0) {
              if (!mounted) return;
              final proceed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                  title: const Text('Some places will merge'),
                  content: Text(
                    'The shorter dates squeeze the plan: '
                    '${pendingShift!.merged} duplicate '
                    '${pendingShift.merged == 1 ? 'place lands' : 'places land'} '
                    'on a day that already has the same place, and the extra '
                    '${pendingShift.merged == 1 ? 'copy' : 'copies'} will be '
                    'deleted. Continue?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Continue'),
                    ),
                  ],
                ),
              );
              if (proceed != true) return;
            }
            shifted = true;
          }
        }
        if (!shifted) {
          if (!mounted) return;
          final ok = await ensureLocationsFitNewTripRange(
            context,
            tripName: trip.name,
            newStart: newStartDate,
            newEnd: newEndDate,
            existingScheduledDates:
                tripLocations.map((loc) => loc.scheduledDate!).toList(),
          );
          if (!ok) return;
        }
      }
    }

    try {
      // The shift runs INSIDE this try — a mid-flight failure must surface
      // as an error, not escape as an unhandled async exception with the
      // itinerary half-moved.
      if (pendingShift != null) {
        await _executeShiftPlan(pendingShift);
      }
      final tripRepository = ref.read(tripRepositoryProvider);
      await tripRepository.updateTrip(
        trip.id,
        name: nameUnchanged ? null : newName,
        description: descriptionUnchanged ? null : newDescription,
        countryCode: clearCountry ? null : newCountryCode,
        clearCountryCode: clearCountry,
        startDate: clearDates ? null : newStartDate,
        endDate: clearDates ? null : newEndDate,
        clearDates: clearDates,
      );

      ref.invalidate(userTripsProvider);

      if (mounted) {
        final parts = <String>[
          if ((pendingShift?.moved ?? 0) > 0)
            '${pendingShift!.moved} '
                '${pendingShift.moved == 1 ? 'place' : 'places'} moved',
          if ((pendingShift?.merged ?? 0) > 0) '${pendingShift!.merged} merged',
        ];
        AppToast.success(
            context,
            parts.isEmpty
                ? 'Trip updated'
                : 'Trip updated · ${parts.join(' · ')}');
      }
    } catch (e) {
      debugPrint('Error updating trip: $e');
      if (mounted) {
        AppToast.error(
          context,
          'Could not update trip. Please check your connection and try again.',
        );
      }
    }
  }

  void _showBulkDeleteConfirmation(BuildContext context, List<Trip> trips) {
    final locationsAsync = ref.read(savedLocationsProvider);

    locationsAsync.whenData((allLocations) {
      // Count total locations across all selected trips
      final totalLocations = allLocations
          .where((loc) => trips.any((t) => t.id == loc.tripId))
          .length;
      final hasLocations = totalLocations > 0;
      final tripCount = trips.length;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          actionsPadding: EdgeInsets.zero,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.warning_rounded,
                  color: Colors.red,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Delete $tripCount ${tripCount == 1 ? 'Trip' : 'Trips'}?',
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'You are about to delete $tripCount ${tripCount == 1 ? 'trip' : 'trips'}.',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              if (hasLocations) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.blue.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline,
                          color: Colors.blue, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'These trips contain $totalLocations ${totalLocations == 1 ? 'location' : 'locations'}. '
                          'What would you like to do with them?',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'This action cannot be undone.',
                style: TextStyle(
                  color: Colors.red,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              if (hasLocations) ...[
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _bulkDeleteTrips(trips, deleteLocations: true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Delete Trips & Locations'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _bulkDeleteTrips(trips, deleteLocations: false);
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Delete Trips, Keep Locations'),
                ),
              ] else
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _bulkDeleteTrips(trips);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    'Delete ${tripCount == 1 ? 'Trip' : 'Trips'}',
                  ),
                ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      );
    });
  }

  Future<void> _bulkDeleteTrips(
    List<Trip> trips, {
    bool deleteLocations = false,
  }) async {
    try {
      final locationRepository = ref.read(locationRepositoryProvider);
      final tripRepository = ref.read(tripRepositoryProvider);

      for (final trip in trips) {
        if (deleteLocations) {
          await locationRepository.deleteLocationsByTripId(trip.id);
        }
        await tripRepository.deleteTrip(trip.id);
      }

      ref.invalidate(userTripsProvider);
      _exitSelectionMode();

      if (mounted) {
        final count = trips.length;
        AppToast.success(
          context,
          deleteLocations
              ? '$count ${count == 1 ? 'trip' : 'trips'} and their locations deleted'
              : '$count ${count == 1 ? 'trip' : 'trips'} deleted. Locations kept.',
        );
      }
    } catch (e) {
      debugPrint('Error bulk deleting trips: $e');
      if (mounted) {
        AppToast.error(
          context,
          'Could not delete all trips. Please check your connection and try again.',
        );
      }
    }
  }
}

extension on String {}

typedef _EditTripSaveCallback = void Function({
  required String newName,
  required String newDescription,
  required String? newCountryCode,
  required bool clearCountry,
  required DateTime? newStartDate,
  required DateTime? newEndDate,
  required bool clearDates,
});

class _EditTripDialog extends StatefulWidget {
  final Trip trip;
  final _EditTripSaveCallback onSave;

  const _EditTripDialog({required this.trip, required this.onSave});

  @override
  State<_EditTripDialog> createState() => _EditTripDialogState();
}

class _EditTripDialogState extends State<_EditTripDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late String? _countryCode;
  late bool _clearedCountry;
  late DateTime? _startDate;
  late DateTime? _endDate;
  late bool _clearedDates;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.trip.name);
    _descriptionController =
        TextEditingController(text: widget.trip.description ?? '');
    _countryCode = widget.trip.countryCode;
    _clearedCountry = false;
    _startDate = widget.trip.startDate;
    _endDate = widget.trip.endDate;
    _clearedDates = false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickCountry() async {
    final result = await showCountryPickerSheet(
      context,
      selectedCode: _countryCode,
    );
    if (result == null) return;
    setState(() {
      if (result.code == kClearCountry.code) {
        _countryCode = null;
        _clearedCountry = true;
      } else {
        _countryCode = result.code;
        _clearedCountry = false;
      }
    });
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initialRange = (_startDate != null && _endDate != null)
        ? DateTimeRange(start: _startDate!, end: _endDate!)
        : null;
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: initialRange,
      firstDate: DateTime(today.year - 1),
      lastDate: DateTime(today.year + 5),
    );
    if (picked == null) return;
    setState(() {
      _startDate = picked.start;
      _endDate = picked.end;
      _clearedDates = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final country = findCountryByCode(_countryCode);

    return AlertDialog(
      title: const Text('Edit Trip'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            maxLength: 30,
            decoration: InputDecoration(
              hintText: 'Trip name',
              labelText: 'Trip Name',
              counterText: '',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            autofocus: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            minLines: 2,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'Optional description',
              labelText: 'Description',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: _pickCountry,
            borderRadius: BorderRadius.circular(8),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Destination Country',
                hintText: 'Optional — biases location search',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                suffixIcon: country == null
                    ? const Icon(Icons.arrow_drop_down)
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        tooltip: 'Clear country',
                        onPressed: () => setState(() {
                          _countryCode = null;
                          _clearedCountry = true;
                        }),
                      ),
              ),
              child: Row(
                children: [
                  if (country != null) ...[
                    CountryFlagIcon(country.code, height: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        country.name,
                        style: theme.textTheme.bodyLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ] else
                    Expanded(
                      child: Text(
                        'Choose a country',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildDateRangeField(theme),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            widget.onSave(
              newName: _nameController.text.trim(),
              newDescription: _descriptionController.text.trim(),
              newCountryCode: _countryCode,
              clearCountry: _clearedCountry,
              newStartDate: _startDate,
              newEndDate: _endDate,
              clearDates: _clearedDates,
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildDateRangeField(ThemeData theme) {
    final hasRange = _startDate != null && _endDate != null;
    final fmt = DateFormat('MMM d, y');
    return InkWell(
      onTap: _pickDateRange,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Trip Dates',
          hintText: 'Optional — pick start and end dates',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          suffixIcon: !hasRange
              ? const Icon(Icons.calendar_today_outlined)
              : IconButton(
                  icon: const Icon(Icons.clear, size: 20),
                  tooltip: 'Clear dates',
                  onPressed: () => setState(() {
                    _startDate = null;
                    _endDate = null;
                    _clearedDates = true;
                  }),
                ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                hasRange
                    ? '${fmt.format(_startDate!)} - ${fmt.format(_endDate!)}'
                    : 'Add a date range',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: hasRange ? null : theme.hintColor,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
