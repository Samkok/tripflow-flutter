import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:voyza/providers/onboarding_checklist_provider.dart';
import 'package:voyza/widgets/onboarding_checklist.dart';
import 'package:voyza/widgets/promo_days_card.dart';
import 'package:voyza/widgets/route_spine.dart';
import 'package:voyza/widgets/sign_up_required_sheet.dart';
import 'package:voyza/screens/create_trip_wizard.dart';
import 'package:voyza/screens/copy_trip_wizard.dart';
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

  // Checklist spotlight anchors. GlobalKeys must be unique, so the two
  // card keys are attached per call site (first list card / active card).
  // Home trip search + start-date sort (toggle asc/desc; dateless trips
  // sink to the end either way).
  final _tripSearchController = TextEditingController();
  String _tripQuery = '';
  bool _tripSortAsc = false;

  final _newTripBtnKey = GlobalKey();
  final _cardActivateKey = GlobalKey();
  final _activeGoToMapKey = GlobalKey();

  // Multi-select state
  bool _selectionMode = false;
  final Set<String> _selectedTripIds = {};

  @override
  void dispose() {
    _tripsScrollController.dispose();
    _tripSearchController.dispose();
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
      if (userId == null) return; // recap is a signed-in feature for now
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

  bool _matchesTripQuery(String name) {
    final q = _tripQuery.trim().toLowerCase();
    return q.isEmpty || name.toLowerCase().contains(q);
  }

  int _compareTripStart(DateTime? sa, DateTime? sb) {
    if (sa == null && sb == null) return 0;
    if (sa == null) return 1; // dateless last in both directions
    if (sb == null) return -1;
    return _tripSortAsc ? sa.compareTo(sb) : sb.compareTo(sa);
  }

  List<Trip> _filterAndSortTrips(List<Trip> trips) {
    final out = trips.where((t) => _matchesTripQuery(t.name)).toList();
    out.sort((a, b) => _compareTripStart(a.startDate, b.startDate));
    return out;
  }

  /// Same search + sort for the shared list, which arrives as raw
  /// collaborator rows ({'trips': {...}, 'permission': ...}) instead of Trip
  /// objects. Rows with a null embed are dropped here so the section can't
  /// render a blank card, and the active trip is excluded (it has its own
  /// section above).
  List<Map<String, dynamic>> _filterAndSortSharedTrips(
      List<Map<String, dynamic>> rows, String? activeTripId) {
    final out = rows.where((d) {
      final t = d['trips'] as Map<String, dynamic>?;
      if (t == null || t['id'] == activeTripId) return false;
      return _matchesTripQuery((t['name'] as String?) ?? '');
    }).toList();
    DateTime? startOf(Map<String, dynamic> d) {
      final raw = (d['trips'] as Map<String, dynamic>)['start_date'] as String?;
      return raw == null ? null : DateTime.tryParse(raw);
    }

    out.sort((a, b) => _compareTripStart(startOf(a), startOf(b)));
    return out;
  }

  /// Checklist tap → set the guide bus and put the right screen on stage.
  /// This screen fulfils createTrip / activateTrip / goToMap itself; trip
  /// details fulfils addLocations; the map fulfils optimizeRoute.
  void _onChecklistStep(ChecklistStep step) {
    final guide = ref.read(checklistGuideRequestProvider.notifier);
    switch (step) {
      case ChecklistStep.createTrip:
        guide.state = ChecklistGuide.createTrip;
      case ChecklistStep.addLocations:
        final trips = ref.read(userTripsProvider).valueOrNull ?? [];
        if (trips.isEmpty) return;
        guide.state = ChecklistGuide.addLocations;
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => TripDetailsScreen(trip: trips.first)),
        );
      case ChecklistStep.activateTrip:
        guide.state = ChecklistGuide.activateTrip;
      case ChecklistStep.optimizeRoute:
        guide.state = ChecklistGuide.optimizeRoute;
        ref.read(mainTabRequestProvider.notifier).state = 1; // Map tab
    }
  }

  /// Scroll home to the top (where every spotlight target lives), wait for
  /// the scroll + layout to settle, then run the coach mark.
  void _coachAfterScroll(GlobalKey key, String title, String body,
      {int settleMs = 400}) {
    if (_tripsScrollController.hasClients &&
        _tripsScrollController.offset > 0) {
      _tripsScrollController.animateTo(0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic);
    }
    Future.delayed(Duration(milliseconds: settleMs), () {
      if (!mounted) return;
      showChecklistCoach(context, targetKey: key, title: title, body: body);
    });
  }

  /// Full-width copy-a-trip entry under the New Trip button. Transparent,
  /// labeled in the same text color as trip-card names, with a border that
  /// renders ONLY at the rounded corners (owner-specified look) — see
  /// [_CornerBorderPainter].
  Widget _buildCopyTripButton(BuildContext context) {
    final theme = Theme.of(context);
    final labelColor =
        theme.textTheme.titleMedium?.color ?? theme.colorScheme.onSurface;
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: CustomPaint(
        painter: _CornerBorderPainter(
          color: labelColor.withValues(alpha: 0.55),
          radius: 18,
          strokeWidth: 1.6,
          extension: 10,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: _openCopyTripWizard,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.content_paste_go_rounded,
                      size: 18, color: labelColor),
                  const SizedBox(width: 8),
                  Text(
                    'Copy a trip with a code',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openCopyTripWizard() {
    if (ref.read(currentUserIdProvider) == null) {
      showSignUpRequiredSheet(
        context,
        icon: Icons.content_paste_go_rounded,
        title: 'Sign in to copy a trip',
        message: 'Trip codes attach the copy to an account. Sign in (or '
            'create one free) and paste the code — the whole trip becomes '
            'yours in seconds.',
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CopyTripWizard()),
    );
  }

  void _openCreateWizard() {
    // Guests create trips too — stored on-device (TripRepository's local
    // branch) and offered for sync at sign-in.
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
        // Checklist: first-ever activation completes step 3 and chains the
        // "Go to map" spotlight on the just-revealed active card.
        final wasFirstActivation =
            !ref.read(checklistProvider).isDone(ChecklistStep.activateTrip);
        ref.read(checklistProvider.notifier).mark(ChecklistStep.activateTrip);
        if (wasFirstActivation) {
          ref.read(checklistGuideRequestProvider.notifier).state =
              ChecklistGuide.goToMap;
        }
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

    // Keep the checklist truthful for work done outside the guided path
    // (or before the feature existed).
    ref.listen(userTripsProvider, (prev, next) {
      final trips = next.valueOrNull;
      if (trips != null && trips.isNotEmpty) {
        ref.read(checklistProvider.notifier).deriveFromTrips(trips);
      }
    });

    // Fulfil the guides this screen owns. Safe as ref.listen: these are
    // only requested while the home tab is on stage.
    ref.listen<ChecklistGuide?>(checklistGuideRequestProvider, (prev, next) {
      if (next == null) return;
      final guide = ref.read(checklistGuideRequestProvider.notifier);
      switch (next) {
        case ChecklistGuide.createTrip:
          guide.state = null;
          _coachAfterScroll(_newTripBtnKey, 'Create your first trip',
              'Tap New Trip — pick a country, dates, and a name. About 30 seconds.');
        case ChecklistGuide.activateTrip:
          guide.state = null;
          _coachAfterScroll(_cardActivateKey, 'Activate your trip',
              'Activating puts this trip on your map so you can navigate it day by day.');
        case ChecklistGuide.goToMap:
          guide.state = null;
          _coachAfterScroll(_activeGoToMapKey, 'See it on the map',
              'Your trip is live! Go to the map to see your places and plan the route.',
              settleMs: 700);
        case ChecklistGuide.addLocations:
        case ChecklistGuide.optimizeRoute:
          break; // consumed by trip details / map screen
      }
    });
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
    // Search/sort results for BOTH sections, computed once: the sections
    // need to know about each other so the "no matches" message appears
    // exactly once, and never above a section that does have results.
    final ownedMatches = _filterAndSortTrips(
        ownedTrips.where((t) => t.id != activeTripId).toList());
    final sharedMatches = _filterAndSortSharedTrips(
        sharedTripsAsync.valueOrNull ?? const [], activeTripId);
    final searching = _tripQuery.trim().isNotEmpty;

    final hideYourTripsHeader = (ownedTrips.isNotEmpty &&
            ownedTrips.every((t) => t.id == activeTripId)) ||
        // A search that matches nothing here shouldn't leave a bare
        // "Your Trips" heading over empty space.
        (searching && ownedMatches.isEmpty);

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

                // Referral-promo status: dismissible "N free days" card,
                // promotional entitlements only (store subs have their own
                // trial banner).
                const SliverToBoxAdapter(child: PromoDaysCard()),

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

                const SliverPadding(padding: EdgeInsets.symmetric(vertical: 2)),

                // Create Trip Button or Form (hidden during multi-select)
                if (!_selectionMode)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      // THE creation affordance — glowing, big, unmissable.
                      child: Column(
                        children: [
                          PulsingGlow(
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
                            child: IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if ((tripsAsync.valueOrNull?.isNotEmpty ??
                                      false))
                                    ChecklistHeaderChip(
                                        onStepTap: _onChecklistStep),
                                  Expanded(
                                    child: FilledButton(
                                      key: _newTripBtnKey,
                                      onPressed: _openCreateWizard,
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 18),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(18)),
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
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          _buildCopyTripButton(context),
                        ],
                      ),
                    ),
                  ),

                // Breathing room so the big New Trip button and the
                // search field can't be mis-tapped for each other.
                const SliverPadding(
                    padding: EdgeInsets.symmetric(vertical: 14)),

                // Trip search + start-date sort. Only once there's a list
                // worth filtering — same pill language as the map search.
                if (tripsAsync.valueOrNull?.isNotEmpty ?? false)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 44,
                              child: TextField(
                                controller: _tripSearchController,
                                onChanged: (v) =>
                                    setState(() => _tripQuery = v),
                                textAlignVertical: TextAlignVertical.center,
                                decoration: InputDecoration(
                                  isDense: true,
                                  filled: false,
                                  hintText: 'Search trips…',
                                  prefixIcon:
                                      const Icon(Icons.search, size: 20),
                                  suffixIcon: _tripQuery.isEmpty
                                      ? null
                                      : IconButton(
                                          icon:
                                              const Icon(Icons.close, size: 18),
                                          onPressed: () {
                                            _tripSearchController.clear();
                                            setState(() => _tripQuery = '');
                                          },
                                        ),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                    borderSide: BorderSide(
                                        color: Theme.of(context)
                                            .dividerColor
                                            .withValues(alpha: 0.35)),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                    borderSide: BorderSide(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        width: 1.4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            height: 44,
                            width: 44,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                  color: Theme.of(context)
                                      .dividerColor
                                      .withValues(alpha: 0.35)),
                            ),
                            child: IconButton(
                              tooltip: _tripSortAsc
                                  ? 'Start date — earliest first'
                                  : 'Start date — latest first',
                              onPressed: () =>
                                  setState(() => _tripSortAsc = !_tripSortAsc),
                              icon: Icon(
                                _tripSortAsc
                                    ? Icons.arrow_upward_rounded
                                    : Icons.arrow_downward_rounded,
                                size: 20,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
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
                        return _buildTripCard(context, activeTrip,
                            spotlightGoToMap: true);
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
                      // Getting-started checklist replaces the old sample-trip
                      // pitch — unless it's already finished (e.g. every trip
                      // deleted): then a completed list is noise, acknowledge
                      // and point at New Trip instead.
                      final checklist = ref.watch(checklistProvider);
                      final checklistDone =
                          checklist.isComplete || checklist.skipped;
                      return SliverToBoxAdapter(
                        child: checklistDone
                            ? const ChecklistAllSetCard()
                            : OnboardingChecklistCard(
                                onStepTap: _onChecklistStep),
                      );
                    }

                    // The active trip already has its own section above.
                    final listTrips = _filterAndSortTrips(
                        trips.where((t) => t.id != activeTripId).toList());
                    if (listTrips.isEmpty && searching) {
                      // Only claim "nothing matches" when the shared section
                      // is empty under this query too — otherwise the message
                      // would sit directly above visible shared results.
                      if (sharedMatches.isNotEmpty) {
                        return const SliverToBoxAdapter(
                            child: SizedBox.shrink());
                      }
                      return SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Center(
                            child: Text(
                              'No trips match "${_tripQuery.trim()}"',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant),
                            ),
                          ),
                        ),
                      );
                    }
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
                              child: _buildTripCard(context, trip,
                                  spotlightActivate: index == 0),
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
                    // Excludes the active trip (own section above), applies
                    // the same name search and start-date sort as Your Trips.
                    final sharedTrips =
                        _filterAndSortSharedTrips(allSharedTrips, activeTripId);
                    if (sharedTrips.isEmpty) {
                      // Also covers "filtered to nothing": the heading stays
                      // hidden rather than labelling an empty section.
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
                            // Null embeds were already dropped by the filter.
                            final tripData =
                                data['trips'] as Map<String, dynamic>;
                            final permission = data['permission'] as String;
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

  Widget _buildTripCard(BuildContext context, Trip trip,
      {bool spotlightActivate = false, bool spotlightGoToMap = false}) {
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
        spotlightActivate: spotlightActivate,
        spotlightGoToMap: spotlightGoToMap,
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
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final isWriteAccess = permission == 'write';

    final localActiveTripId = ref.watch(localActiveTripIdProvider);
    final isActive = localActiveTripId == trip.id;

    // Same metadata derivation as the owner card: prefer the trip's explicit
    // dates, fall back to the span of its locations' scheduled dates.
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

    final metaSpans = <InlineSpan>[];
    if (startDate != null && endDate != null) {
      final st = DateTime(startDate.year, startDate.month, startDate.day);
      final en = DateTime(endDate.year, endDate.month, endDate.day);
      final dayCount = daySpanDays(st, en) + 1;
      final dateText = st == en
          ? DateFormat('MMM d, y').format(st)
          : '${DateFormat('MMM d').format(st)} – ${DateFormat('MMM d, y').format(en)}';
      metaSpans
        ..add(TextSpan(text: dateText))
        ..add(TextSpan(
          text: '  ·  $dayCount day${dayCount == 1 ? '' : 's'}',
          style: TextStyle(color: primary, fontWeight: FontWeight.w700),
        ));
    } else {
      metaSpans.add(const TextSpan(text: 'No dates yet'));
    }
    metaSpans.add(TextSpan(
        text: '  ·  $locationCount place${locationCount == 1 ? '' : 's'}'));

    final country =
        trip.countryCode == null ? null : findCountryByCode(trip.countryCode);

    // The eyebrow carries BOTH facts on one quiet line: activation state
    // and permission — replacing the old orange/blue permission chip.
    final eyebrow = isActive
        ? 'ACTIVE NOW · ${isWriteAccess ? 'CAN EDIT' : 'VIEW ONLY'}'
        : 'SHARED · ${isWriteAccess ? 'CAN EDIT' : 'VIEW ONLY'}';
    final eyebrowColor =
        isActive ? primary : theme.colorScheme.onSurfaceVariant;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => TripDetailsScreen(trip: trip),
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: theme.cardColor.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive
                ? primary.withValues(alpha: 0.45)
                : theme.dividerColor.withValues(alpha: 0.2),
            width: isActive ? 1.4 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: isActive
                  ? primary.withValues(alpha: 0.12)
                  : Colors.black.withValues(alpha: 0.05),
              blurRadius: isActive ? 10 : 4,
              offset: Offset(0, isActive ? 4 : 2),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header: flag badge · eyebrow+name · Options ────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (country != null) ...[
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: theme.dividerColor.withValues(alpha: 0.25)),
                    ),
                    child: CountryFlagIcon(country.code, height: 16),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eyebrow,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: eyebrowColor,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                          fontSize: 10,
                        ),
                      ),
                      Text(
                        trip.name,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Options',
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  color: theme.cardColor.withValues(alpha: 0.94),
                  offset: const Offset(0, 34),
                  child: _optionsChip(theme),
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(
                      value: 'leave',
                      child: Row(
                        children: [
                          Icon(Icons.exit_to_app_rounded,
                              size: 18, color: Colors.red),
                          SizedBox(width: 12),
                          Text('Leave trip',
                              style: TextStyle(color: Colors.red)),
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

            // ── Signature: the route spine ─────────────────────────────
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 12),
              child: SizedBox(
                height: 12,
                width: double.infinity,
                child: CustomPaint(
                  painter: RouteSpinePainter(
                    color: isActive
                        ? primary
                        : theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.35),
                    stops: locationCount,
                  ),
                ),
              ),
            ),

            // ── Metadata line ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: Text.rich(
                TextSpan(children: metaSpans),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // ── Contextual action row ──────────────────────────────────
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: isActive
                  ? Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 42,
                            child: FilledButton.icon(
                              onPressed: () => _goToMapForTrip(trip),
                              icon: const Icon(Icons.map_rounded, size: 18),
                              label: const Text('Go to map'),
                              style: FilledButton.styleFrom(
                                textStyle: theme.textTheme.labelLarge
                                    ?.copyWith(fontWeight: FontWeight.w700),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _cardIconSquare(
                          theme,
                          icon: Icons.stop_circle_outlined,
                          tooltip: 'Deactivate',
                          onPressed: () => _deactivateTrip(trip),
                        ),
                      ],
                    )
                  : SizedBox(
                      width: double.infinity,
                      height: 42,
                      child: FilledButton.tonalIcon(
                        onPressed: () => _setActiveTrip(trip),
                        icon: const Icon(Icons.play_circle_outline, size: 18),
                        label: const Text('Activate'),
                        style: FilledButton.styleFrom(
                          backgroundColor: primary.withValues(alpha: 0.14),
                          foregroundColor: primary,
                          textStyle: theme.textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
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

  /// Publish / unpublish a trip straight from its card. Both directions
  /// confirm first: publishing is privacy-affecting (anyone with the code
  /// can copy the itinerary), and unpublishing revokes every code holder's
  /// access. The server mints the code on first publish and keeps it, so
  /// re-publishing restores the same one.
  Future<void> _toggleTripPublic(Trip trip) async {
    final goPublic = !trip.isPublic;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(goPublic ? 'Make this trip public?' : 'Make it private?'),
        content: Text(
          goPublic
              ? 'You\'ll get a share code. Anyone with it can copy '
                  '"${trip.name}" as their own trip — they never see your '
                  'name, your edits, or your progress, and you can turn '
                  'this off any time.'
              : 'People who have your code will no longer be able to copy '
                  'this trip. Making it public again restores the same code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(goPublic ? 'Go public' : 'Go private'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await ref.read(tripRepositoryProvider).setTripPublic(trip.id, goPublic);
      ref.invalidate(userTripsProvider);
      if (!mounted) return;
      AppToast.success(
          context,
          goPublic
              ? 'Trip is public — the code is on your card'
              : 'Trip is private again');
    } catch (e) {
      debugPrint('setTripPublic failed: $e');
      if (mounted) {
        AppToast.error(
            context, 'Could not update sharing. Check your connection.');
      }
    }
  }

  /// The labeled, transparent menu trigger both card variants use in place
  /// of the bare three-dot icon.
  Widget _optionsChip(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
      ),
      child: Text(
        'Options',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 46×42 quiet square for the card's secondary actions (share,
  /// deactivate) — outlined ghost, never competing with the primary.
  Widget _cardIconSquare(
    ThemeData theme, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      height: 42,
      width: 46,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          foregroundColor: theme.colorScheme.onSurfaceVariant,
          side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Tooltip(message: tooltip, child: Icon(icon, size: 20)),
      ),
    );
  }

  Widget _buildTripCardContent(
    BuildContext context,
    Trip trip,
    int locationCount,
    DateTime? startDate,
    DateTime? endDate, {
    bool isSelected = false,
    bool spotlightActivate = false,
    bool spotlightGoToMap = false,
  }) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final localActiveTripId = ref.watch(localActiveTripIdProvider);
    final isActive = localActiveTripId == trip.id;
    final signedIn = ref.watch(currentUserIdProvider) != null;

    // Active/selected state lives on the SHELL (border + glow) and the
    // eyebrow — never repeated as chips or button colors. Cyan is the only
    // accent; green/orange are gone from this card.
    final borderColor = isSelected
        ? primary
        : isActive
            ? primary.withValues(alpha: 0.45)
            : theme.dividerColor.withValues(alpha: 0.2);
    final borderWidth = isSelected
        ? 2.0
        : isActive
            ? 1.4
            : 1.0;

    // Metadata pieces. Default: one line "Oct 5 – Oct 15, 2026 · 11 days ·
    // 24 places". When a share code exists, the facts split onto a second
    // line under the dates so the code chip fits beside them (owner call).
    String dateText = 'No dates yet';
    final factsSpans = <InlineSpan>[];
    if (startDate != null && endDate != null) {
      final st = DateTime(startDate.year, startDate.month, startDate.day);
      final en = DateTime(endDate.year, endDate.month, endDate.day);
      final dayCount = daySpanDays(st, en) + 1;
      dateText = st == en
          ? DateFormat('MMM d, y').format(st)
          : '${DateFormat('MMM d').format(st)} – ${DateFormat('MMM d, y').format(en)}';
      factsSpans.add(TextSpan(
        text: '$dayCount day${dayCount == 1 ? '' : 's'}',
        style: TextStyle(color: primary, fontWeight: FontWeight.w700),
      ));
    }
    factsSpans.add(TextSpan(
        text:
            '${factsSpans.isEmpty ? '' : '  ·  '}$locationCount place${locationCount == 1 ? '' : 's'}'));

    final metaSpans = <InlineSpan>[
      TextSpan(text: dateText),
      const TextSpan(text: '  ·  '),
      ...factsSpans,
    ];

    final hasCode = signedIn && trip.isPublic && trip.shareCode != null;
    // (factsSpans/dateText stay separate above for readability; the card
    // renders them as one line — the code has its own band below.)

    final country =
        trip.countryCode == null ? null : findCountryByCode(trip.countryCode);

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
                color: theme.cardColor.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: borderColor, width: borderWidth),
                boxShadow: [
                  BoxShadow(
                    color: (isSelected || isActive)
                        ? primary.withValues(alpha: 0.12)
                        : Colors.black.withValues(alpha: 0.05),
                    blurRadius: (isSelected || isActive) ? 10 : 4,
                    offset: Offset(0, (isSelected || isActive) ? 4 : 2),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Header: flag badge · eyebrow+name · menu ──────────
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (country != null) ...[
                        Container(
                          width: 34,
                          height: 34,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color:
                                    theme.dividerColor.withValues(alpha: 0.25)),
                          ),
                          child: CountryFlagIcon(country.code, height: 16),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Eyebrow exists ONLY when the state exists.
                            if (isActive)
                              Text(
                                'ACTIVE NOW',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: primary,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.4,
                                  fontSize: 10,
                                ),
                              ),
                            Text(
                              trip.name,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (!_selectionMode)
                        PopupMenuButton<String>(
                          tooltip: 'Options',
                          // Rounded, slightly translucent menu surface —
                          // shared style with the shared-trip card's menu.
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          color: theme.cardColor.withValues(alpha: 0.94),
                          offset: const Offset(0, 34),
                          child: _optionsChip(theme),
                          itemBuilder: (context) => [
                            PopupMenuItem<String>(
                              value: 'rename',
                              child: Row(
                                children: [
                                  Icon(Icons.edit_rounded,
                                      size: 18, color: primary),
                                  const SizedBox(width: 12),
                                  const Text('Edit'),
                                ],
                              ),
                            ),
                            PopupMenuItem<String>(
                              value: 'reschedule',
                              child: Row(
                                children: [
                                  Icon(Icons.event_repeat_rounded,
                                      size: 18, color: primary),
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
                                  Icon(Icons.delete_rounded,
                                      size: 18, color: Colors.red),
                                  SizedBox(width: 12),
                                  Text('Delete',
                                      style: TextStyle(color: Colors.red)),
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

                  // ── Signature: the route spine ─────────────────────────
                  Padding(
                    padding: const EdgeInsets.only(top: 8, right: 12),
                    child: SizedBox(
                      height: 12,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: RouteSpinePainter(
                          color: isActive
                              ? primary
                              : theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.35),
                          stops: locationCount,
                        ),
                      ),
                    ),
                  ),

                  // ── Metadata line ──────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.only(top: 8, right: 8),
                    child: Text.rich(
                      TextSpan(children: metaSpans),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),

                  // ── Collaborators: their own quiet band again ──────────
                  if (!_selectionMode) ...[
                    const SizedBox(height: 10),
                    TripCollaboratorsRow(
                      tripId: trip.id,
                      tripName: trip.name,
                    ),
                  ],

                  // ── Actions: primary + publish toggle ──────────────────
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 42,
                            child: isActive
                                ? FilledButton.icon(
                                    key: spotlightGoToMap
                                        ? _activeGoToMapKey
                                        : null,
                                    onPressed: () => _goToMapForTrip(trip),
                                    icon:
                                        const Icon(Icons.map_rounded, size: 18),
                                    label: const Text('Go to map'),
                                    style: FilledButton.styleFrom(
                                      textStyle: theme.textTheme.labelLarge
                                          ?.copyWith(
                                              fontWeight: FontWeight.w700),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                    ),
                                  )
                                : FilledButton.tonalIcon(
                                    key: spotlightActivate
                                        ? _cardActivateKey
                                        : null,
                                    onPressed: () => _setActiveTrip(trip),
                                    icon: const Icon(Icons.play_circle_outline,
                                        size: 18),
                                    label: const Text('Activate'),
                                    style: FilledButton.styleFrom(
                                      backgroundColor:
                                          primary.withValues(alpha: 0.14),
                                      foregroundColor: primary,
                                      textStyle: theme.textTheme.labelLarge
                                          ?.copyWith(
                                              fontWeight: FontWeight.w700),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                    ),
                                  ),
                          ),
                        ),
                        // Publish toggle — the LABEL states what the tap
                        // does, so the trip's current visibility is
                        // readable without a separate status chip.
                        if (signedIn) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            height: 42,
                            child: OutlinedButton(
                              onPressed: () => _toggleTripPublic(trip),
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 14),
                                foregroundColor: trip.isPublic
                                    ? theme.colorScheme.onSurfaceVariant
                                    : primary,
                                side: BorderSide(
                                    color: trip.isPublic
                                        ? theme.dividerColor
                                            .withValues(alpha: 0.4)
                                        : primary.withValues(alpha: 0.5)),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                textStyle: theme.textTheme.labelLarge
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              child: Text(
                                  trip.isPublic ? 'Go private' : 'Go public'),
                            ),
                          ),
                        ],
                        if (isActive) ...[
                          const SizedBox(width: 8),
                          _cardIconSquare(
                            theme,
                            icon: Icons.stop_circle_outlined,
                            tooltip: 'Deactivate',
                            onPressed: () => _deactivateTrip(trip),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // ── Share code band: what it's for (left) and the code
                  // itself (right, tappable to copy). Only when public.
                  if (hasCode)
                    Padding(
                      padding: const EdgeInsets.only(top: 12, right: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              'Send this code to anyone who wants to copy '
                              'your trip',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                height: 1.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          InkWell(
                            borderRadius: BorderRadius.circular(11),
                            onTap: () {
                              Clipboard.setData(ClipboardData(
                                  text: 'TRIP-${trip.shareCode}'));
                              AppToast.success(
                                  context, 'Code copied — send it to anyone!');
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 9),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(11),
                                border: Border.all(
                                    color: primary.withValues(alpha: 0.45)),
                                color: primary.withValues(alpha: 0.08),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'TRIP-${trip.shareCode}',
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.4,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(Icons.copy_rounded,
                                      size: 16, color: primary),
                                ],
                              ),
                            ),
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
                    shape: BoxShape.circle,
                    color: isSelected
                        ? primary
                        : theme.cardColor.withValues(alpha: 0.9),
                    border: Border.all(
                      color: isSelected
                          ? primary
                          : theme.dividerColor.withValues(alpha: 0.6),
                      width: 1.5,
                    ),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check_rounded,
                          size: 17, color: Colors.black)
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
        // Runs for a RESCHEDULE and for the FIRST date set alike. A trip
        // that had no dates still anchors the shift — on the earliest
        // scheduled day among its places — otherwise setting dates left
        // every place stranded on whatever "today" it was added under
        // (the July-dates bug this repairs).
        if (newStartDate != null) {
          final mode = await _askRescheduleMode(
            count: tripLocations.length,
            newStart: newStartDate,
          );
          if (mode == null) return; // cancelled
          if (mode == 'move') {
            final anchor = trip.startDate ??
                tripLocations
                    .map((l) => l.scheduledDate!)
                    .reduce((a, b) => a.isBefore(b) ? a : b);
            pendingShift = _planTripShift(
              tripLocations,
              oldStart: anchor,
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

/// Border that exists ONLY at the four rounded corners: each corner draws
/// its 90° arc plus a short [extension] into the straight edges, leaving the
/// edges themselves open. Round caps so the strokes end softly.
class _CornerBorderPainter extends CustomPainter {
  const _CornerBorderPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
    required this.extension,
  });

  final Color color;
  final double radius;
  final double strokeWidth;
  final double extension;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final r = radius;
    final e = extension;
    final w = size.width;
    final h = size.height;
    final rad = Radius.circular(r);

    final path = Path()
      // top-left
      ..moveTo(0, r + e)
      ..lineTo(0, r)
      ..arcToPoint(Offset(r, 0), radius: rad)
      ..lineTo(r + e, 0)
      // top-right
      ..moveTo(w - r - e, 0)
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w, r), radius: rad)
      ..lineTo(w, r + e)
      // bottom-right
      ..moveTo(w, h - r - e)
      ..lineTo(w, h - r)
      ..arcToPoint(Offset(w - r, h), radius: rad)
      ..lineTo(w - r - e, h)
      // bottom-left
      ..moveTo(r + e, h)
      ..lineTo(r, h)
      ..arcToPoint(Offset(0, h - r), radius: rad)
      ..lineTo(0, h - r - e);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerBorderPainter old) =>
      color != old.color ||
      radius != old.radius ||
      strokeWidth != old.strokeWidth ||
      extension != old.extension;
}
