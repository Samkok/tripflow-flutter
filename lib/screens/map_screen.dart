import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ui';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/screens/location_search_screen.dart';
// import 'package:voyza/screens/login_screen.dart'; // DISABLED with first-optimize celebration (2026-08-07)
import 'package:voyza/widgets/pulsing_glow.dart';
import 'package:voyza/widgets/route_leg_sheet.dart';
import 'package:voyza/providers/onboarding_checklist_provider.dart';
import 'package:voyza/widgets/onboarding_checklist.dart';
import 'package:voyza/widgets/review_sentiment_dialog.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';
import 'package:uuid/uuid.dart';
import '../models/location_model.dart';
import '../models/trip.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/route_share_card_service.dart';
import '../services/trip_day_service.dart';
import '../utils/trip_dates.dart';
import '../services/time_saved_ledger_service.dart';
import '../utils/geo_utils.dart';
import '../providers/location_provider.dart';
import '../providers/optimized_map_overlay_provider.dart';
import '../providers/trip_provider.dart';
// import '../providers/trip_simulation_provider.dart'; // DISABLED with first-optimize celebration (2026-08-07)
import '../providers/theme_provider.dart';
import '../providers/all_days_route_provider.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/debounced_settings_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/user_trip_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/local_active_trip_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/auth_provider.dart';
import '../services/location_service.dart';
import '../services/places_service.dart';
import '../services/anonymous_user_service.dart';
import '../services/location_add_service.dart';
import '../services/subscription_limit_service.dart';
import '../services/onboarding_service.dart';
import '../providers/nearby_radius_provider.dart';
import '../providers/zoom_fit_settings_provider.dart';
import '../utils/countries.dart';
import '../widgets/app_toast.dart';
import '../providers/subscription_provider.dart';
import '../services/analytics_service.dart';
import '../widgets/celebration_dialogs.dart';
import '../widgets/free_places_meter.dart';
import '../widgets/map_tutorial.dart';
// import '../widgets/referral_prompt.dart'; // DISABLED with first-optimize celebration (2026-08-07)
import '../widgets/map_widget.dart';
import '../widgets/nearby_places_picker_sheet.dart';
import '../widgets/trip_bottom_sheet.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  GoogleMapController? _mapController;
  bool _preparingShare = false;
  DraggableScrollableController? _sheetController;
  bool _isTrackingLocation = false;
  int? _highlightedLocationIndex;

  /// Set when [localActiveTripIdProvider] changes (activate / switch /
  /// deactivate). The actual camera move waits until [pinnedLocations]
  /// next emits, so we operate on the locations of the new trip rather
  /// than the old one (the sync listener that swaps locations is async).
  bool _pendingTripCameraMove = false;

  /// Content signature of the all-days routes the camera last fitted.
  /// allDayRoutesProvider recomputes on every pinnedLocations emission
  /// (startup sync churn!) and returns a FRESH map instance each time, so
  /// an identity check re-fitted the camera over and over — yanking the
  /// view back to zoom-to-fit while the user was mid-gesture. Geometry
  /// content is what matters: re-fit only when it actually changes.
  String? _allDaysRoutesFitSig;

  StreamSubscription<LatLng>?
      _locationSubscription; // PERFORMANCE: Track subscription for cleanup

  // Compass feed for the current-location heading beam. The stream is
  // throttled at the source (250ms); _lastAppliedHeading backs the ≥3°
  // change gate below, so magnetometer noise while the phone lies still
  // writes nothing into deviceHeadingProvider (zero marker churn).
  StreamSubscription<double?>? _compassSubscription;
  double? _lastAppliedHeading;

  /// Thermal: while the plan sheet is expanded past ~half height it covers
  /// the map — heading-beam updates are invisible there, but each one still
  /// forced a map redraw (+ the sheet's blur). The compass stream is
  /// CANCELLED (not paused — a paused broadcast subscription buffers events
  /// and replays a stale burst on resume) while the sheet hides the map and
  /// restarted when it collapses. Hysteresis avoids flapping mid-drag.
  bool _compassStoppedBySheet = false;

  void _syncCompassToSheetExtent() {
    final ctrl = _sheetController;
    if (ctrl == null || !ctrl.isAttached) return;
    final size = ctrl.size;
    final shouldStop = _compassStoppedBySheet ? size > 0.50 : size > 0.55;
    if (shouldStop == _compassStoppedBySheet) return;
    _compassStoppedBySheet = shouldStop;
    if (shouldStop) {
      _compassSubscription?.cancel();
      _compassSubscription = null;
    } else if (_isTrackingLocation) {
      _startCompassTracking();
    }
  }

  /// Battery: set when the tab gate (not lifecycle/dispose) stopped the
  /// sensor streams, so returning to the Map tab restarts exactly what the
  /// gate stopped — and never becomes a second entry point into the
  /// permission-prompting first-init flow.
  bool _sensorsStoppedByTabGate = false;

  // OPTIMIZATION: Cache for lifecycle management
  AppLifecycleState? _lastLifecycleState;

  // ── One-time map spotlight tour ────────────────────────────────────────
  // Keys are State fields (created once) so the spotlight elements survive
  // rebuilds; the search bar lives in a Consumer's cached child and the
  // optimize button is passed down into TripBottomSheet.
  final _searchBarKey = GlobalKey();
  final _optimizeButtonKey = GlobalKey();

  // Checklist guide consumption. Watch-and-compare, NOT ref.listen: this
  // tab is offstage in the IndexedStack when the request is set from home,
  // and listeners in offstage children never fire (riverpod-offstage-listen).
  ChecklistGuide? _lastConsumedGuide;

  /// Guards the manual refresh FAB against double-taps and drives its
  /// in-button spinner.
  bool _isManualRefreshing = false;
  bool _tutorialCheckInFlight = false;
  TutorialCoachMark? _activeTutorial;

  // Country of the device's current location, reverse-geocoded from the known
  // position (see [_resolveCurrentLocationCountry]). Used by "zoom to fit" to
  // exclude the current location when it's in a different country than the
  // active trip. Null until resolved (fit falls back to including it).
  String? _currentLocationCountry;
  LatLng? _currentLocationCountryFor;
  // Dedupes the cross-country "location not included" toast so repeated /
  // background fits don't spam it. Holds the last "trip>current" pair notified;
  // reset whenever the countries match again so a later mismatch re-notifies.
  String? _crossCountryFitNoticeKey;

  @override
  void initState() {
    super.initState();
    // OPTIMIZATION: Register as lifecycle observer to handle app state changes
    WidgetsBinding.instance.addObserver(this);
    // Seed from the binding: didChangeAppLifecycleState only fires on LATER
    // transitions, and on Android the launch "resumed" is delivered before
    // this observer exists — leaving the field null for the whole session
    // unless the app is backgrounded once. The position listener gates on
    // resumed, so unseeded it silently dropped every GPS update (frozen
    // current-location dot on a cold start).
    _lastLifecycleState = WidgetsBinding.instance.lifecycleState;
    _sheetController = DraggableScrollableController();
    // Compass stops while the plan sheet covers the map (thermal).
    _sheetController!.addListener(_syncCompassToSheetExtent);
    // NOT here: MapScreen is built inside MainScreen's IndexedStack, so its
    // initState runs at launch even when the Map tab is offstage — which
    // fired the OS location prompt on the very first frame, before the user
    // had seen a map. Deferred to _maybeInitLocationForVisibleMap(), which
    // runs when the Map tab is actually shown (see build + didChangeDeps).
    // Session 2+: an anonymous user lands directly on the map tab with no
    // provider event, so check once after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeStartMapTutorial();
      // Arrival polling runs for the life of this screen while the app is
      // foregrounded (lifecycle callbacks pause/resume it). Started here so
      // opening the app while already standing at a stop is noticed —
      // didChangeAppLifecycleState only fires on later transitions.
      _startArrivalPolling();
    });
  }

  // OPTIMIZATION: Handle app lifecycle to pause heavy operations when app is backgrounded
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lastLifecycleState = state;
    if (state == AppLifecycleState.paused) {
      // App is backgrounded - stop location + compass tracking to save battery
      _locationSubscription?.pause();
      _compassSubscription?.pause();
      // …and stop arrival polling entirely (no background location, ever).
      _stopArrivalPolling();
    } else if (state == AppLifecycleState.resumed) {
      // App is resumed - resume location + compass tracking
      _locationSubscription?.resume();
      _compassSubscription?.resume();
      _startArrivalPolling();
    }
  }

  @override
  void dispose() {
    // OPTIMIZATION: Remove lifecycle observer
    WidgetsBinding.instance.removeObserver(this);

    // Defensive: never strand the tutorial's OverlayEntry on teardown.
    _activeTutorial?.finish();
    _activeTutorial = null;

    _sheetController?.removeListener(_syncCompassToSheetExtent);
    _sheetController?.dispose();

    // PERFORMANCE: Cancel location stream to prevent memory leaks and battery drain
    _locationSubscription?.cancel();
    _compassSubscription?.cancel();
    _stopArrivalPolling();

    // OPTIMIZATION: Dispose map controller if still active
    _mapController = null;

    super.dispose();
  }

  /// One-time map spotlight tour (search → long-press → optimize).
  /// Gate chain, in order — every await is followed by a liveness re-check:
  ///  visible tab → settle delay → route current → loading overlay gone →
  ///  onboarding resolved → tour flag unset → show. Flag is marked on BOTH
  ///  finish and skip; app-kill mid-tour leaves it unset (tour repeats —
  ///  the correct failure direction).
  Future<void> _maybeStartMapTutorial() async {
    if (_tutorialCheckInFlight || _activeTutorial != null) return;
    _tutorialCheckInFlight = true;
    try {
      if (ref.read(selectedTabIndexProvider) != 1) return;

      // Let the landing settle (map paint, sheet snap, toasts).
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      if (ref.read(selectedTabIndexProvider) != 1) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;

      // Don't spotlight through the map loading overlay — same pair of
      // conditions that dismisses it (see the Stack's loading branch).
      if (!ref.read(initialSyncCompleteProvider)) return;
      if (!ref.read(cachedMarkerBitmapsProvider).hasValue) return;

      final effectiveId =
          ref.read(currentUserIdProvider) ?? await AnonymousUserService.id;
      if (!mounted) return;

      // The tour opens with "Add your first place" — pointless (and factually
      // wrong, fighting the places meter) when the board already has places,
      // e.g. right after the one-tap sample-trip seed, where it would sit
      // between the user and the glowing Optimize button. Empty boards only.
      if (ref.read(tripProvider).pinnedLocations.isNotEmpty) return;

      final service = OnboardingService.instance;
      // Only after onboarding is resolved (completed/skipped/seeded) — the
      // tour must never race the onboarding route.
      if (await service.shouldShowOnboarding(effectiveId)) return;
      if (await service.hasCelebrated(
          effectiveId, OnboardingMilestone.mapTutorial)) {
        return;
      }

      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      if (ref.read(selectedTabIndexProvider) != 1) return;

      Future<void> markDone() async {
        _activeTutorial = null;
        await service.markCelebrated(
            effectiveId, OnboardingMilestone.mapTutorial);
      }

      _activeTutorial = buildMapTutorial(
        context,
        searchBarKey: _searchBarKey,
        optimizeKey: _optimizeButtonKey,
        isPro: ref.read(isProProvider),
        onFinish: () {
          unawaited(markDone());
          AnalyticsService.instance.mapTutorialCompleted();
        },
        onSkip: (lastStep) {
          unawaited(markDone());
          AnalyticsService.instance.mapTutorialSkipped(lastStep);
          return true; // allow the dismissal
        },
      );
      // rootOverlay: the scrim must cover the bottom nav so the user can't
      // switch tabs out from under the tour.
      _activeTutorial!.show(context: context, rootOverlay: true);
    } finally {
      _tutorialCheckInFlight = false;
    }
  }

  /// True once the Map tab has been visible at least once, so the location
  /// permission prompt fires in context (on the map) rather than at launch.
  bool _locationInitStarted = false;

  /// Kicks off location setup the first time the Map tab is actually on
  /// screen. Both Apple and Google recommend asking in context like this —
  /// it's also where the permission finally makes sense to the user.
  /// Opened only by an explicit "the user is now looking at the map, and
  /// nothing is covering it" signal — see [_openLocationGate].
  ///
  /// A plain "is the Map tab selected + is my route on top?" test is NOT
  /// enough: MainScreen switches anonymous users to the Map tab
  /// synchronously at launch, but doesn't push onboarding until after a
  /// multi-second sync await. In that gap the tab IS the map and nothing IS
  /// on top yet — so the prompt fired seconds before onboarding appeared.
  bool _locationGateOpen = false;

  /// Marks the map as the user's current, uncovered surface and takes the
  /// first location reading. Called from the two signals that genuinely mean
  /// that: startup chrome (consent + onboarding + sign-up) having fully
  /// resolved, and the user tapping over to the Map tab.
  void _openLocationGate() {
    _locationGateOpen = true;
    // From here on the OS dialog is allowed — the map is what the user is
    // looking at, so the request finally has context.
    LocationService.promptsAllowed = true;
    _maybeInitLocationForVisibleMap();
  }

  void _maybeInitLocationForVisibleMap() {
    if (_locationInitStarted || !_locationGateOpen || !mounted) return;
    if (ref.read(selectedTabIndexProvider) != 1) return;
    // Belt and braces: never prompt while any route sits above the map.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _locationInitStarted = true;
    _initializeLocation();
  }

  Future<void> _initializeLocation() async {
    try {
      final currentLocation = await LocationService.getCurrentLocation();
      if (currentLocation != null) {
        ref.read(tripProvider.notifier).updateCurrentLocation(currentLocation);
        // Resolve its country up front so the first "zoom to fit" already
        // knows whether we're in the trip's country.
        _resolveCurrentLocationCountry(currentLocation);

        // Initial camera positioning
        if (_mapController != null) {
          _mapController!.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(
                target: currentLocation,
                zoom: 15.0,
              ),
            ),
          );
        }
        _startLocationTracking();
      }
    } catch (e) {
      debugPrint("Failed to get location: $e");
      if (mounted) {
        AppToast.warning(
          context,
          'Location permissions denied. Showing default map area.',
        );
      }
      // Move camera to a default location if getting current location fails
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          const CameraPosition(
            target: LatLng(37.422, -122.084), // GooglePlex as default
            zoom: 10.0,
          ),
        ),
      );
    }
  }

  void _startLocationTracking() {
    if (_isTrackingLocation) return;
    if (ref.read(selectedTabIndexProvider) != 1) {
      // Reached while the map tab is hidden (e.g. the user tabbed away
      // during the first fix). Don't spin sensors for an invisible map —
      // flag it so the tab listener starts them on the next visit.
      _sensorsStoppedByTabGate = true;
      return;
    }

    _isTrackingLocation = true;

    // Continuous tracking, Google-Maps style: the stream emits every 5m of
    // real movement (native distanceFilter — a stationary device emits
    // nothing), updateCurrentLocation() dedupes <3m GPS jitter, and the
    // heavy marker/route pipelines don't watch the position, so each tick
    // costs one single-marker diff.
    _startCompassTracking();
    _locationSubscription = LocationService.getLocationStream().listen(
      (location) {
        // OPTIMIZATION: Only update if app is in foreground to prevent background processing
        // null = no lifecycle event seen yet → we're foreground (same
        // null-tolerance as the arrival-poll gates below).
        if (mounted &&
            (_lastLifecycleState == null ||
                _lastLifecycleState == AppLifecycleState.resumed)) {
          ref.read(tripProvider.notifier).updateCurrentLocation(location);
          // FOREGROUND-ONLY by construction: this stream only runs while the
          // app is active (no background modes are declared on either
          // platform) AND this branch is additionally gated on
          // AppLifecycleState.resumed. No background location anywhere.
          _maybePromptArrival(location);
        }
        // Location tracking without automatic camera animation
        // Camera only moves when user explicitly requests it
      },
      onError: (error) {
        // Handle location stream errors gracefully
        debugPrint('Location stream error: $error');
      },
    );
  }

  /// Battery: GPS + compass run only while the map is the visible tab.
  /// pause() on the Dart subscription is NOT enough for that — the native
  /// location manager keeps the GPS hot until the last listener CANCELS —
  /// so hiding the tab cancels both streams and re-visiting restarts them.
  /// (App-level backgrounding needs no equivalent: with no background modes
  /// declared, the OS suspends the process and releases the sensors itself.)
  /// Arrival polling is deliberately NOT gated: it must keep noticing
  /// arrivals from any tab, and its discrete 20s fixes are cheap.
  void _syncSensorsToTabVisibility(bool mapTabVisible) {
    if (!mapTabVisible) {
      if (_isTrackingLocation) {
        _stopSensorStreams();
        _sensorsStoppedByTabGate = true;
      }
    } else if (_sensorsStoppedByTabGate) {
      _sensorsStoppedByTabGate = false;
      _startLocationTracking();
    }
  }

  void _stopSensorStreams() {
    _locationSubscription?.cancel();
    _locationSubscription = null;
    _compassSubscription?.cancel();
    _compassSubscription = null;
    // Next compass event after a restart must always apply (no ≥3° gate
    // against a stale reference), so the beam re-aims immediately.
    _lastAppliedHeading = null;
    _isTrackingLocation = false;
  }

  /// Compass feed for the current-location heading beam (the Google-Maps
  /// "flashlight"). Started with location tracking, paused/resumed with the
  /// app lifecycle, cancelled in dispose. Writes into [deviceHeadingProvider]
  /// only when the heading moved ≥3° (circular difference), so sensor noise
  /// on a still phone triggers zero marker updates.
  void _startCompassTracking() {
    if (_compassSubscription != null) return;
    // The sheet currently hides the map — _syncCompassToSheetExtent
    // restarts this the moment it collapses.
    if (_compassStoppedBySheet) return;

    _compassSubscription = LocationService.getCompassStream().listen(
      (heading) {
        if (!mounted || _lastLifecycleState == AppLifecycleState.paused) {
          return;
        }
        if (heading == null) {
          // Lost the compass (uncalibrated / no magnetometer): fall back to
          // the plain dot instead of freezing the beam at a stale angle.
          if (_lastAppliedHeading != null) {
            _lastAppliedHeading = null;
            ref.read(deviceHeadingProvider.notifier).state = null;
          }
          return;
        }
        final h = ((heading % 360) + 360) % 360;
        final last = _lastAppliedHeading;
        if (last != null) {
          final delta = ((h - last + 540) % 360) - 180;
          if (delta.abs() < 3) return;
        }
        _lastAppliedHeading = h;
        ref.read(deviceHeadingProvider.notifier).state = h;
      },
      onError: (error) {
        debugPrint('Compass stream error: $error');
      },
    );
  }

  /// Arrival detection: when the device is within [_arrivalRadiusMeters] of
  /// one of TODAY's not-yet-done stops on the active trip, offer to mark it
  /// done. Prompted at most once per stop per session (declining doesn't
  /// nag again), and never while another arrival dialog is up.
  static const double _arrivalRadiusMeters = 10;
  final Set<String> _arrivalPromptedIds = {};
  bool _arrivalDialogOpen = false;
  Timer? _arrivalPollTimer;
  bool _arrivalCheckInFlight = false;

  /// Dedicated arrival poll. The movement stream can't drive this: it emits
  /// only on movement (5m native + 3m state filter), so a user already
  /// standing at the stop when the app opens produces NO event inside the
  /// 10m arrival ring. A slow timer taking its own fix is the only trigger
  /// that also notices arrivals that happened while the app was closed.
  ///
  /// FOREGROUND-ONLY, by three independent guards: the timer is started on
  /// resume and cancelled on pause/dispose, each tick re-checks
  /// AppLifecycleState.resumed, and no background location mode is declared
  /// on either platform. Ticks are cheap and skipped entirely when there's
  /// nothing to detect (no active trip, or every stop already prompted).
  static const Duration _arrivalPollInterval = Duration(seconds: 20);

  void _startArrivalPolling() {
    _arrivalPollTimer?.cancel();
    _arrivalPollTimer =
        Timer.periodic(_arrivalPollInterval, (_) => _pollArrival());
    // Also check immediately — arriving while the app was closed should be
    // noticed on the first foreground frame, not 20s later.
    _pollArrival();
  }

  void _stopArrivalPolling() {
    _arrivalPollTimer?.cancel();
    _arrivalPollTimer = null;
  }

  Future<void> _pollArrival() async {
    if (!mounted || _arrivalCheckInFlight || _arrivalDialogOpen) return;
    if (_lastLifecycleState != null &&
        _lastLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    // Arrival polling starts at LAUNCH (initState post-frame) so arriving
    // while the app was closed is noticed immediately — which means it must
    // never be the thing that raises the permission dialog. Without this
    // gate, a user with an active trip got the OS location prompt on top of
    // onboarding. Opportunistic feature: run only if already permitted.
    if (!await LocationService.hasLocationPermissionAlready()) return;
    if (!mounted) return;
    // Cheap pre-checks before spending a GPS fix.
    if (ref.read(realtimeActiveTripProvider).valueOrNull == null) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final candidates = ref.read(tripProvider).pinnedLocations.where((l) =>
        !l.isDone &&
        !l.isSkipped &&
        !_arrivalPromptedIds.contains(l.id) &&
        l.isActiveOnDate(today));
    if (candidates.isEmpty) return;

    _arrivalCheckInFlight = true;
    try {
      final fix = await LocationService.getCurrentLocation();
      if (fix == null || !mounted) return;
      await _maybePromptArrival(fix);
    } catch (e) {
      debugPrint('arrival poll: $e');
    } finally {
      _arrivalCheckInFlight = false;
    }
  }

  Future<void> _maybePromptArrival(LatLng position) async {
    if (_arrivalDialogOpen || !mounted) return;
    if (_lastLifecycleState != null &&
        _lastLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final activeTrip = ref.read(realtimeActiveTripProvider).valueOrNull;
    if (activeTrip == null) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    LocationModel? hit;
    var best = double.infinity;
    for (final loc in ref.read(tripProvider).pinnedLocations) {
      if (loc.isDone || loc.isSkipped) continue;
      if (_arrivalPromptedIds.contains(loc.id)) continue;
      if (!loc.isActiveOnDate(today)) continue;
      final d = _metersBetween(position, loc.coordinates);
      if (d <= _arrivalRadiusMeters && d < best) {
        best = d;
        hit = loc;
      }
    }
    if (hit == null) return;
    final arrived = hit;

    _arrivalPromptedIds.add(arrived.id);
    _arrivalDialogOpen = true;
    try {
      final markDone = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          icon: Icon(Icons.place_rounded,
              color: Theme.of(ctx).colorScheme.primary, size: 34),
          title: Text('You\'re at ${arrived.name}!'),
          content: const Text('Looks like you\'ve arrived. Mark this stop as '
              'done so your route stays up to date?'),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            // The primary action is deliberately the big, filled, full-width
            // one — marking done should be the obvious tap.
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(ctx).pop(true),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Mark as done'),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Not yet'),
            ),
          ],
        ),
      );
      if (markDone == true && mounted) {
        await ref.read(tripProvider.notifier).markLocationsAsDone({arrived.id});
        if (mounted) {
          AppToast.success(context, '${arrived.name} marked as done ✓');
        }
      }
    } finally {
      _arrivalDialogOpen = false;
    }
  }

  /// Captures a live snapshot of the actual map (route polyline + numbered
  /// markers) and shares it as a branded card — the realistic "route on the
  /// map" image. Frames the route first and lets tiles settle before the
  /// snapshot; falls back to the silhouette card if the snapshot is null.
  ///
  /// [archetype]/[roastLine] are supplied by the Plan Card moment so the same
  /// realistic-map card carries the identity headline + roast line.
  Future<void> _shareRouteMapImage(
      {String? archetype, String? roastLine}) async {
    if (_preparingShare) return;
    final tripState = ref.read(tripProvider);
    final allDaysMode = ref.read(allDaysModeProvider);
    if (allDaysMode) {
      // All-days share: needs the whole-trip overlays, not the selected-date
      // optimized route.
      final routes = ref.read(allDayRoutesProvider).valueOrNull ?? const {};
      if (routes.isEmpty) {
        if (mounted) {
          AppToast.info(
              context, 'Your day routes are still loading — try again.');
        }
        return;
      }
    } else if (tripState.optimizedRoute.isEmpty) {
      if (mounted) {
        AppToast.info(context, 'Optimize a route first, then share it.');
      }
      return;
    }
    // Instagram center-crops feed posts to ~4:5 while Stories are full-bleed
    // 9:16 — one image cannot serve both, so the user picks the destination
    // shape and both the camera fit and the card render match it. QA drives
    // skip the picker (no one to tap it) and test the story render.
    const qaNoShare = bool.fromEnvironment('QA_NO_SHARE', defaultValue: false);
    ShareCardFormat format = ShareCardFormat.story;
    var saveToPhotos = false;
    var captureAsIs = false;
    if (!qaNoShare) {
      final picked = await _pickShareFormat();
      if (picked == null || !mounted) {
        return; // dismissed — don't hijack the camera
      }
      format = picked.format;
      saveToPhotos = picked.save;
      captureAsIs = picked.asIs;
    }
    setState(() => _preparingShare = true);
    try {
      // Frame for the CAPTURE, not for browsing: the snapshot is the raw map
      // layer (no search bar / FABs / sheet), and the share card center-crops
      // it to the chosen format's window — so fit every location + route into
      // that window as large as possible, mode-aware (all days vs selected).
      // "Screenshot" mode skips ALL of that: the user framed the map
      // themselves, so we capture the current camera untouched (and leave
      // it exactly where they put it afterwards).
      if (!captureAsIs) {
        _zoomToFitForShare(format.aspect);
        await Future.delayed(const Duration(milliseconds: 900));
      }
      Uint8List? bytes = await _mapController?.takeSnapshot();
      if (bytes == null && _mapController != null) {
        await Future.delayed(const Duration(milliseconds: 700));
        bytes = await _mapController?.takeSnapshot();
      }
      if (!mounted) return;
      if (!captureAsIs) {
        // Frame captured — restore the normal north-up browsing camera so
        // the user isn't left on a rotated map behind the share sheet.
        _zoomToFitTrip();
      }
      final trip = ref.read(realtimeActiveTripProvider).valueOrNull;
      final anonymous = ref.read(currentUserIdProvider) == null;
      // All-days mode: the card frames the whole trip, so its stats must be
      // whole-trip numbers (every location, every day) — not the selected
      // day's optimized-route count (which is 0 unless that day was just
      // optimized).
      final int? shareDaysCount;
      final int? shareTotalPlaces;
      if (allDaysMode) {
        shareDaysCount = ref.read(activeTripDayAxisProvider).length;
        shareTotalPlaces = ref.read(tripProvider).pinnedLocations.length;
      } else {
        shareDaysCount = null;
        shareTotalPlaces = null;
      }
      // QA-only (flutter drive --dart-define=QA_NO_SHARE=true): render the real
      // card and show it full-screen so the drive can screenshot it, instead of
      // opening the native share sheet (which would block the test). Inert in
      // prod builds.
      final tripName = trip?.name ?? 'My route';
      final stopCount = tripState.optimizedLocationsForSelectedDate.length;
      final shareTimeSaved = allDaysMode ? Duration.zero : tripState.timeSaved;
      // Single-day shares carry which day of the trip this is — the story
      // kicker "DAY 1 OF THE TRIP" above the trip name. All-days shares
      // frame the whole trip, so no day number there.
      String? shareDayLabel;
      if (!allDaysMode) {
        final axis = ref.read(activeTripDayAxisProvider);
        final sel = ref.read(selectedDateProvider);
        final idx = axis.indexWhere((d) =>
            d.year == sel.year && d.month == sel.month && d.day == sel.day);
        if (idx >= 0) shareDayLabel = 'Day ${idx + 1} of the trip';
      }

      // Render ONCE — QA, preview, share and save all consume these bytes,
      // so the QA screenshot is provably the production card.
      Uint8List? cardPng;
      if (bytes != null) {
        cardPng = await RouteShareCardService.instance.renderMapCard(
          mapBytes: bytes,
          tripName: tripName,
          stops: shareTotalPlaces ?? stopCount,
          timeSaved: shareTimeSaved,
          distanceKm: allDaysMode ? 0 : tripState.totalDistance / 1000.0,
          archetype: archetype,
          roastLine: roastLine,
          daysCount: shareDaysCount,
          dayLabel: shareDayLabel,
          format: format,
        );
      }
      if (qaNoShare) {
        debugPrint('QA_SHARE: map snapshot bytes=${bytes?.length}, '
            'card bytes=${cardPng?.length}');
        final qaBytes = cardPng;
        if (qaBytes != null && mounted) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => Scaffold(
              backgroundColor: Colors.black,
              body: Center(child: Image.memory(qaBytes)),
            ),
          ));
        }
        return;
      }
      if (cardPng == null) {
        // Snapshot/render unavailable — fall back to the silhouette card so
        // NEITHER button dead-ends (snapshot flakiness is routine enough
        // that the share path retries it once already).
        final silhouette = await RouteShareCardService.instance.renderCard(
          originalOrder: tripState.originalOrderForSelectedDate,
          optimizedOrder: tripState.optimizedLocationsForSelectedDate,
          timeSaved: shareTimeSaved,
          tripName: tripName,
          dayLabel: shareDayLabel,
        );
        if (saveToPhotos) {
          final ok = silhouette != null &&
              await RouteShareCardService.instance
                  .saveImageFileToPhotos(silhouette);
          if (mounted) {
            if (ok) {
              AppToast.success(
                  context, 'Map unavailable — saved the route card instead.');
            } else {
              AppToast.error(context,
                  'Couldn\'t capture the map — try again in a moment.');
            }
          }
          return;
        }
        await RouteShareCardService.instance.shareRouteCard(
          originalOrder: tripState.originalOrderForSelectedDate,
          optimizedOrder: tripState.optimizedLocationsForSelectedDate,
          timeSaved: shareTimeSaved,
          anonymous: anonymous,
          tripName: tripName,
          tripId: anonymous ? null : trip?.id,
          dayLabel: shareDayLabel,
        );
        return;
      }

      if (!mounted) return;
      final confirmed =
          await _showCardPreview(cardPng, saveToPhotos: saveToPhotos);
      if (confirmed != true || !mounted) return;

      if (saveToPhotos) {
        final saved = await RouteShareCardService.instance
            .saveRenderedMapCard(cardPng, format: format);
        if (mounted) {
          if (saved) {
            AppToast.success(context, 'Route card saved to Photos.');
          } else {
            AppToast.error(context,
                'Couldn\'t save the card — allow photo access and try again.');
          }
        }
        return;
      }

      await RouteShareCardService.instance.shareRenderedMapCard(
        png: cardPng,
        tripId: anonymous ? null : trip?.id,
        tripName: tripName,
        stopCount: stopCount,
        timeSaved: shareTimeSaved,
        anonymous: anonymous,
        archetype: archetype,
        daysCount: shareDaysCount,
        totalPlaces: shareTotalPlaces,
        format: format,
      );
      // The caption (with the itinerary/referral links) rides the clipboard
      // now — the image is shared alone so targets like Facebook can't
      // downgrade it to a link post. Tell the user the paste is ready.
      if (mounted) {
        AppToast.info(
            context, 'Caption with your links copied — paste it in your post.');
      }
    } catch (e) {
      debugPrint('_shareRouteMapImage: $e');
    } finally {
      if (mounted) setState(() => _preparingShare = false);
    }
  }

  /// Full-screen preview of the rendered card — exactly the bytes that will
  /// be shared/saved. Pops true on confirm, false/null on cancel or
  /// barrier dismiss.
  Future<bool?> _showCardPreview(Uint8List png, {required bool saveToPhotos}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.memory(png, fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0x66FFFFFF)),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        icon: Icon(saveToPhotos
                            ? Icons.download_rounded
                            : Icons.ios_share_rounded),
                        label: Text(saveToPhotos ? 'Save to Photos' : 'Share'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onMapCreated(GoogleMapController controller) async {
    _mapController = controller;
    // Set the initial map style.
    final themeMode = ref.read(themeProvider);
    final showPlaceNames = ref.read(showPlaceNamesProvider);
    final style = await MapWidget.getMapStyle(themeMode, showPlaceNames);
    _mapController!.setMapStyle(style);
    // Controller is ready — animate to current location. The map only gets
    // created when the tab is visible, so this is also a valid in-context
    // trigger; the guard inside keeps it to one run.
    _maybeInitLocationForVisibleMap();
  }

  Future<void> _onMapLongPress(LatLng coordinates) async {
    // Check if user has write access to the active trip
    final hasWriteAccess =
        await ref.read(hasActiveTripWriteAccessProvider.future);
    if (!mounted) return;

    if (!hasWriteAccess) {
      AppToast.warning(
        context,
        'You don\'t have permission to add locations to this trip.',
      );
      return;
    }

    // Prevent adding locations to past dates
    final selectedDate = ref.read(selectedDateProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (selectedDate.isBefore(today)) {
      AppToast.warning(context, 'Cannot add locations to a past date.');
      return;
    }
    try {
      final radius = ref.read(nearbyRadiusProvider).round();

      AppToast.info(
        context,
        'Looking up places within ${_formatRadius(radius)}...',
        duration: const Duration(seconds: 3),
      );

      final nearby = await PlacesService.searchNearbyPlaces(
        coordinates,
        radiusMeters: radius,
      );
      if (!mounted) return;
      AppToast.dismiss();

      final picked = await showNearbyPlacesPicker(
        context,
        places: nearby,
        radiusMeters: radius,
      );
      if (picked.isEmpty || !mounted) return;

      await _addNearbyPlaces(picked);
    } catch (e) {
      debugPrint('Error adding location from map: $e');
      if (mounted) {
        AppToast.error(context, 'Failed to add location. Please try again.');
      }
    }
  }

  /// Adds each picked nearby place to the trip. Each pick is first enriched
  /// via [PlacesService.getPlaceDetails] so it carries the full photo list
  /// and the parsed country code — Nearby Search alone returns only the
  /// cover photo and no `address_components`, which is why a manual-search
  /// add ends up with more photos than a long-press add did before.
  ///
  /// The strict country guard inside [LocationAddService.addLocation]
  /// runs once per pick. Picks within the same radius are essentially
  /// always in the same country as each other, so in practice the first
  /// mismatch dialog (if any) covers the whole batch.
  Future<void> _addNearbyPlaces(List<NearbyPlace> pickedAll) async {
    // ONE allowance decision for the whole batch. Without this, every
    // selected place past the free limit re-opened its own paywall — pick
    // 4 places with the allowance full and 4 paywalls stacked up.
    final allowed = await SubscriptionLimitService(ref)
        .canAddPlaces(context, pickedAll.length);
    if (!mounted) return;
    if (allowed == 0) return; // paywall declined, nothing fits
    final picked = pickedAll.take(allowed).toList();

    final enriched = await Future.wait(
      picked.map((p) => PlacesService.getPlaceDetails(p.placeId)),
    );
    if (!mounted) return;

    final scheduledDate = ref.read(selectedDateProvider);
    final addedLocations = <LocationModel>[];
    for (var i = 0; i < picked.length; i++) {
      final fallback = picked[i];
      final details = enriched[i];
      final resolvedName =
          details?.name.isNotEmpty == true ? details!.name : fallback.name;
      final location = LocationModel(
        id: const Uuid().v4(),
        name: resolvedName,
        address: details?.address.isNotEmpty == true
            ? details!.address
            : fallback.vicinity,
        coordinates: details?.coordinates ?? fallback.coordinates,
        addedAt: DateTime.now(),
        scheduledDate: scheduledDate,
        photoReference: details?.photoReference ?? fallback.photoReference,
        photoReferences: details?.photoReferences.isNotEmpty == true
            ? details!.photoReferences
            : fallback.photoReferences,
        photoAttributions:
            details?.photoAttributions ?? fallback.photoAttributions,
        placeId: details?.placeId ?? fallback.placeId,
        originalName: resolvedName,
        googleOpeningHours: details?.openingHours,
        hoursLastRefreshedAt:
            details?.openingHours != null ? DateTime.now() : null,
      );
      final added = await LocationAddService(ref).beforeAddingLocation(
        context,
        location,
        locationCountryCode: details?.countryCode,
        skipLimitCheck: true, // batch gate ran once above
      );
      if (!mounted) return;
      if (added) addedLocations.add(location);
    }

    // Partial batch: tell the user why the rest didn't make it.
    if (allowed < pickedAll.length && addedLocations.isNotEmpty && mounted) {
      AppToast.info(
        context,
        'Added $allowed of ${pickedAll.length} — your free allowance is '
        '${SubscriptionLimitService.effectiveAllowanceOf(ref)} places.',
      );
    }

    if (!mounted || addedLocations.isEmpty) return;

    final count = addedLocations.length;
    AppToast.success(
      context,
      count == 1
          ? 'Added ${addedLocations.first.name} to your trip'
          : 'Added $count locations to your trip',
    );

    setState(() {
      _highlightedLocationIndex = null;
    });
    ref.read(mapUIStateProvider.notifier).clearHighlights();
  }

  String _formatRadius(int meters) {
    if (meters < 1000) return '${meters}m';
    return '${(meters / 1000).toStringAsFixed(meters % 1000 == 0 ? 0 : 1)}km';
  }

  void _onMarkerTapped(LocationModel location) {
    // Find the index of the tapped location in the list for the currently selected date.
    var locationsForDate = ref.read(locationsForSelectedDateProvider);
    var indexInList = locationsForDate.indexWhere((l) => l.id == location.id);

    // All-days mode: the tapped pin may belong to any day, so resolve its
    // number (and the sibling list for the sheet's From/To picker) from the
    // day group that contains it instead of the selected date's list.
    if (ref.read(allDaysModeProvider)) {
      final stopsByDay = ref.read(allDayStopsProvider);
      for (final stops in stopsByDay.values) {
        final i = stops.indexWhere((l) => l.id == location.id);
        if (i != -1) {
          locationsForDate = stops;
          indexInList = i;
          break;
        }
      }
    }

    // The stop number is the index + 1. If not found, default to 0.
    final stopNumber = indexInList != -1 ? indexInList + 1 : 0;

    // The bottom sheet's scroll controller is not directly available here,
    // so we create a new one for the detail sheet's parent controller.
    // This is okay because the detail sheet doesn't need to control the main sheet's scroll from here.
    final dummyScrollController = ScrollController();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      // Keep a full-height sheet (photos + hours + multi-day on small
      // screens) from rendering its header under the status bar/notch.
      useSafeArea: true,
      builder: (modalContext) => LocationDetailSheet(
        location: location,
        number: stopNumber,
        parentScrollController: dummyScrollController,
        parentSheetController: _sheetController,
        onLocationTap: _zoomToLocation,
        // All-days mode: give the sheet the tapped pin's own day group so
        // its From/To picker doesn't show the (unrelated) selected date's
        // stops. Null in single-day mode = existing behavior.
        locationsForDate:
            ref.read(allDaysModeProvider) ? locationsForDate : null,
      ),
    );

    // Clean up the dummy controller after use.
    dummyScrollController.dispose();
  }

  void _showProximitySliderBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Consumer(
        builder: (context, ref, child) {
          final proximityThreshold =
              ref.watch(proximityThresholdPreviewProvider);

          return Container(
            // Uses theme colors
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, -5),
                ),
              ],
              border: Border.all(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.tune,
                      color: Theme.of(context).colorScheme.primary,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Zone Distance',
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        Navigator.of(context).pop();
                        _showManualZoneDistanceInputDialog();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          // Uses theme colors
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          _formatDistance(proximityThreshold),
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                // Uses theme colors
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Theme.of(context).colorScheme.primary,
                    inactiveTrackColor:
                        Theme.of(context).colorScheme.primary.withOpacity(0.3),
                    thumbColor: Theme.of(context).colorScheme.primary,
                    overlayColor:
                        Theme.of(context).colorScheme.primary.withOpacity(0.2),
                    trackHeight: 6,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 12),
                  ),
                  child: Slider(
                    value: proximityThreshold,
                    min: 100.0,
                    max: 5000.0,
                    divisions: 49,
                    onChanged: (value) {
                      ref
                          .read(debouncedProximityThresholdProvider.notifier)
                          .updatePreviewValue(value);
                    },
                    onChangeEnd: (value) {
                      ref
                          .read(debouncedProximityThresholdProvider.notifier)
                          .setValueImmediately(value);
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Adjust how close locations need to be to form a zone. Smaller values create tighter zones, larger values group more distant locations together.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        // Uses theme colors
                        fontStyle: FontStyle.italic, // Uses theme colors
                      ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      // Uses theme colors
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showManualZoneDistanceInputDialog() {
    final textController = TextEditingController();
    final currentThreshold = ref.read(proximityThresholdPreviewProvider);
    textController.text = currentThreshold.toInt().toString();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor, // Uses theme colors
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Set Zone Distance'),
          content: TextField(
            controller: textController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: false),
            decoration: InputDecoration(
              hintText: 'Enter distance in meters', // Uses theme colors
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (newValue) {
              final distance = double.tryParse(newValue);
              if (distance != null && distance >= 100 && distance <= 5000) {
                ref
                    .read(debouncedProximityThresholdProvider.notifier)
                    .setValueImmediately(distance);
              }
              Navigator.of(context).pop();
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel',
                  style: TextStyle(
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color)), // Uses theme colors
            ),
            TextButton(
              onPressed: () {
                final distance = double.tryParse(textController.text);
                if (distance != null && distance >= 100 && distance <= 5000) {
                  ref
                      .read(debouncedProximityThresholdProvider.notifier)
                      .setValueImmediately(distance);
                }
                Navigator.of(context).pop();
              },
              style: TextButton.styleFrom(
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .primary), // Uses theme colors
              child: const Text(
                'Set', // Uses theme colors
                style:
                    TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Note: Collaborator realtime listener is now initialized at app root (main.dart)
    // No need to initialize it here anymore

    // Checklist "optimize" spotlight: requested on home, fulfilled here once
    // the tab is on stage. Collapse the plan sheet first so the header
    // optimize button is where the spotlight expects it.
    final guideReq = ref.watch(checklistGuideRequestProvider);
    if (guideReq == ChecklistGuide.optimizeRoute &&
        _lastConsumedGuide != guideReq) {
      _lastConsumedGuide = guideReq;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(checklistGuideRequestProvider.notifier).state = null;
        _sheetController?.animateTo(
          0.15,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
        Future.delayed(const Duration(milliseconds: 500), () {
          if (!mounted) return;
          showChecklistCoach(
            context,
            targetKey: _optimizeButtonKey,
            title: 'Optimize your route',
            body: 'One tap reorders your day into the smartest route — less '
                'backtracking, more time at the places themselves.',
            align: ContentAlign.top,
          );
        });
      });
    } else if (guideReq == null && _lastConsumedGuide != null) {
      _lastConsumedGuide = null;
    }

    // OPTIMIZATION: Move listeners to separate effect to prevent rebuilding entire widget tree
    // Use a dedicated build widget for listener side effects
    return _buildMapScreenContent(context);
  }

  Widget _buildMapScreenContent(BuildContext context) {
    // Listen to polyline taps to animate the camera to fit the route
    // segment — 'leg_3' fits the whole leg, 'leg_3_s1' fits just that run
    // of a transit leg (the walk connector or ride the user tapped).
    ref.listen<String?>(tappedPolylineIdProvider, (previous, next) {
      if (next == null) return;
      final m = RegExp(r'^leg_(\d+)(?:_s(\d+))?$').firstMatch(next);
      if (m == null) return;
      _zoomToFitLeg(
        int.parse(m.group(1)!),
        runIndex: m.group(2) == null ? null : int.parse(m.group(2)!),
      );
    });

    // PERFORMANCE: Only listen to optimizedRoute changes, not entire TripState
    ref.listen<List<LatLng>>(
      tripProvider.select((s) => s.optimizedRoute),
      (previous, next) {
        final selectedDate = ref.read(selectedDateProvider);
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final isPastDate = selectedDate.isBefore(today);

        // If we are on a past date and a route has just been loaded...
        if (isPastDate && next.isNotEmpty && (previous?.isEmpty ?? true)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _zoomToFitRoute(next);
          });
        }
      },
    );

    // Listen for when the "View Route" button is pressed on a historical trip.
    ref.listen<bool>(TripBottomSheet.viewHistoricalRouteProvider,
        (previous, next) {
      if (next) {
        final route = ref.read(tripProvider).optimizedRoute;
        if (route.isNotEmpty) {
          _zoomToFitRoute(route);
        }
        // Reset the trigger
        ref.read(TripBottomSheet.viewHistoricalRouteProvider.notifier).state =
            false;
      }
    });

    // Listen for the zoom trigger after route optimization
    ref.listen<int>(zoomToFitRouteTrigger, (previous, next) {
      if (next > (previous ?? 0)) {
        _zoomToFitTrip();
      }
    });

    // The "aha" moment: a delight event (optimization / day completion) passed
    // every eligibility gate. Let the user see the optimized route settle for a
    // beat, then run the sentiment-gated review flow. All caps/cooldown live in
    // ReviewPromptService; this only ever fires when it's appropriate to ask.
    ref.listen<int>(reviewPromptTriggerProvider, (previous, next) {
      if (next <= (previous ?? 0)) return;
      Future.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) showReviewSentimentFlow(context);
      });
    });

    // One-time FIRST-optimize celebration. Delayed so the zoom-to-fit
    // settles first (mirrors the review flow's beat). Defers to the
    // timing-warnings sheet when one is due — the flag stays unset in that
    // case, so the next successful optimize celebrates instead. This
    // listener owns the per-user celebrated flag: re-check → mark → show.
    // One-time map spotlight tour re-evaluation points: the tab becoming
    // visible, and MainScreen's "onboarding resolved" bump (the anonymous
    // flow is already ON the map tab when onboarding pops, so no tab event
    // fires for them).
    ref.listen<int>(selectedTabIndexProvider, (prev, next) {
      if (next == 1 && prev != 1) {
        _maybeStartMapTutorial();
        // User deliberately switched to the map — an unambiguous
        // "I'm looking at the map now" signal.
        _openLocationGate();
      }
      // Battery: stop GPS + compass whenever the map tab is hidden and
      // restart them on return (see _syncSensorsToTabVisibility).
      _syncSensorsToTabVisibility(next == 1);
    });
    // Location card's map button → collapse the plan sheet and fly to the
    // spot. Listen is safe: the tap happens on this (onstage) screen.
    ref.listen<MapZoomToLocationRequest?>(mapZoomToLocationRequestProvider,
        (prev, next) {
      if (next == null) return;
      ref.read(mapZoomToLocationRequestProvider.notifier).state = null;
      _sheetController?.animateTo(
        0.15,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: next.target, zoom: 16.5),
        ),
      );
    });

    // Leg sheet's "Show on map": collapse the plan sheet, fit the camera
    // to the leg's bounds, and highlight it so the chip appears.
    ref.listen<MapZoomToLegRequest?>(mapZoomToLegRequestProvider, (prev, next) {
      if (next == null) return;
      ref.read(mapZoomToLegRequestProvider.notifier).state = null; // consume
      final polys = ref.read(tripProvider).legPolylines;
      if (next.legIndex < 0 || next.legIndex >= polys.length) return;
      final points = polys[next.legIndex];
      if (points.isEmpty) return;
      var minLat = points.first.latitude, maxLat = points.first.latitude;
      var minLng = points.first.longitude, maxLng = points.first.longitude;
      for (final p in points) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      _sheetController?.animateTo(
        0.15,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      ref
          .read(mapUIStateProvider.notifier)
          .setTappedPolyline('leg_${next.legIndex}');
      _mapController?.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat, minLng),
            northeast: LatLng(maxLat, maxLng),
          ),
          70,
        ),
      );
    });

    // A route-leg chip was tapped → open its sheet. The markers live in a
    // FutureProvider with no BuildContext, so the tap arrives as a request
    // that we consume here.
    ref.listen<RouteLegSheetRequest?>(routeLegSheetRequestProvider,
        (prev, next) {
      if (next == null) return;
      ref.read(routeLegSheetRequestProvider.notifier).state = null; // consume
      showRouteLegSheet(
        context,
        origin: next.origin,
        destination: next.destination,
        distanceLabel: next.distanceLabel,
        durationLabel: next.durationLabel,
        legIndex: next.legIndex,
        mode: next.mode,
        transit: next.transit,
      );
    });

    ref.listen<int>(mapTutorialRecheckProvider, (prev, next) {
      if (next != (prev ?? 0)) {
        _maybeStartMapTutorial();
        // MainScreen bumps this at the END of its startup chain — after the
        // analytics-consent dialog, onboarding, and the sign-up screen have
        // all resolved. For a launch that lands on the map, this is the
        // first moment the map is genuinely uncovered.
        _openLocationGate();
      }
    });

    // FIRST-OPTIMIZE CELEBRATION DISABLED (owner request 2026-08-07).
    // The trigger side in trip_provider is commented out too; revive
    // both together.
    // ref.listen<int>(firstOptimizeCelebrationTrigger, (previous, next) {
    // if (next <= (previous ?? 0)) return;
    // Future.delayed(const Duration(milliseconds: 1200), () async {
    // if (!mounted) return;
    // // Anonymous users celebrate too — flags keyed to the persistent
    // // device UUID. Their dialog carries a signup nudge: local places
    // // merge into the account on login (syncOnLogin), so "keep your
    // // places" is a true promise and this is the conversion moment.
    // final authUserId = ref.read(currentUserIdProvider);
    // final isAnonymous = authUserId == null;
    // final userId = authUserId ?? await AnonymousUserService.id;
    // if (!mounted) return;
    // final service = OnboardingService.instance;
    // if (await service.hasCelebrated(
    // userId, OnboardingMilestone.firstOptimize)) {
    // return;
    // }
    // // Same condition as the TimingWarningsSheet listener in
    // // trip_bottom_sheet — if the warnings sheet is up/imminent, don't
    // // stack the celebration on top of it.
    // final sim = ref.read(tripSimulationProvider);
    // if (sim != null && !sim.fullyFeasible) {
    // final acked = ref.read(acknowledgedTimingWarningsProvider);
    // final hasUnacked = sim.stops.any(
    // (s) => s.warnings.isNotEmpty && !acked.contains(s.locationId));
    // if (hasUnacked) return;
    // }
    // if (!mounted) return;
    // final tripState = ref.read(tripProvider);
    // await service.markCelebrated(userId, OnboardingMilestone.firstOptimize);
    // if (!mounted || !context.mounted) return;
    // await showFirstOptimizeCelebration(
    // context,
    // stops: tripState.optimizedLocationsForSelectedDate.length,
    // totalTime: tripState.totalTravelTime,
    // timeSaved: tripState.timeSaved,
    // onSignUp: isAnonymous
    // ? () => Navigator.of(context).push(
    // MaterialPageRoute(builder: (_) => const LoginScreen()),
    // )
    // : null,
    // // Authenticated users get the referral CTA instead — the aha
    // // moment is the single highest-converting referral surface.
    // onInvite: isAnonymous
    // ? null
    // : () => inviteFriends(context, ref, source: 'celebration'),
    // // Everyone can carry the aha out of the app — as the realistic
    // // map image (route + markers), falling back to the silhouette card
    // // if the snapshot isn't available.
    // onShare: _shareRouteMapImage,
    // );
    // });
    // });

    // Plan Card: the active trip's plan just became fully optimized — the
    // pre-trip "my plan is ready" social-currency moment. Shown once per
    // trip; this listener owns the shown flag (celebration pattern).
    ref.listen<int>(planCardReadyTrigger, (previous, next) {
      if (next <= (previous ?? 0)) return;
      Future.delayed(const Duration(milliseconds: 1500), () async {
        if (!mounted) return;
        final trip = ref.read(realtimeActiveTripProvider).valueOrNull;
        if (trip == null) return;
        final prefs = await SharedPreferences.getInstance();
        final shownKey = 'plan_card_shown_${trip.id}';
        if (prefs.getBool(shownKey) ?? false) return;
        if (!mounted || !context.mounted) return;

        final places = ref
            .read(tripProvider)
            .pinnedLocations
            .where((l) => l.scheduledDate != null && !l.isSkipped)
            .toList();
        if (places.length < 3) return;
        final days = places
            .map((l) {
              final d = l.scheduledDate!;
              return DateTime(d.year, d.month, d.day);
            })
            .toSet()
            .length;
        final saved =
            await TimeSavedLedgerService.instance.totalForTrip(trip.id);
        final archetype =
            RouteShareCardService.instance.planArchetype(places, days);
        final roast = RouteShareCardService.instance.planRoastLine(trip.id);

        await prefs.setBool(shownKey, true);
        if (!mounted || !context.mounted) return;
        AnalyticsService.instance.planCardShown();
        await showPlanCardDialog(
          context,
          tripName: trip.name,
          archetype: archetype,
          days: days,
          places: places.length,
          timeSaved: saved,
          roastLine: roast,
          // Share the realistic map card (real route + markers) carrying the
          // identity headline + roast — not the abstract silhouette.
          onShare: (roastEnabled) => _shareRouteMapImage(
            archetype: archetype,
            roastLine: roastEnabled ? roast : null,
          ),
        );
      });
    });

    // Share-route requests from outside this screen (the bottom-sheet summary
    // button) — capture a live map snapshot for the realistic share image.
    ref.listen<int>(shareRouteMapTrigger, (previous, next) {
      if (next <= (previous ?? 0)) return;
      _shareRouteMapImage();
    });

    // Auto-frame the map when the user changes the selected date: zoom to
    // fit the day's stops, or fall back to the device location when the
    // day is empty. Date changes are synchronous, so a post-frame callback
    // is enough — pinnedLocations is already correct.
    ref.listen<DateTime>(selectedDateProvider, (previous, next) {
      if (previous == null || previous == next) return;
      // All-days mode owns the camera — don't re-frame per selected date.
      if (ref.read(allDaysModeProvider)) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateCameraForCurrentDate();
      });
    });

    // Entering All-days mode frames the whole trip; leaving it restores the
    // selected day's framing.
    ref.listen<bool>(allDaysModeProvider, (previous, next) {
      if (previous == next) return;
      _allDaysRoutesFitSig = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (next) {
          _zoomToFitAllDays();
        } else {
          _updateCameraForCurrentDate();
        }
      });
    });

    // Day routes stream in asynchronously after the mode flips on (Directions
    // per day). Re-fit when they land so long road detours aren't cropped —
    // the initial fit only knew the stop coordinates.
    ref.listen<AsyncValue<Map<DateTime, List<LatLng>>>>(allDayRoutesProvider,
        (previous, next) {
      final routes = next.valueOrNull;
      if (routes == null || routes.isEmpty) return;
      if (!ref.read(allDaysModeProvider)) return;
      // Cheap geometry signature: day keys + per-day point counts (+ end
      // points). Recomputes triggered by unrelated state churn produce the
      // SAME geometry from the route cache — those must never move the
      // camera; only routes genuinely (re)landing may.
      final sig = (routes.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
          .map((e) => '${e.key.toIso8601String()}#${e.value.length}'
              '#${e.value.isEmpty ? '' : '${e.value.first.latitude.toStringAsFixed(5)},${e.value.last.longitude.toStringAsFixed(5)}'}')
          .join('|');
      if (sig == _allDaysRoutesFitSig) return;
      _allDaysRoutesFitSig = sig;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _zoomToFitAllDays();
      });
    });

    // Trip activation / switch / deactivation. The locations list refreshes
    // asynchronously via _initSyncListener, so we mark a pending camera
    // move here and execute it once pinnedLocations next emits below —
    // that way we always frame the *new* trip's locations, never the old
    // ones.
    ref.listen<String?>(localActiveTripIdProvider, (previous, next) {
      if (previous == next) return;
      _pendingTripCameraMove = true;
      // All-days mode belongs to the trip it was opened for. On switch or
      // deactivation the day chips (its only exit affordance) change or
      // vanish, so drop back to single-day mode rather than stranding the
      // map in a stale overlay.
      ref.read(allDaysModeProvider.notifier).state = false;
    });

    ref.listen<List<LocationModel>>(
      tripProvider.select((s) => s.pinnedLocations),
      (previous, next) {
        // Trip activation / switch / deactivation: gated by the flag
        // set in the localActiveTripIdProvider listener above.
        if (_pendingTripCameraMove) {
          _pendingTripCameraMove = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _updateCameraForCurrentDate();
          });
          return;
        }

        // Reframe whenever the set of locations active on the selected
        // date changes — covers:
        //   • Adding a location via the search-bar / long-press flow.
        //   • Deleting a location.
        //   • Collaborator-driven adds/deletes arriving through the
        //     sync listener (locations show up after a remote fetch).
        // Comparing ID sets (not lengths) catches the same-count
        // "deleted A, added B in the same tick" case too. Edits that
        // don't change membership (rename, stayDuration, etc.) leave
        // the set unchanged and don't trigger reframes.
        final selectedDate = ref.read(selectedDateProvider);
        final prevIds = (previous ?? const <LocationModel>[])
            .where((l) => l.isActiveOnDate(selectedDate))
            .map((l) => l.id)
            .toSet();
        final nextIds = next
            .where((l) => l.isActiveOnDate(selectedDate))
            .map((l) => l.id)
            .toSet();
        final membershipChanged =
            prevIds.length != nextIds.length || !prevIds.containsAll(nextIds);
        if (membershipChanged) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _updateCameraForCurrentDate();
          });
        }
      },
    );

    // Listen for theme or label visibility changes to update the map style instantly.
    ref.listen<bool>(showPlaceNamesProvider, (_, showLabels) async {
      if (_mapController != null) {
        final themeMode = ref.read(themeProvider);
        final style = await MapWidget.getMapStyle(themeMode, showLabels);
        _mapController!.setMapStyle(style);
      }
    });
    ref.listen<ThemeMode>(themeProvider, (_, themeMode) async {
      if (_mapController != null) {
        final showLabels = ref.read(showPlaceNamesProvider);
        final style = await MapWidget.getMapStyle(themeMode, showLabels);
        _mapController!.setMapStyle(style);
      }
    });

    return Scaffold(
      // Don't reflow the body when the soft keyboard appears — the search
      // results render inside the search-bar overlay and the bottom sheet
      // already handles scroll. Resizing on every keyboard frame caused
      // the visible "page pulls down" jank when the input was focused.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // Map — wrapped in a MediaQuery that zeroes viewInsets and
          // viewPadding for THIS subtree only. The google_maps_flutter
          // platform view (GMSMapView/MKMapView on iOS) reads inherited
          // MediaQuery values and shifts its native frame downward when
          // the keyboard opens, which exposes the scaffold background
          // strip at the top of the screen on focus. Other widgets in
          // the Stack (search bar, banners, FAB, bottom sheet) keep the
          // original MediaQuery — the wrap is scoped to just the map so
          // it can't break their own keyboard handling.
          MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewInsets: EdgeInsets.zero,
              viewPadding: MediaQuery.of(context).padding,
            ),
            child: MapWidget(
              onMapCreated: _onMapCreated,
              onMapLongPress: _onMapLongPress,
              onMarkerTap: _onMarkerTapped,
            ),
          ),

          // Trip Name Overlay - Beautiful header showing active trip
          Positioned(
            top: 50,
            left: 16,
            right: 16,
            child: Consumer(
              builder: (context, ref, child) {
                final activeTripAsync = ref.watch(realtimeActiveTripProvider);

                return activeTripAsync.when(
                  // A reload (manual refresh, day added, collaborator edit)
                  // re-resolves the SAME trip through an AsyncLoading tick.
                  // Without this the banner dropped out for those frames and
                  // the search bar jumped up and back — the refresh button's
                  // "page reloaded" flash. Keep drawing the previous trip.
                  skipLoadingOnReload: true,
                  data: (activeTrip) {
                    if (activeTrip == null) return child!;

                    return Column(
                      children: [
                        // Active Trip Name Banner
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: BackdropFilter(
                            filter:
                                ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 14),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.95),
                                    Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.85),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.3),
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.3),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8),
                                  ),
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.white.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Icon(
                                      Icons.navigation_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Active Trip',
                                          style: TextStyle(
                                            color: Colors.white
                                                .withValues(alpha: 0.9),
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          activeTrip.name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 17,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 0.3,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        // Date-range + inclusive day count.
                                        // Rendered as a small subtitle so
                                        // the badge stays compact; only
                                        // shows when the trip actually has
                                        // both endpoints set.
                                        if (activeTrip.startDate != null &&
                                            activeTrip.endDate != null)
                                          Builder(builder: (context) {
                                            final s = DateTime(
                                                activeTrip.startDate!.year,
                                                activeTrip.startDate!.month,
                                                activeTrip.startDate!.day);
                                            final e = DateTime(
                                                activeTrip.endDate!.year,
                                                activeTrip.endDate!.month,
                                                activeTrip.endDate!.day);
                                            final dayCount =
                                                e.difference(s).inDays + 1;
                                            final dateText = activeTrip
                                                        .startDate ==
                                                    activeTrip.endDate
                                                ? DateFormat('MMM d, y').format(
                                                    activeTrip.startDate!)
                                                : '${DateFormat('MMM d').format(activeTrip.startDate!)} - ${DateFormat('MMM d').format(activeTrip.endDate!)}';
                                            return Padding(
                                              padding:
                                                  const EdgeInsets.only(top: 2),
                                              child: Text(
                                                '$dateText  ·  $dayCount day${dayCount == 1 ? '' : 's'}',
                                                style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.85),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w500,
                                                  letterSpacing: 0.2,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            );
                                          }),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  // Day selector — replaces the old owner
                                  // pill and shows for EVERY trip (owned or
                                  // shared): selected date + "Day N", tap
                                  // for the day-picker sheet.
                                  const _DayPill(),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        child!,
                      ],
                    );
                  },
                  loading: () => child!,
                  error: (_, __) => child!,
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Fake search bar — pushes [LocationSearchScreen]
                      // instead of focusing an inline TextField. This
                      // sidesteps every keyboard-driven layout shift that
                      // an inline TextField caused on this screen (the map
                      // getting "pulled down" on focus). The chrome
                      // (rounded, translucent, blurred, with a search icon
                      // and hint text) is preserved so it still reads as a
                      // search bar at a glance.
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(30),
                          child: BackdropFilter(
                            filter:
                                ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(30),
                                onTap: () {
                                  // Zero-duration page transition: the new
                                  // screen appears instantly instead of
                                  // sliding in. The standard slide-in left
                                  // a window (~300ms on iOS) during which
                                  // the map screen was still visible — any
                                  // MediaQuery / keyboard event from the
                                  // mounting screen propagated back to the
                                  // map and visibly shifted it before the
                                  // transition finished. With Duration.zero,
                                  // the new screen fully covers the map
                                  // before the next frame paints.
                                  Navigator.of(context).push(
                                    PageRouteBuilder(
                                      pageBuilder: (context, _, __) =>
                                          const LocationSearchScreen(),
                                      transitionDuration: Duration.zero,
                                      reverseTransitionDuration: Duration.zero,
                                      opaque: true,
                                    ),
                                  );
                                },
                                child: Container(
                                  key: _searchBarKey, // spotlight-tour anchor
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 14),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surface
                                        .withValues(alpha: 0.92),
                                    borderRadius: BorderRadius.circular(30),
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .dividerColor
                                          .withValues(alpha: 0.2),
                                      width: 1.5,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.15),
                                        blurRadius: 20,
                                        offset: const Offset(0, 5),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.search,
                                        color: AppTheme.primaryColor,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          'Search for places...',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Goal-gradient progress: free users see how much of the
                  // 5-place allowance is used, live. Hidden for Pro.
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: FreePlacesProgressChip(),
                  ),
                  // Manual refresh — realtime escape hatch. Right-aligned so
                  // it shares the vertical axis of the FAB column below.
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      // Bare icon (owner call): no box, tinted the color
                      // the box used to be, soft shadow for map legibility.
                      child: IconButton(
                        tooltip: 'Refresh data',
                        onPressed: _isManualRefreshing ? null : _manualRefresh,
                        icon: _isManualRefreshing
                            ? SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              )
                            : Icon(
                                Icons.refresh_rounded,
                                size: 28,
                                color: Theme.of(context).colorScheme.primary,
                                shadows: const [
                                  Shadow(color: Colors.black45, blurRadius: 8),
                                ],
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Floating Action Buttons for Map Controls — flips to a
          // horizontal row when the search bar is focused so it doesn't
          // crowd the search results column. Direction is driven by the
          // focus ValueNotifier (so only this subtree rebuilds), and the
          // bounding-box change is smoothed with AnimatedSize.
          //
          // Positioned is INSIDE the ValueListenableBuilder so both the
          // bottom offset and the FAB axis can react to focus together:
          //   • Vertical (default): 16px gap above the collapsed sheet.
          //   • Horizontal (focused): the row drops well below the sheet
          //     top so it visibly hugs the sheet rather than floating
          //     high above it.
          //
          // Position is anchored against `View.physicalSize` — the OS-
          // reported screen size in logical pixels — instead of
          // `MediaQuery.size.height` so the FAB doesn't shift with
          // keyboard events. The search bar pushes a separate screen
          // now, so there is no inline keyboard event on this screen
          // to begin with — but anchoring against physicalSize keeps
          // the position correct even if something else (Android
          // adjustResize, system UI change) ever does shrink the
          // logical screen height.
          Builder(
            builder: (context) {
              final view = View.of(context);
              final screenH = view.physicalSize.height / view.devicePixelRatio;
              return Positioned(
                bottom: screenH * 0.23 + 16,
                right: 16,
                child: AnimatedBuilder(
                  // Fade the FAB column as the plan sheet expands over its
                  // zone — half-visible buttons ghosting through the glass
                  // read as tappable (the confusion that briefly sent this
                  // sheet chasing a globe background). Fully gone by 0.5
                  // extent; IgnorePointer so invisible buttons can't be hit.
                  animation:
                      _sheetController ?? const AlwaysStoppedAnimation(0.0),
                  builder: (context, child) {
                    final extent = (_sheetController?.isAttached ?? false)
                        ? _sheetController!.size
                        : 0.15;
                    final covered = ((extent - 0.30) / 0.20).clamp(0.0, 1.0);
                    return IgnorePointer(
                      ignoring: covered > 0.95,
                      child: Opacity(opacity: 1.0 - covered, child: child),
                    );
                  },
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    alignment: Alignment.bottomRight,
                    child: Consumer(
                      builder: (context, ref, _) {
                        final locationsForDate =
                            ref.watch(locationsForSelectedDateProvider);
                        final hasSelectedDayRoute = ref.watch(tripProvider
                            .select((s) => s.optimizedRoute.isNotEmpty));
                        // In All-days mode the share/fit affordances key off the
                        // whole-trip overlays instead of the selected-date route.
                        final allDaysActive = ref.watch(allDaysModeProvider) &&
                            (ref
                                    .watch(allDayRoutesProvider)
                                    .valueOrNull
                                    ?.isNotEmpty ??
                                false);
                        final hasRoute = hasSelectedDayRoute || allDaysActive;
                        final isGenerating =
                            ref.watch(isGeneratingRouteProvider);
                        final showPlaceNames =
                            ref.watch(showPlaceNamesProvider);

                        final fabs = <Widget>[
                          FloatingActionButton(
                            heroTag: 'currentLocationFab',
                            mini: true,
                            onPressed: _goToCurrentLocation,
                            child: const Icon(Icons.my_location),
                          ),
                          if (locationsForDate.isNotEmpty)
                            FloatingActionButton(
                              heroTag: 'zoomToFitFab',
                              mini: true,
                              onPressed: _zoomToFitTrip,
                              child: const Icon(Icons.zoom_out_map),
                            ),
                          // The share FAB is the growth surface — a pulsing glow
                          // makes it the standout affordance in the column.
                          if (hasRoute && !isGenerating)
                            PulsingGlow(
                              glowColor: Theme.of(context).colorScheme.primary,
                              child: FloatingActionButton(
                                heroTag: 'shareRouteFab',
                                mini: true,
                                backgroundColor:
                                    Theme.of(context).colorScheme.primary,
                                foregroundColor:
                                    Theme.of(context).colorScheme.onPrimary,
                                onPressed: _preparingShare
                                    ? null
                                    : _shareRouteMapImage,
                                tooltip: 'Share route',
                                child: _preparingShare
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white),
                                      )
                                    : const Icon(Icons.ios_share_rounded),
                              ),
                            ),
                          // Clearing operates on the SELECTED day's optimized
                          // route — in pure All-days viewing there's nothing to
                          // clear, so key this off the day route only.
                          if (hasSelectedDayRoute && !isGenerating)
                            FloatingActionButton(
                              heroTag: 'clearRouteFab',
                              mini: true,
                              backgroundColor:
                                  Theme.of(context).colorScheme.errorContainer,
                              foregroundColor: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                              onPressed: () => ref
                                  .read(tripProvider.notifier)
                                  .clearOptimizedRoute(),
                              tooltip: 'Clear Route',
                              child: const Icon(Icons.clear_outlined),
                            ),
                          // (The bulk "Add Locations to Trip" FAB lived here.
                          // Removed: adding now happens per-location from the
                          // pin's detail sheet, which shows "Add to trip" for
                          // any location not attached to a trip.)
                          FloatingActionButton(
                            heroTag: 'togglePlaceNamesFab',
                            mini: true,
                            onPressed: () {
                              ref.read(showPlaceNamesProvider.notifier).state =
                                  !showPlaceNames;
                            },
                            tooltip: 'Toggle Place Names',
                            child: Icon(
                              showPlaceNames
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ];

                        // Always vertical now — the inline search bar
                        // (which previously flipped this to horizontal on
                        // focus) is gone, replaced by a button that pushes
                        // a separate screen.
                        const gap = SizedBox(height: 12);
                        final children = <Widget>[];
                        for (var i = 0; i < fabs.length; i++) {
                          if (i > 0) children.add(gap);
                          children.add(fabs[i]);
                        }

                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: children,
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),

          // Trip bottom sheet. (The Listener that previously wrapped
          // this sheet to dismiss the inline search keyboard is gone —
          // search now lives on its own pushed screen, so there's no
          // FocusNode on this screen to unfocus.)
          TripBottomSheet(
            sheetController: _sheetController,
            onLocationTap: _zoomToLocation,
            optimizeKey: _optimizeButtonKey, // spotlight-tour anchor
            // onGoToCurrentLocation is now handled by the FAB
            onShowZoneSettings: _showProximitySliderBottomSheet,
            // onZoomToFitTrip is now handled by the FAB
            highlightedLocationIndex: _highlightedLocationIndex,
          ),

          // Loading overlay — covers the map during the initial data sync so
          // the user never sees the blink that occurs while marker bitmaps are
          // being generated for the first time.  The overlay fades out once:
          //   1. performInitialLocationSync() has completed (remote data written
          //      to Hive), AND
          //   2. cachedMarkerBitmapsProvider has finished its async bitmap
          //      generation (the expensive part that would cause the blink).
          Consumer(
            builder: (context, ref, _) {
              final syncDone = ref.watch(initialSyncCompleteProvider);
              final markersAsync = ref.watch(cachedMarkerBitmapsProvider);
              // Ready when sync is done AND the first set of bitmaps is computed.
              // Keeping both conditions prevents the overlay from dismissing
              // prematurely while bitmap generation is still in flight.
              final isReady = syncDone && markersAsync.hasValue;
              return AnimatedOpacity(
                opacity: isReady ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 500),
                child: IgnorePointer(
                  ignoring: isReady,
                  child: _buildLoadingOverlay(context),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(
                  Icons.map_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Loading your locations...',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Manual "pull everything again" for when realtime missed something:
  /// the same work the app does at start — remote locations into the Hive
  /// cache (the repository skips Supabase for guests on its own) plus a
  /// trips/shared-trips refetch (guests re-read the local store).
  Future<void> _manualRefresh() async {
    if (_isManualRefreshing) return;
    setState(() => _isManualRefreshing = true);
    try {
      await Future.wait([
        performInitialLocationSync(ref.read(locationRepositoryProvider)),
        // Floor so the spinner reads as action, not flicker.
        Future.delayed(const Duration(milliseconds: 600)),
      ]);
      ref.invalidate(userTripsProvider);
      ref.invalidate(sharedTripsProvider);
      if (mounted) AppToast.success(context, 'Everything is up to date');
    } catch (e) {
      debugPrint('Manual refresh failed: $e');
      if (mounted) {
        AppToast.error(
            context, 'Refresh failed. Please check your connection.');
      }
    } finally {
      if (mounted) setState(() => _isManualRefreshing = false);
    }
  }

  Future<void> _goToCurrentLocation() async {
    // Explicit user action on the map — the OS prompt is legitimate here
    // even if the startup gate never opened (e.g. user raced past it).
    LocationService.promptsAllowed = true;
    // Try to get current location from state first
    LatLng? currentLocation = ref.read(tripProvider).currentLocation;

    // If location isn't available in the state, try to fetch it again.
    if (currentLocation == null) {
      try {
        // Check if location services are enabled first
        final serviceEnabled = await LocationService.isLocationServiceEnabled();
        if (!serviceEnabled) {
          if (!mounted) return;
          final shouldOpenSettings = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Location Services Disabled'),
              content: const Text(
                'Location services are turned off on your device. Please enable them in Settings to use this feature.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          );

          if (shouldOpenSettings == true) {
            // On iOS, this opens Location Services settings
            await LocationService.openLocationSettings();
          }
          return;
        }

        currentLocation = await LocationService.getCurrentLocation();
        if (currentLocation != null) {
          ref
              .read(tripProvider.notifier)
              .updateCurrentLocation(currentLocation);
        } else {
          // Location service returned null (likely permission denied)
          if (!mounted) return;
          AppToast.warning(
            context,
            'Location permission denied. Please enable it to use this feature.',
          );
          return;
        }
      } catch (e) {
        debugPrint("Failed to get current location on demand: $e");
        if (!mounted) return;
        AppToast.error(
            context, 'Failed to get your location. Please try again.');
        return;
      }
    }

    if (_mapController != null && mounted) {
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
            CameraPosition(target: currentLocation, zoom: 16.0)),
      ); // Uses theme colors

      // Collapse the bottom sheet to show more of the map
      _sheetController?.animateTo(
        0.15, // minChildSize
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );

      // Clear highlighting
      setState(() {
        _highlightedLocationIndex = null;
      });
      ref.read(mapUIStateProvider.notifier).clearHighlights();
    } else if (mounted) {
      AppToast.warning(
        context,
        'Current location is not available. Please enable location services.',
      );
    }
  }

  /// Automatic camera reframe called when the selected date changes or the
  /// active trip is swapped/deactivated. Picks the natural framing for the
  /// new context:
  ///   • Day has stops → [_zoomToFitTrip] (also honors the
  ///     "include current location in fit" setting).
  ///   • Day is empty → recenter on the device's known [currentLocation].
  ///
  /// Stays silent if the map isn't ready or the device location is unknown:
  /// this is a background camera move, so it must never pop a permission
  /// dialog or snackbar the way the manual "My location" FAB does.
  void _updateCameraForCurrentDate() {
    if (_mapController == null) return;
    final locations = ref.read(locationsForSelectedDateProvider);
    if (locations.isNotEmpty) {
      _zoomToFitTrip();
      return;
    }
    final current = ref.read(tripProvider).currentLocation;
    if (current == null) return;
    _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: current, zoom: 16.0),
      ),
    );
  }

  /// Resolves and caches the country of the device's [location] so
  /// [_zoomToFitTrip] can compare it against the active trip's country without
  /// an async hop. Re-geocodes only after ~5km of movement (country
  /// granularity), so it costs at most one network call per meaningful move.
  Future<void> _resolveCurrentLocationCountry(LatLng location) async {
    final last = _currentLocationCountryFor;
    if (last != null &&
        _currentLocationCountry != null &&
        _metersBetween(last, location) < 5000) {
      return; // still near the last resolve — reuse the cached country
    }
    final country = await LocationService.getCountryCodeForLocation(location);
    if (!mounted || country == null) return;
    _currentLocationCountry = country;
    _currentLocationCountryFor = location;
  }

  double _metersBetween(LatLng a, LatLng b) {
    const earthRadius = 6371000.0; // meters
    final dLat = (b.latitude - a.latitude) * math.pi / 180.0;
    final dLng = (b.longitude - a.longitude) * math.pi / 180.0;
    final lat1 = a.latitude * math.pi / 180.0;
    final lat2 = b.latitude * math.pi / 180.0;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * earthRadius * math.asin(math.min(1.0, math.sqrt(h)));
  }

  void _zoomToFitTrip() {
    if (_mapController == null) return;

    // In All-days mode the whole trip is on screen, so every "fit the route"
    // request (FAB, optimize flow, share) means "fit every day", not the
    // selected date.
    if (ref.read(allDaysModeProvider)) {
      _zoomToFitAllDays();
      return;
    }

    // The day fit frames what's left to DO: skipped and done stops keep
    // their pins but don't drive the camera. (Entire-trip mode differs by
    // design — [_zoomToFitAllDays] keeps done stops in the story via
    // [allDayStopsProvider], which only drops skipped ones.) When every stop
    // on the day is done/skipped there's nothing "left", so fall back to
    // framing all of them rather than doing nothing.
    final allOnDate = ref.read(locationsForSelectedDateProvider);
    final active = allOnDate.where((l) => !l.isSkipped && !l.isDone).toList();
    final locations = active.isEmpty ? allOnDate : active;
    final excludedIds = <String>{
      if (active.isNotEmpty)
        for (final l in allOnDate)
          if (l.isSkipped || l.isDone) l.id,
    };
    final includeCurrent = ref.read(includeCurrentInFitProvider);
    final currentLocation = ref.read(tripProvider).currentLocation;

    // Keep the current-location country fresh (cheap after the first resolve)
    // so the cross-country check has an answer on the next fit even if the
    // device has since moved.
    if (currentLocation != null) {
      _resolveCurrentLocationCountry(currentLocation);
    }

    // If the device is in a different country than the active trip, never fold
    // the current location into the bounds — a trip in Japan shouldn't zoom out
    // to a phone in Cambodia. This OVERRIDES the "include current location"
    // preference, which only makes sense within a single country.
    final tripCountry =
        ref.read(realtimeActiveTripProvider).valueOrNull?.countryCode;
    final currentCountry = _currentLocationCountry;
    final bool crossCountry;
    if (tripCountry != null) {
      crossCountry = currentCountry != null &&
          tripCountry.toUpperCase() != currentCountry.toUpperCase();
    } else {
      // No trip country (anonymous session, or a trip with no country tagged):
      // the country comparison has nothing to compare against, so fall back to
      // proximity — a device implausibly far from every stop is in a different
      // region and must not be folded into the bounds (e.g. a phone in Cambodia
      // framing the Lisbon sample trip).
      crossCountry = currentLocation != null &&
          locations.isNotEmpty &&
          minMetersToAny(currentLocation, locations.map((l) => l.coordinates)) >
              kForeignFallbackMeters;
    }

    if (crossCountry) {
      // Announce it once — but only when the preference would otherwise have
      // included the location and there are stops to frame. Deduped so
      // background / repeated fits don't spam the toast.
      if (includeCurrent && currentLocation != null && locations.isNotEmpty) {
        final key =
            tripCountry != null ? '$tripCountry>$currentCountry' : 'far';
        if (_crossCountryFitNoticeKey != key) {
          _crossCountryFitNoticeKey = key;
          final where = tripCountry != null
              ? (findCountryByCode(tripCountry)?.name ?? "the trip's country")
              : null;
          AppToast.info(
            context,
            where != null
                ? "You're not in $where right now, so your current location "
                    "isn't included in the map view."
                : "Your current location is far from your stops, so it isn't "
                    "included in the map view.",
          );
        }
      }
    } else {
      // Countries match (or one is unknown, or in range) — let a later
      // mismatch re-notify.
      _crossCountryFitNoticeKey = null;
    }

    final currentForFit =
        (includeCurrent && !crossCountry) ? currentLocation : null;

    // Build the points list before the small-list short-circuit so the
    // current-location preference also takes effect when there's only 0–1
    // stops on the date.
    final points = <LatLng>[
      ...locations.map((loc) => loc.coordinates),
      if (currentForFit != null) currentForFit,
    ];

    if (points.length < 2) {
      if (points.isNotEmpty) {
        _zoomToLocation(points.first);
      }
      return;
    }

    // Same leading-vector framing as the share capture, constrained to the
    // BROWSING window (below the search bar, above the collapsed sheet).
    // Route geometry rides in the extents so the drawn road never clips —
    // except legs touching an excluded (done/skipped) stop, which would drag
    // the frame right back to the pin the filter just dropped.
    final tripState = ref.read(tripProvider);
    final legDetails = tripState.legDetails;
    final legPoints = <LatLng>[
      for (var i = 0; i < tripState.legPolylines.length; i++)
        if (excludedIds.isEmpty ||
            i >= legDetails.length ||
            (!excludedIds.contains(legDetails[i]['fromId']) &&
                !excludedIds.contains(legDetails[i]['toId'])))
          ...tripState.legPolylines[i],
    ];
    _fitPointsLeadingVector(
      orientStops: locations.map((l) => l.coordinates).toList(),
      extents: [...points, ...legPoints],
      window: _browsingFitWindow(),
      instant: false,
    );
  }

  /// Fits every day of the active trip at once: all stops plus every day's
  /// route geometry (so a long detour on any day stays in frame). Used by
  /// All-days mode for the fit FAB, the mode-entry zoom, and the share
  /// capture. The device location is deliberately excluded — the whole-trip
  /// overview frames the trip, not the viewer.
  void _zoomToFitAllDays() {
    if (_mapController == null) return;

    final stopsByDay = ref.read(allDayStopsProvider);
    final routes = ref.read(allDayRoutesProvider).valueOrNull ?? const {};

    final stops = <LatLng>[
      for (final dayStops in stopsByDay.values)
        for (final loc in dayStops) loc.coordinates,
    ];
    final points = <LatLng>[
      ...stops,
      for (final route in routes.values) ...route,
    ];

    if (points.length < 2) {
      if (points.isNotEmpty) {
        _zoomToLocation(points.first);
      }
      return;
    }

    _fitPointsLeadingVector(
      orientStops: stops,
      extents: points,
      window: _browsingFitWindow(),
      instant: false,
    );
  }

  /// Share-capture framing. Unlike the browsing fits, this ignores every
  /// piece of on-screen chrome — `takeSnapshot()` returns only the map
  /// layer, so content "under" the search bar or FABs is fully visible in
  /// the capture. What DOES matter is the share card's cover-crop: the
  /// snapshot is center-cropped to the chosen format's portrait canvas
  /// ([cardAspect] = width:height, 9:16 story or 4:5 post), so all points
  /// (stops + full route geometry, all days in All-days mode) are fitted
  /// into that central vertical window with only a slim margin — far-flung
  /// stops fill the tall card instead of huddling in a padded corner.
  void _zoomToFitForShare(double cardAspect) {
    if (_mapController == null) return;

    // Stops drive the ORIENTATION (the "leading vector" is fitted through
    // the plotted locations); stops + route geometry drive the EXTENTS so
    // no road bulge gets cropped.
    final List<LatLng> stops;
    final List<LatLng> points;
    if (ref.read(allDaysModeProvider)) {
      final stopsByDay = ref.read(allDayStopsProvider);
      final routes = ref.read(allDayRoutesProvider).valueOrNull ?? const {};
      stops = <LatLng>[
        for (final dayStops in stopsByDay.values)
          for (final loc in dayStops) loc.coordinates,
      ];
      points = <LatLng>[
        ...stops,
        for (final route in routes.values) ...route,
      ];
    } else {
      final tripState = ref.read(tripProvider);
      stops = ref
          .read(locationsForSelectedDateProvider)
          .map((loc) => loc.coordinates)
          .toList();
      points = <LatLng>[
        ...stops,
        for (final leg in tripState.legPolylines) ...leg,
      ];
    }

    if (stops.length < 2 || points.length < 2) {
      // Nothing meaningful to frame tightly — fall back to the normal fit.
      _zoomToFitTrip();
      return;
    }

    _fitPointsLeadingVector(
      orientStops: stops,
      extents: points,
      window: _shareCropWindow(cardAspect),
      // moveCamera (NOT animate): an animated sweep could still be
      // mid-flight when the snapshot fires — the "locations cut off"
      // failure mode.
      instant: true,
    );
  }

  /// Small pre-share chooser: which destination shape to render. Tapping a
  /// row opens the OS share sheet — on iOS that sheet natively contains
  /// "Save Image" (it appears now that NSPhotoLibraryAddUsageDescription is
  /// declared; iOS hides the action without it). Android's system sheet
  /// can't host custom actions, so ONLY there each row keeps a download
  /// button that saves the card straight to the gallery. Returns null when
  /// dismissed.
  Future<({ShareCardFormat format, bool save, bool asIs})?> _pickShareFormat() {
    final androidSaveButton = defaultTargetPlatform == TargetPlatform.android;
    Widget option(BuildContext ctx, ShareCardFormat format, IconData icon,
        String title, String subtitle,
        {bool asIs = false}) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: () =>
            Navigator.of(ctx).pop((format: format, save: false, asIs: asIs)),
        trailing: androidSaveButton
            ? IconButton(
                icon: const Icon(Icons.download_rounded),
                tooltip: 'Save to gallery',
                onPressed: () => Navigator.of(ctx)
                    .pop((format: format, save: true, asIs: asIs)),
              )
            : null,
      );
    }

    return showModalBottomSheet<
        ({ShareCardFormat format, bool save, bool asIs})>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Share your route as…',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            option(ctx, ShareCardFormat.story, Icons.smartphone, 'Story',
                '9:16 full screen — Instagram/Facebook Stories, WhatsApp status'),
            option(ctx, ShareCardFormat.post, Icons.grid_on, 'Post',
                '4:5 — fits Instagram & Facebook feed posts without cropping'),
            // As-framed: no auto zoom — the card captures the map exactly
            // as the user has panned/zoomed it right now.
            option(ctx, ShareCardFormat.story, Icons.crop_free_rounded,
                'Screenshot', 'Captures the map exactly as you framed it',
                asIs: true),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// The on-screen region fitted content should occupy while BROWSING:
  /// below the search bar (and the active-trip banner when shown), above
  /// the collapsed trip sheet, clear of the FAB column.
  Rect _browsingFitWindow() {
    final size = MediaQuery.of(context).size;
    final topSafePadding = MediaQuery.of(context).padding.top;
    final hasActiveTrip =
        ref.read(realtimeActiveTripProvider).valueOrNull != null;
    const topMargin = 50.0;
    final bannerH = hasActiveTrip ? 72.0 + 12.0 : 0.0;
    const searchBarHeight = 60.0;
    const buffer = 20.0;
    final top = topSafePadding + topMargin + bannerH + searchBarHeight + buffer;
    // The sheet's top edge is exactly collapsedSize of the screen up from the
    // bottom — use the sheet's own constant (a stale hardcoded fraction here
    // is why fitted stops used to hide behind it), plus a slightly larger
    // buffer so pins never kiss the sheet's rounded corner.
    final bottom = size.height -
        (size.height * TripBottomSheet.collapsedSize + buffer + 8.0);
    const left = 16.0 + buffer;
    final right = size.width - (40.0 + 16.0 + 40.0); // FAB + margin + buffer
    return Rect.fromLTRB(
        left, top, math.max(right, left + 1), math.max(bottom, top + 1));
  }

  /// The centered window (of [cardAspect] = width:height, e.g. 9:16 story or
  /// 4:5 post) the share card keeps after cover-cropping the snapshot, inset
  /// by a slim margin. Chrome is irrelevant here — the snapshot is the raw
  /// map layer.
  Rect _shareCropWindow(double cardAspect) {
    final size = MediaQuery.of(context).size;
    double cropW = size.width;
    double cropH = size.height;
    if (size.width / size.height < cardAspect) {
      // Screen taller/narrower than 9:16 (every modern phone) → the card
      // keeps full width and crops top/bottom.
      cropH = size.width / cardAspect;
    } else {
      cropW = size.height * cardAspect;
    }
    const innerMargin = 28.0;
    final left = (size.width - cropW) / 2 + innerMargin;
    final top = (size.height - cropH) / 2 + innerMargin;
    return Rect.fromLTRB(left, top, size.width - left, size.height - top);
  }

  /// Leading-vector camera fit — the one framing algorithm behind BOTH the
  /// zoom-to-fit affordances and the share capture.
  ///
  /// Treats [orientStops] as points in the (Web-Mercator) plane, fits the
  /// invisible best-fit line through them (principal axis), and rotates the
  /// camera so that axis runs along [window]'s TALL dimension; then picks
  /// the maximum zoom that keeps every point of [extents] (stops + route
  /// geometry) inside [window]. Off-center windows — the browsing frame
  /// sits high because of the collapsed sheet — are compensated by shifting
  /// the camera target so content centers in the WINDOW, not the screen.
  ///
  /// [instant] uses moveCamera, required before a snapshot so the capture
  /// can never race an animation; browsing fits animate.
  void _fitPointsLeadingVector({
    required List<LatLng> orientStops,
    required List<LatLng> extents,
    required Rect window,
    required bool instant,
  }) {
    if (_mapController == null || extents.isEmpty) return;
    final size = MediaQuery.of(context).size;
    final availW = math.max(window.width, 1.0);
    final availH = math.max(window.height, 1.0);

    // Planar coords: x east (0..1), n north (mercator, flipped north-positive).
    double mercYOf(double latDeg) {
      final s = math.sin(latDeg * math.pi / 180).clamp(-0.9999999, 0.9999999);
      return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
    }

    (double, double) plane(LatLng p) =>
        ((p.longitude + 180) / 360.0, -mercYOf(p.latitude));

    // Principal axis of the stops via the 2x2 covariance eigenvector. A
    // round blob (no dominant axis) stays north-up — rotation buys nothing.
    double bearingDeg = 0;
    final stopPts = orientStops.map(plane).toList(growable: false);
    var mx = 0.0, mn = 0.0;
    if (stopPts.isNotEmpty) {
      for (final (x, n) in stopPts) {
        mx += x;
        mn += n;
      }
      mx /= stopPts.length;
      mn /= stopPts.length;
    }
    if (stopPts.length >= 2) {
      var sxx = 0.0, snn = 0.0, sxn = 0.0;
      for (final (x, n) in stopPts) {
        final dx = x - mx, dn = n - mn;
        sxx += dx * dx;
        snn += dn * dn;
        sxn += dx * dn;
      }
      final tr = sxx + snn;
      final det =
          math.sqrt(math.max((sxx - snn) * (sxx - snn) + 4 * sxn * sxn, 0.0));
      final l1 = (tr + det) / 2, l2 = (tr - det) / 2;
      if (l2 <= 1e-24 || l1 / math.max(l2, 1e-24) > 1.4) {
        // Compass bearing of the major axis = atan2(east, north), folded to
        // (-90, 90] — an axis has no direction, prefer least rotation.
        final phi = 0.5 * math.atan2(2 * sxn, sxx - snn);
        bearingDeg = math.atan2(math.cos(phi), math.sin(phi)) * 180 / math.pi;
        while (bearingDeg > 90) {
          bearingDeg -= 180;
        }
        while (bearingDeg <= -90) {
          bearingDeg += 180;
        }
      }
    }
    final br = bearingDeg * math.pi / 180;
    // With bearing b the compass direction b points UP on screen.
    final ux = math.sin(br), un = math.cos(br);
    final rx = math.cos(br), rn = -math.sin(br);

    // Extents in the ROTATED screen frame.
    var minV = double.infinity, maxV = -double.infinity;
    var minH = double.infinity, maxH = -double.infinity;
    for (final p in extents) {
      final (x, n) = plane(p);
      final dx = x - mx, dn = n - mn;
      final v = dx * ux + dn * un; // along screen-up
      final h = dx * rx + dn * rn; // along screen-right
      minV = math.min(minV, v);
      maxV = math.max(maxV, v);
      minH = math.min(minH, h);
      maxH = math.max(maxH, h);
    }
    final spanV = math.max(maxV - minV, 1e-12);
    final spanH = math.max(maxH - minH, 1e-12);

    // Max zoom fitting the rotated box: world-units × 256·2^z = px.
    const tileSize = 256.0;
    final zoomForV = math.log(availH / (tileSize * spanV)) / math.ln2;
    final zoomForH = math.log(availW / (tileSize * spanH)) / math.ln2;
    final zoom = math.min(zoomForV, zoomForH).clamp(2.0, 17.5).toDouble();
    final scale = tileSize * math.pow(2.0, zoom).toDouble();

    // Content center in world coords…
    final midV = (minV + maxV) / 2, midH = (minH + maxH) / 2;
    final cxw = mx + ux * midV + rx * midH;
    final cnw = mn + un * midV + rn * midH;
    // …then shift the camera target so that center lands at the WINDOW
    // center rather than the screen center (T = C − r·Δx/s + u·Δy/s, with
    // Δ = windowCenter − screenCenter in screen px, +y down).
    final dxPx = window.center.dx - size.width / 2;
    final dyPx = window.center.dy - size.height / 2;
    final tx = cxw - rx * (dxPx / scale) + ux * (dyPx / scale);
    final tn = cnw - rn * (dxPx / scale) + un * (dyPx / scale);

    final ty = -tn; // back to mercator-y (south-positive)
    final targetLat =
        (2 * math.atan(math.exp((0.5 - ty) * 2 * math.pi)) - math.pi / 2) *
            180 /
            math.pi;
    final targetLng = tx * 360.0 - 180.0;

    final camera = CameraPosition(
      target: LatLng(targetLat, targetLng),
      zoom: zoom,
      bearing: (bearingDeg + 360) % 360,
    );
    if (instant) {
      _mapController!.moveCamera(CameraUpdate.newCameraPosition(camera));
    } else {
      _mapController!.animateCamera(CameraUpdate.newCameraPosition(camera));
    }
  }

  void _zoomToLocation(LatLng coordinates) {
    if (_mapController != null) {
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: coordinates,
            zoom: 16.0,
          ),
        ),
      );

      // Clear highlighting when zooming to location
      setState(() {
        _highlightedLocationIndex = null;
      });
      ref.read(mapUIStateProvider.notifier).clearHighlights();
    }
  }

  void _zoomToFitLeg(int legIndex, {int? runIndex}) {
    if (_mapController == null) return;

    final tripState = ref.read(tripProvider);
    if (legIndex < 0 || legIndex >= tripState.legPolylines.length) return;

    // A tapped RUN of a transit leg frames its own geometry; anything
    // missing falls back to the whole leg.
    List<LatLng> legPoints = tripState.legPolylines[legIndex];
    if (runIndex != null && legIndex < tripState.legDetails.length) {
      final runs = tripState.legDetails[legIndex]['transitSteps'] as List?;
      if (runs != null && runIndex >= 0 && runIndex < runs.length) {
        final runPoints =
            ((runs[runIndex] as Map)['points'] as List).cast<LatLng>();
        if (runPoints.length >= 2) legPoints = runPoints;
      }
    }
    if (legPoints.length < 2) return;

    // Calculate the bounds of the polyline
    double minLat = legPoints.first.latitude;
    double maxLat = legPoints.first.latitude;
    double minLng = legPoints.first.longitude;
    double maxLng = legPoints.first.longitude;

    for (final point in legPoints) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLng = math.min(minLng, point.longitude);
      maxLng = math.max(maxLng, point.longitude);
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    _mapController!.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 80.0)); // 80.0 padding
  }

  void _zoomToFitRoute(List<LatLng> routePoints) {
    if (_mapController == null || routePoints.isEmpty) return;

    if (routePoints.length == 1) {
      _mapController!
          .animateCamera(CameraUpdate.newLatLngZoom(routePoints.first, 15.0));
      return;
    }

    double minLat = routePoints.first.latitude;
    double maxLat = routePoints.first.latitude;
    double minLng = routePoints.first.longitude;
    double maxLng = routePoints.first.longitude;

    for (final point in routePoints) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLng = math.min(minLng, point.longitude);
      maxLng = math.max(maxLng, point.longitude);
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    _mapController!.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 60.0)); // 60.0 padding
  }

  String _formatDistance(double distanceInMeters) {
    if (distanceInMeters < 1000) {
      return '${distanceInMeters.toInt()}m';
    } else {
      final kilometers = distanceInMeters / 1000;
      return '${kilometers.toStringAsFixed(1)}km';
    }
  }
}

/// Frosted day-selector pill on the right edge of the active-trip badge.
///
/// Shows the selected day's date with its 1-based index in the trip
/// ("Day 3" under "Sep 9") — or "Entire trip" while All-days mode is on —
/// plus a chevron so it reads as tappable. Tapping opens [_DayPickerSheet].
/// Replaces the old owner pill and shows for EVERY active trip, owned or
/// shared. The leading dot is the selected day's route color, so the pill,
/// the day chips and the map polylines all speak the same legend.
class _DayPill extends ConsumerWidget {
  const _DayPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trip = ref.watch(realtimeActiveTripProvider).valueOrNull;
    final locations = ref.watch(tripProvider.select((s) => s.pinnedLocations));
    final days = contiguousTripDates([
      trip?.startDate,
      trip?.endDate,
      for (final loc in locations) ...[
        loc.scheduledDate ?? loc.addedAt,
        loc.scheduledEndDate ?? loc.scheduledDate ?? loc.addedAt,
      ],
    ]);

    final allDays = ref.watch(allDaysModeProvider);
    final selected = dayKey(ref.watch(selectedDateProvider));
    final dayIndex = days.indexWhere((d) => d.isAtSameMomentAs(selected));
    final routeColor = ref.watch(tripDayColorsProvider)[selected];

    final String topLine;
    final String? bottomLine;
    if (allDays) {
      topLine = 'Entire trip';
      bottomLine = days.isEmpty
          ? null
          : '${days.length} day${days.length == 1 ? '' : 's'}';
    } else {
      topLine = DateFormat('MMM d').format(selected);
      // Off-plan dates (picked outside the trip's day span) have no index —
      // show the year instead of a wrong "Day N".
      bottomLine = dayIndex >= 0
          ? 'Day ${dayIndex + 1}'
          : DateFormat('y').format(selected);
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _DayPickerSheet.show(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.45),
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (allDays) ...[
                        const Icon(Icons.layers_rounded,
                            size: 12, color: Colors.white),
                        const SizedBox(width: 4),
                      ] else if (routeColor != null) ...[
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: routeColor,
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.7),
                                width: 1),
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        topLine,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                  if (bottomLine != null) ...[
                    const SizedBox(height: 1),
                    Text(
                      bottomLine,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.88),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(width: 3),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: Colors.white.withValues(alpha: 0.95),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Frosted-glass day picker opened from [_DayPill]: one row per trip day
/// (stacked vertically), an "Entire trip" row on top mirroring the sheet's
/// All-days chip, and — with write access — the same add/remove-day actions
/// as the trip sheet's day strip, via the shared [TripDayService] so the
/// two surfaces can't drift. Stays open after add/remove so several days
/// can be added in one visit; every row rebuilds live off the providers.
class _DayPickerSheet extends ConsumerStatefulWidget {
  const _DayPickerSheet();

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => const _DayPickerSheet(),
    );
  }

  @override
  ConsumerState<_DayPickerSheet> createState() => _DayPickerSheetState();
}

class _DayPickerSheetState extends ConsumerState<_DayPickerSheet> {
  ScrollController? _scroll;

  // Row heights used to seed the scroll offset so the SELECTED day is
  // already in view when a long trip opens the sheet.
  static const double _rowExtent = 64;

  ScrollController _controllerFor(int selIndex) {
    if (_scroll != null) return _scroll!;
    final target = selIndex <= 2 ? 0.0 : (selIndex - 2) * _rowExtent;
    _scroll = ScrollController(initialScrollOffset: target);
    return _scroll!;
  }

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  Future<void> _addDay(Trip trip, List<DateTime> days) async {
    final range = await TripDayService.addDayAtEnd(
      context,
      ref,
      trip: trip,
      days: days,
    );
    if (range != null && mounted) {
      ref.read(allDaysModeProvider.notifier).state = false;
      ref.read(selectedDateProvider.notifier).state = range.changedDay;
    }
  }

  Future<void> _removeDay(Trip trip, List<DateTime> days) async {
    final range = await TripDayService.removeLastDay(
      context,
      ref,
      trip: trip,
      days: days,
    );
    if (range != null && mounted) {
      final selected = dayKey(ref.read(selectedDateProvider));
      if (selected.isAtSameMomentAs(range.changedDay)) {
        ref.read(selectedDateProvider.notifier).state = range.end;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trip = ref.watch(realtimeActiveTripProvider).valueOrNull;
    final locations = ref.watch(tripProvider.select((s) => s.pinnedLocations));
    final days = contiguousTripDates([
      trip?.startDate,
      trip?.endDate,
      for (final loc in locations) ...[
        loc.scheduledDate ?? loc.addedAt,
        loc.scheduledEndDate ?? loc.scheduledDate ?? loc.addedAt,
      ],
    ]);

    final allDays = ref.watch(allDaysModeProvider);
    final selected = dayKey(ref.watch(selectedDateProvider));
    final dayColors = ref.watch(tripDayColorsProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final canEdit = trip != null &&
        (ref.watch(hasActiveTripWriteAccessProvider).valueOrNull ?? false);

    // Stops scheduled per day — the same isActiveOnDate the planner uses.
    final stopCount = <DateTime, int>{
      for (final d in days)
        d: locations.where((l) => l.isActiveOnDate(d)).length,
    };

    final selIndex = days.indexWhere((d) => d.isAtSameMomentAs(selected));

    final maxHeight = MediaQuery.of(context).size.height * 0.62;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.86),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
            ),
          ),
          // SafeArea sits INSIDE the frosted container so the glass runs to
          // the physical bottom edge (no see-through gap under the buttons)
          // while the buttons keep the same clearance above the home bar.
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Jump to a day',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (trip != null)
                              Text(
                                trip.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: days.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                          child: Text(
                            'Add places or trip dates to build your '
                            'day-by-day list.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.6),
                            ),
                          ),
                        )
                      : ListView(
                          controller: _controllerFor(selIndex),
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          children: [
                            _entireTripRow(theme, days.length, allDays),
                            const SizedBox(height: 4),
                            for (var i = 0; i < days.length; i++) ...[
                              _dayRow(
                                theme,
                                index: i,
                                day: days[i],
                                isSelected: !allDays &&
                                    days[i].isAtSameMomentAs(selected),
                                isToday: days[i].isAtSameMomentAs(today),
                                routeColor: dayColors[days[i]],
                                stops: stopCount[days[i]] ?? 0,
                              ),
                              if (i != days.length - 1)
                                const SizedBox(height: 4),
                            ],
                          ],
                        ),
                ),
                if (canEdit && days.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _addDay(trip, days),
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('Add day'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              foregroundColor: theme.colorScheme.primary,
                              side: BorderSide(
                                color: theme.colorScheme.primary
                                    .withValues(alpha: 0.6),
                                width: 1.3,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              textStyle: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        if (days.length > 1) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _removeDay(trip, days),
                              icon: const Icon(Icons.remove_rounded, size: 18),
                              label: const Text('Remove day'),
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                foregroundColor: theme
                                    .textTheme.bodyMedium?.color
                                    ?.withValues(alpha: 0.7),
                                side: BorderSide(
                                  color:
                                      theme.dividerColor.withValues(alpha: 0.7),
                                  width: 1.2,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                textStyle: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "Entire trip" — the sheet twin of the day strip's All chip: every
  /// day's route on the map at once.
  Widget _entireTripRow(ThemeData theme, int dayCount, bool active) {
    final primary = theme.colorScheme.primary;
    return _pickerRow(
      theme,
      selected: active,
      accent: primary,
      leading: Icon(
        Icons.layers_rounded,
        size: 18,
        color: active
            ? primary
            : theme.colorScheme.onSurface.withValues(alpha: 0.65),
      ),
      title: 'Entire trip',
      subtitle: 'All $dayCount day${dayCount == 1 ? '' : 's'} on the map',
      onTap: () {
        ref.read(allDaysModeProvider.notifier).state = true;
        Navigator.of(context).pop();
      },
    );
  }

  Widget _dayRow(
    ThemeData theme, {
    required int index,
    required DateTime day,
    required bool isSelected,
    required bool isToday,
    required Color? routeColor,
    required int stops,
  }) {
    final accent = routeColor ?? theme.colorScheme.primary;
    return _pickerRow(
      theme,
      selected: isSelected,
      accent: accent,
      leading: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color:
              routeColor ?? theme.colorScheme.onSurface.withValues(alpha: 0.25),
          shape: BoxShape.circle,
        ),
      ),
      title: 'Day ${index + 1}',
      titleBadge: isToday,
      subtitle: DateFormat('EEE, MMM d, y').format(day),
      trailing: stops > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$stops stop${stops == 1 ? '' : 's'}',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
            )
          : null,
      onTap: () {
        ref.read(allDaysModeProvider.notifier).state = false;
        ref.read(selectedDateProvider.notifier).state = day;
        Navigator.of(context).pop();
      },
    );
  }

  /// Shared row chrome: route-color accent fill + border when selected,
  /// quiet otherwise — the same treatment as the day strip's chips.
  Widget _pickerRow(
    ThemeData theme, {
    required bool selected,
    required Color accent,
    required Widget leading,
    required String title,
    String? subtitle,
    Widget? trailing,
    bool titleBadge = false,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? accent.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color:
                  selected ? accent.withValues(alpha: 0.7) : Colors.transparent,
              width: 1.4,
            ),
          ),
          child: Row(
            children: [
              SizedBox(width: 24, child: Center(child: leading)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        if (titleBadge) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color:
                                  Colors.green.shade600.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'Today',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: Colors.green.shade700,
                                fontWeight: FontWeight.w700,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6),
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing,
              ],
              if (selected) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_rounded, size: 20, color: accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
